{ config, options, pkgs, lib, inputs, ... }:

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
      serverAliases = app.aliases;
      locations."/" = {
        proxyPass = "http://localhost:${toString app.port}";
        proxyWebsockets = true;
        # Without these the app is told it was reached over plain http at
        # localhost, so it cannot tell which of its names the visitor typed.
        recommendedProxySettings = true;
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
      profile = mkOption {
        type = types.nullOr (types.submodule {
          options = {
            attr = mkOption {
              type = types.str;
              example = "moperapp";
              description = ''
                The attribute under `services` where this app's module lives.
                Stated for the same reason `unit` is: an app called MoperApp
                declares `services.moperapp.profile`, and no rule turns one into
                the other.
              '';
            };
            module = mkOption {
              type = types.nullOr types.deferredModule;
              default = null;
              description = "The app's own NixOS module, so the host does not import it separately.";
            };
            settings = mkOption {
              type = types.attrs;
              default = { };
              example = { mode = "production"; };
              description = ''
                Everything the app's module needs that webStack cannot know.
                What webStack derives — see `webStack.profiles` — must not
                appear here: two definitions of one option is an error.
              '';
            };
          };
        });
        default = null;
        description = ''
          Data for `lib.appModules`, which turns this entry into the app's own
          module and its settings. This module only declares it.

          Nothing here writes to `services.<attr>.profile`, and that is not an
          oversight: building an option PATH out of an option VALUE makes the
          module system evaluate `config` to learn which options exist, which is
          its own fixpoint. Measured, as infinite recursion.

          `lib.appModules` is outside that fixpoint, so it can. The host passes
          it the same list it assigns here:

              let apps = [ … ]; in {
                imports = [ … ] ++ nixosConfig.lib.appModules apps;
                webStack.nginx.apps = apps;
              }

          One list, written once, read twice.
        '';
      };
      secrets = mkOption {
        type = types.attrsOf types.attrs;
        default = { };
        example = {
          moperapp-env = {
            file = ./secrets/moperapp-env.age;
            vmValue = "MOPERAPP_PGPASS=vmtest";
          };
        };
        description = ''
          agenix secrets this app needs, keyed as `age.secrets` keys them.

          They live here rather than in a separate `age.secrets` block so that
          everything about one app is in one place. A host that spreads an app
          over four top-level attributes has four places to keep in step, and
          nothing tells it when one falls behind.

          One key is not agenix's: `vmValue`. It is stripped before the rest is
          handed over, and becomes this secret's stand-in inside
          `run-<host>-vm`, which cannot decrypt anything because the ciphertext
          is bound to the real host's key.

          It sits next to the secret it stands for, rather than in a list at
          host level, for the reason the rest of this entry exists: the day the
          secret is renamed, both move together or neither does. A stand-in that
          quietly stops matching is worse than none, because the rehearsal still
          passes — it just stops rehearsing the case production has.
        '';
      };
      directories = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "d /upload 0755 admin users -" ];
        description = ''
          systemd-tmpfiles rules for the directories this app owns, in tmpfiles
          syntax.

          Two rules of the same TYPE for the same path do NOT merge: systemd
          keeps one, warns about the other, and which one survives depends on
          the order of the generated file. Two apps that share a directory
          therefore need one rule between them, plus a rule of a different type
          — `z` adjusts a path without recursing — for whatever else differs.
        '';
      };
      aliases = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "moperapp.net" ];
        description = ''
          Other names that serve THIS app, not a redirect to it: they reach the
          same vhost and the certificate covers them.

          The difference from `redirects` is what the visitor ends up on. An
          alias keeps the name they typed; a redirect sends them to `domain`.
          Both are legitimate and a host usually wants one of each — the `.net`
          that should behave like the `.org`, and the `www.` that should not.

          They count towards the same uniqueness assertions as `domain`, which
          is the point: an alias is a name this machine answers on, so two apps
          claiming one is the collision those assertions exist to catch.

          NixOS puts `serverAliases` into the certificate itself — measured in
          nixpkgs, `nginx/default.nix` sets `extraDomainNames` from them — so
          **each alias needs its own DNS record pointing here first**. A name
          that does not resolve fails the order for the whole certificate, not
          just for itself.
        '';
      };
      redirects = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "www.moperapp.org" ];
        description = ''
          Names that should 301 to this app's own domain.

          The general form stays `webStack.nginx.redirects`, which points
          anywhere. This is the common case — a bare `www` — expressed where the
          app is, because that is the one a host forgets to move when the app's
          domain changes.
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

          A `profile` app can take it too. default_server is a flag nginx puts
          on each of a virtualHost's listen directives, so it does not matter
          who wrote them: webStack merges the flag onto the app's own vhost
          the same way it merges the aliases.
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
            provision = mkOption {
              type = types.bool;
              default = true;
              description = ''
                Whether webStack should be the one to create this database and
                role, through `postgresql.ensure`.

                False when something else already does — typically a
                `kind = "profile"` app whose own module declares
                `ensureDatabases`, or a second app on the same database. The
                entry stays because it is what the assertions read: declaring a
                database is how an app says which one it needs, and that is
                worth checking whoever creates it.

                Two provisioners for one database is what this exists to avoid.
                It is not a harmless duplicate: each writes ownership and the
                role's password on every activation, in an order nothing fixes.
              '';
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
      # `options ? age` guards the attribute so a host without agenix still
      # evaluates, which is how the app modules guard theirs.
      age = lib.mkIf (options ? age) {
        secrets = lib.mkMerge (map
          (a: lib.mapAttrs (_: s: removeAttrs s [ "vmValue" ]) a.secrets)
          (cfg.tunnel.apps ++ cfg.nginx.apps));
      };

      vm.secretValues = lib.mkMerge (map
        (a: lib.mapAttrs (_: s: s.vmValue) (lib.filterAttrs (_: s: s ? vmValue) a.secrets))
        (cfg.tunnel.apps ++ cfg.nginx.apps));

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

      postgresql.ensure = map (a: {
        database = a.database.name;
        role = a.database.user;
        inherit (a.database) passwordFile;
      }) (lib.filter (a: a.database != null && a.database.provision)
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