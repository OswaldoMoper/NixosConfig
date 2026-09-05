{ config, pkgs, lib, inputs, ... }:

let 
  inherit (lib) mkIf mkOption mkEnableOption types listToAttrs mkMerge;
  cfg = config.webStack;

  managed = lib.filter (app: app.kind == "managed");

  resolvePackage = app:
    if lib.isDerivation app.package
    then app.package
    else if (lib.isAttrs app.package  && app.package ? packages)
    then
      let
        system = pkgs.stdenv.hostPlatform.system;
        wrapperName = "${app.name}-wrapper";
      in
        app.package.packages.${system}.${wrapperName}
        or app.package.packages.${system}.${app.name}
        or (throw "Package '${app.name}' or '${wrapperName}' was not found in the input of ${app.name}")
    else throw "The value provided in 'package' for ${app.name} is not valid.";

  mkVHost = {app, enableACME ? false}: {
    name = app.domain;
    value = {
      inherit enableACME;
      inherit (app) default;
      forceSSL = enableACME;
      locations."/" = {
        proxyPass = "http://localhost:${toString app.port}";
        proxyWebsockets = true;
      };
    };
  };

  webApp = types.submodule {
    options = {
      kind = mkOption {
        type = types.enum [ "managed" "profile" ];
        default = "managed";
        description = ''
          "managed": webStack generates the systemd unit and the nginx virtualHost.

          "profile": the app ships its own NixOS module (services.<app>.profile),
          which owns the unit and the vhost. webStack only contributes the
          non-nginx edge — tunnel ingress, firewall, ACME email — and keeps the
          app inside the global uniqueness assertions.
        '';
      };
      name = mkOption {
        type = types.str;
        description = "Internal Service Name";
      };
      unit = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "moperapp";
        description = ''
          systemd unit this app runs as. Defaults to 'name' for kind =
          "managed", which is the unit webStack itself generates.

          For kind = "profile" the app's own module names the unit, and the
          name need not match: an app called MoperApp runs as moperapp.
          Nothing here can derive it, so a host that wants tooling to reach a
          profile app's unit says so here.
        '';
      };
      domain = mkOption {
        type = types.str;
        description = "Public domain for the app";
      };
      port = mkOption {
        type = types.port;
        description = "Internal port the app listens on";
      };
      package = mkOption {
        type = types.nullOr (types.oneOf [ types.package types.attrs ]);
        default = null;
        description = "Derivation or Flake Input from which to extract the app wrapper. Unused when kind = \"profile\".";
      };
      binaryName = mkOption {
        type = types.str;
        default = "";
        description = "If default, will use '{name}-wrapped'";
      };
      extraArgs = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Extra command-line arguments passed to the app binary";
      };
      environment = mkOption {
        type = types.attrsOf (types.nullOr (types.oneOf [
          types.str
          types.path
          types.package
        ]));
        default = {};
        description = ''
          Environment variables for the app (same type as systemd.services.environment).
          These end up in the unit file, which is world-readable in the nix store,
          so secrets belong in 'environmentFile' instead.
        '';
      };
      environmentFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "/run/agenix/myapp-env";
        description = ''
          Path on the target host to a file of KEY=value lines, read by systemd at
          start time. Unlike 'environment' it never enters the nix store, so this is
          where passwords and tokens go.
        '';
      };
      path = mkOption {
        type = types.listOf (types.oneOf [
          types.path
          types.str
        ]);
        default = [];
        description = "Packages added to the app's 'PATH' environment variable. Both the 'bin' and 'sbin' subdirectories of each package are added.";
      };
      workDir = mkOption {
        type = types.str;
        default = "";
        example = "/home/myapp/myapp";
        description = ''
          WorkingDirectory for the unit. Empty leaves it unset, so the app
          starts in `/`.

          That matters more than it looks: an app that opens a path relative to
          its own directory resolves it against `/`, where the manager account
          cannot write, and the unit dies with no obvious cause. If the app
          reads or writes anything by a relative path, set this.

          systemd fails a unit whose WorkingDirectory does not exist, so a host
          that sets this usually wants a tmpfiles rule beside it.
        '';
      };
      tls = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Serve the app over TLS with an ACME certificate.

          For kind = "profile" this enables enableACME, forceSSL and the 443
          listener on the virtualHost the app's own module created, without
          taking over its locations. "managed" apps in nginx.apps already get
          this from webStack, so it is only meaningful for profiles.
        '';
      };
      default = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Make this app's virtualHost nginx's default_server.

          Without one, nginx serves the first server block to a request whose
          Host matches nothing, and the blocks come out in attribute order:
          an unknown name, or a request to the bare IP, reaches whichever app
          sorts first alphabetically rather than the site you meant.
        '';
      };
      database = mkOption {
        type = types.nullOr (types.submodule {
          options = {
            name = mkOption {
              type = types.str;
              description = "PostgreSQL database the app connects to.";
            };
            user = mkOption {
              type = types.str;
              description = "PostgreSQL role the app connects as.";
            };
            passwordFile = mkOption {
              type = types.nullOr types.str;
              default = null;
              example = "/run/agenix/myapp-db-password";
              description = ''
                Path on the target host to a file holding the role's password.
                A string rather than a path, so a path literal cannot copy the
                secret into the world-readable nix store.

                Null leaves the role's password alone, which is what
                postgresql.authMode = "trust" wants. Set it and the database
                reconciles the role to that value on every activation.

                The same value usually has to reach the app too, through
                'environmentFile'. Setting only one of the two leaves the app
                sending a password the cluster does not have, which reads as
                the database rejecting it rather than as a missing pair.
              '';
            };
          };
        });
        default = null;
        example = { name = "myapp"; user = "myapp"; };
        description = ''
          Declares that the app needs the host's PostgreSQL. Today this orders the
          unit after postgresql.service and lets the pre-deploy checks verify that
          'environment' really carries these names. Provisioning the role and the
          database from here is the next step.
        '';
      };
    };
  };
in
  {
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
      postgresql.ensure = map (a: {
        database = a.database.name;
        role = a.database.user;
        inherit (a.database) passwordFile;
      }) (lib.filter (a: a.database != null) (cfg.tunnel.apps ++ cfg.nginx.apps));

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
            assertion = lib.all (a: !a.default || a.kind == "managed") allApps;
            message = ''
              webStack: 'default = true' only reaches nginx on a kind = "managed"
              app, because webStack does not build the virtualHost of a profile.
              Set default_server in the app's own module instead.
            '';
          }
          {
            assertion = 
              let
                domains = (map (a: a.domain) allApps)
                  ++ (builtins.attrNames cfg.nginx.redirects)
                  ++ (lib.optional cfg.tunnel.ssh.enable cfg.tunnel.ssh.domain);
              in builtins.length (lib.unique domains) == builtins.length domains;
            message = "webStack: Each service must have a unique domain.";
          }
          {
            assertion =
              builtins.length (lib.unique (map (a: a.name) allApps)) 
              == builtins.length allApps;
            message = "webStack: Each app must have a unique name.";
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
      ];
    };
  }