{ lib, pkgs }:

let
  inherit (lib) mkOption types;
in
rec {
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

  holdingPage = pkgs.writeTextDir "__unavailable.html" ''
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta http-equiv="refresh" content="3">
    <title>Back in a moment</title>
    <style>
      html { color-scheme: light dark; }
      body { margin: 0; min-height: 100vh; display: grid; place-items: center;
             font: 16px/1.6 system-ui, sans-serif; padding: 16px; }
      main { max-width: 26rem; text-align: center; }
      h1 { font-size: 1.25rem; margin: 0 0 .5rem; }
      p { margin: 0; opacity: .75; }
    </style>
    </head>
    <body>
    <main>
      <h1>Back in a moment</h1>
      <p>This page is being updated and will reload by itself.</p>
    </main>
    </body>
    </html>
  '';

  holdingConfig = "error_page 502 503 504 =503 /__unavailable.html;";

  holdingLocation = {
    "= /__unavailable.html" = {
      root = holdingPage;
      extraConfig = ''
        internal;
        add_header Retry-After 5 always;
      '';
    };
  };

  mkVHost = {app, enableACME ? false}: {
    name = app.domain;
    value = {
      inherit enableACME;
      inherit (app) default;
      forceSSL = enableACME;
      serverAliases = app.aliases;
      extraConfig = holdingConfig;
      locations = holdingLocation // {
        "/" = {
          # Not "localhost", which resolves to both 127.0.0.1 and [::1]: an app
          # listening only on IPv4 makes nginx spend a refused connect on half
          # the requests before it retries the address that works.
          proxyPass = "http://127.0.0.1:${toString app.port}";
          proxyWebsockets = true;
          # Without these the app is told it was reached over plain http at
          # localhost, so it cannot tell which of its names the visitor typed.
          recommendedProxySettings = true;
        };
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
      umask = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "0007";
        description = ''
          UMask for the app's unit, which decides what an app that WRITES into
          a shared directory leaves behind. null keeps whatever the unit
          already has.

          An app hardened with UMask=0077 creates every file and directory
          readable by nobody but itself, so a second app reading the same
          directory is denied — and one that scans that directory at startup
          does not degrade, it fails to start. The group the two apps share
          cannot help, because the mode never grants the group anything.

          Set on the app that writes, not on the one that reads, and only as
          wide as the sharing needs: 0007 keeps everyone outside the group out.

          For kind = "profile" this overrides what the app's own module set,
          which is the only way to reach it from here.
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
}
