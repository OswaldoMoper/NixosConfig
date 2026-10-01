{ config, pkgs, lib, inputs, ... }:

let
  inherit (lib) mkIf mkOption mkEnableOption types listToAttrs mkMerge;
  inherit (import ./webstack/lib.nix { inherit lib pkgs; })
    managed resolvePackage holdingConfig holdingLocation mkVHost webApp;
  cfg = config.webStack;
in
  {
    imports = [ ./webstack/integrations.nix ];

    options.webStack = {
      enable = mkEnableOption "Web hosting stack";
      manager = mkOption {
        type = types.str;
        description = "Hosting user";
        default = "admin";
      };
      email = mkOption {
        type = types.str;
        default = "";
        description = "ACME and webStack notifications";
      };

      profiles = mkOption {
        type = types.attrsOf types.attrs;
        default = { };
        internal = true;
        description = ''
          Per `kind = "profile"` app, the settings its own module should take
          from this registry rather than from a second hand-written copy: the
          public name, the backend port and the ACME email.

          A host merges it into the app's own option, naming only where it goes:

              services.moperapp.profile = lib.mkMerge [
                config.webStack.profiles.MoperApp
                { mode = "production"; }
              ];

          The pointer is stated for the same reason `unit` is — an app called
          MoperApp declares `services.moperapp.profile`, and no rule turns one
          into the other. What used to be stated twice, and drifted, is the
          data: a host reached production with an ACME email that was never
          threaded, and only the absence of TLS in development hid it.

          webStack derives it; writing to it is the duplication this exists to
          remove.

          Merging it also makes a mismatch loud. The app's module has to accept
          `serverName`, `ports.backend` and `acmeEmail` under that name, or the
          host fails to evaluate saying which option is missing.
        '';
      };

      nginx = {
        enable = mkEnableOption "Nginx stack";
        apps = mkOption {
          type = types.listOf webApp;
          default = [];
          description = "List of web apps";
        };
        redirects = mkOption {
          type = types.attrsOf types.str;
          default = {};
          example = { "old.example.com" = "https://new.example.com"; };
          description = ''
            Domains that only redirect somewhere else, as domain -> target.
            Each becomes an ACME/TLS virtualHost returning 301, and counts
            towards the global domain uniqueness assertions.
          '';
        };
      };

      tunnel = {
        enable = mkEnableOption "Cloudflare Tunnels stack";
        name = mkOption {
          type = types.str;
          default = "main";
        };
        credentials = mkOption {
          type = types.str;
          default = "/etc/.cloudflared/uuid.json";
        };
        apps = mkOption {
          type = types.listOf webApp;
          default = [];
          description = "List of web apps";
        };
        useNginx = mkEnableOption "Use nginx proxy";
        ssh = {
          enable = mkEnableOption "SSH through Cloudflare Tunnel";
          domain = mkOption {
            type = types.str;
            description = "Public domain for the service";
            default = "";
          };
          port = mkOption {
            type = types.port;
            description = "Internal port the service listens on";
            default = 22;
          };
        };
      };
    };

    config = mkIf cfg.enable {
      webStack.profiles = lib.listToAttrs (map (a: lib.nameValuePair a.name {
        enable = true;
        serverName = a.domain;
        ports.backend = a.port;
        acmeEmail = cfg.email;
      }) (lib.filter (a: a.kind == "profile") (cfg.tunnel.apps ++ cfg.nginx.apps)));

      systemd.tmpfiles.rules =
        lib.concatMap (a: a.directories) (cfg.tunnel.apps ++ cfg.nginx.apps);

      webStack.nginx.redirects = lib.listToAttrs (lib.concatMap
        (a: map (from: lib.nameValuePair from "https://${a.domain}") a.redirects)
        (cfg.tunnel.apps ++ cfg.nginx.apps));

      assertions = let allApps = cfg.tunnel.apps ++ cfg.nginx.apps;
        in [
          {
            assertion = cfg.email != "";
            message = "webStack requires a valid email";
          }
          {
            assertion = lib.any (a: a.database != null) allApps -> config.postgresql.enable;
            message = "webStack: an app declares a database but postgresql.enable is false, so nothing would create it.";
          }
          {
            assertion = lib.all (a: a.umask == null || a.kind != "profile" || a.unit != null) allApps;
            message = ''
              webStack: ${lib.concatMapStringsSep ", " (a: a.name)
                (lib.filter (a: a.umask != null && a.kind == "profile" && a.unit == null) allApps)
              } sets `umask` but is a profile app with no `unit`, and nothing here
              can derive the unit name from the app name. Name the unit, or the
              setting would be dropped without a word.
            '';
          }
          # Declaring a database is not the same as anything creating it, and
          # `provision = false` is exactly where the two come apart.
          {
            assertion = lib.all
              (a: lib.elem a.database.name config.services.postgresql.ensureDatabases)
              (lib.filter (a: a.database != null) allApps);
            message = ''
              webStack: an app declares a database that nothing provisions.

              ${lib.concatMapStringsSep "\n" (a: "  ${a.name} reads ${a.database.name}")
                (lib.filter (a: a.database != null
                               && !(lib.elem a.database.name config.services.postgresql.ensureDatabases))
                  allApps)}

              Either let webStack create it (database.provision = true) or make
              sure whatever module was meant to declares it in
              services.postgresql.ensureDatabases.
            '';
          }
          {
            assertion = lib.all
              (a: lib.elem a.database.user (map (u: u.name) config.services.postgresql.ensureUsers))
              (lib.filter (a: a.database != null) allApps);
            message = ''
              webStack: an app declares a role that nothing provisions.

              ${lib.concatMapStringsSep "\n" (a: "  ${a.name} connects as ${a.database.user}")
                (lib.filter (a: a.database != null
                               && !(lib.elem a.database.user (map (u: u.name) config.services.postgresql.ensureUsers)))
                  allApps)}
            '';
          }
          {
            assertion = lib.all (app: app.kind != "managed" || app.package != null) allApps;
            message = "webStack: every app with kind = \"managed\" needs a 'package'.";
          }
          {
            assertion = allApps != [] || cfg.tunnel.ssh.enable;
            message = "webStack requires at least one app or SSH enabled through the tunnel";
          }
          {
            assertion = cfg.tunnel.enable -> (cfg.tunnel.apps != [] || cfg.tunnel.ssh.enable);
            message = "webStack: Cloudflare Tunnel is enabled but no apps are defined in 'tunnel.apps' and SSH is not enabled.";
          }
          {
            assertion = cfg.nginx.enable -> cfg.nginx.apps != [];
            message = "webStack: Nginx stack is enabled but no apps are defined in 'nginx.apps'.";
          }
          {
            assertion = cfg.tunnel.ssh.enable -> cfg.tunnel.enable != false;
            message = "webStack: SSH service is enabled but `tunnel.enable` is disabled";
          }
          {
            assertion = cfg.tunnel.ssh.enable -> cfg.tunnel.ssh.domain != "";
            message = "webStack: SSH service is enabled but `tunnel.ssh.domain` is void or null.";
          }
          {
            assertion =
              let
                ports = (map (a: a.port) allApps)
                  ++ (lib.optional cfg.tunnel.ssh.enable cfg.tunnel.ssh.port);
              in builtins.length (lib.unique ports) == builtins.length ports;
            message = "webStack: Each service must have unique port";
          }
          {
            assertion = builtins.length (lib.filter (a: a.default) allApps) <= 1;
            message = "webStack: at most one app can set 'default = true'.";
          }
          {
            assertion = 
              let
                domains = (map (a: a.domain) allApps)
                  ++ (lib.concatMap (a: a.aliases) allApps)
                  ++ (builtins.attrNames cfg.nginx.redirects)
                  ++ (lib.optional cfg.tunnel.ssh.enable cfg.tunnel.ssh.domain);
              in builtins.length (lib.unique domains) == builtins.length domains;
            message = ''
              webStack: Each service must have a unique domain.

              An alias counts: it is a name this machine answers on, so it
              shares the namespace with domains and redirects.
            '';
          }
          {
            assertion =
              builtins.length (lib.unique (map (a: a.name) allApps))
              == builtins.length allApps;
            message = "webStack: Each app must have a unique name.";
          }
          {
            assertion =
              let
                pairs = v: map (l: "${l.addr}:${toString l.port}") v.listen;
              in
              lib.all (
                v: builtins.length (lib.unique (pairs v)) == builtins.length (pairs v)
              ) (lib.attrValues config.services.nginx.virtualHosts);
            message =
              let
                dup = lib.filterAttrs (
                  _: v:
                  let
                    p = map (l: "${l.addr}:${toString l.port}") v.listen;
                  in
                  builtins.length (lib.unique p) != builtins.length p
                ) config.services.nginx.virtualHosts;
              in
              ''
                webStack: ${lib.concatStringsSep ", " (lib.attrNames dup)} listens on the same
                address twice. A kind = "profile" app whose module already serves TLS does not
                need tls = true here as well; that option is for one that does not.
              '';
          }
        ];

      security.acme = {
        acceptTerms = true;
        defaults.email = cfg.email;
      };

      services.nginx = {
        enable = cfg.nginx.enable || (cfg.tunnel.enable && cfg.tunnel.useNginx)
          || cfg.nginx.redirects != {};
        virtualHosts = lib.mkMerge [
          (mkIf (cfg.nginx.enable && managed cfg.nginx.apps != []) (
            listToAttrs (map (app: mkVHost { inherit app; enableACME = true; }) (managed cfg.nginx.apps))
          ))
          (mkIf (cfg.tunnel.enable && cfg.tunnel.useNginx) (
            listToAttrs (map (app: mkVHost { inherit app; enableACME = false; }) (managed cfg.tunnel.apps))
          ))
          # Profile apps own their vhost; we only add TLS to it.
          (listToAttrs (map (app: {
            name = app.domain;
            value = {
              enableACME = true;
              forceSSL = true;
              listen = [
                { addr = "0.0.0.0"; port = 443; ssl = true; }
                { addr = "[::]";    port = 443; ssl = true; }
              ];
            };
          }) (lib.filter (a: a.kind == "profile" && a.tls) (cfg.tunnel.apps ++ cfg.nginx.apps))))

          (listToAttrs (map (app: {
            name = app.domain;
            value = { default = true; };
          }) (lib.filter (a: a.kind == "profile" && a.default)
                (cfg.tunnel.apps ++ cfg.nginx.apps))))

          # A profile app's own module built the vhost, so the aliases go onto
          # it rather than into one of ours.
          (listToAttrs (map (app: {
            name = app.domain;
            value = {
              serverAliases = app.aliases;
            };
          }) (lib.filter (a: a.kind == "profile" && a.aliases != [ ])
                (cfg.tunnel.apps ++ cfg.nginx.apps))))

          (listToAttrs (map (app: {
            name = app.domain;
            value = {
              extraConfig = holdingConfig;
              locations = holdingLocation;
            };
          }) (lib.filter (a: a.kind == "profile")
                (cfg.tunnel.apps ++ cfg.nginx.apps))))

          (lib.mapAttrs (_: target: {
            enableACME = true;
            forceSSL = true;
            locations."/".return = "301 ${target}$request_uri";
          }) cfg.nginx.redirects)
        ];
      };

      services.cloudflared = mkIf cfg.tunnel.enable {
        enable = true;
        tunnels.${cfg.tunnel.name} = {
          credentialsFile = cfg.tunnel.credentials;
          ingress = mkMerge [
            (lib.listToAttrs (map (app: {
              name = app.domain;
              value = if cfg.tunnel.useNginx 
                then "http://${app.domain}" 
                else "http://localhost:${toString app.port}";
            }) cfg.tunnel.apps))
            (mkIf cfg.tunnel.ssh.enable (
              { "${cfg.tunnel.ssh.domain}" = "ssh://localhost:${toString cfg.tunnel.ssh.port}"; }
            ))
          ];
          default = "http_status:404";
        };
      };

      systemd.services = mkMerge [
        (listToAttrs (map (app:
          let
            pkg = resolvePackage app;
            bin = if app.binaryName == "" then "${app.name}-wrapped" else app.binaryName;
          in {
            name = app.name;
            value = {
              description = "${app.name} web";
              # `after` without `requires`: if postgres fails the app still starts
              # and retries, instead of waiting for an event systemd won't send.
              after = [ "network.target" ]
                ++ lib.optional (app.database != null) "postgresql.service";
              wantedBy = [ "multi-user.target" ];

              stopIfChanged = false;
              environment = app.environment;
              path = app.path;
              serviceConfig = mkMerge [
                {
                  User = cfg.manager;
                  ExecStart = "${pkg}/bin/${bin}${lib.optionalString (app.extraArgs != []) " ${lib.escapeShellArgs app.extraArgs}"}";
                  Restart = "always";
                }
                (mkIf (app.workDir != "") { WorkingDirectory = app.workDir; })
                (mkIf (app.environmentFile != null) { EnvironmentFile = app.environmentFile; })
              ];
            };
          }) (managed (cfg.tunnel.apps ++ cfg.nginx.apps))))

        (listToAttrs (map (app: {
          name = app.unit;
          value.stopIfChanged = false;
        }) (lib.filter (a: a.kind == "profile" && a.unit != null)
              (cfg.tunnel.apps ++ cfg.nginx.apps))))

        (listToAttrs (map (app: {
          name = if app.kind == "profile" then app.unit else app.name;
          value.serviceConfig.UMask = lib.mkForce app.umask;
        }) (lib.filter (a: a.umask != null && (a.kind != "profile" || a.unit != null))
              (cfg.tunnel.apps ++ cfg.nginx.apps))))
      ];
    };
  }
