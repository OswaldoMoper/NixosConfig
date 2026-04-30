{ config, pkgs, lib, inputs, ... }:

let 
  inherit (lib) mkIf mkOption mkEnableOption types listToAttrs mkMerge;
  cfg = config.webStack;

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
        or (throw "Package '${app.name}' or '${wrapperName}' was not fount in the input of ${app.name}")
    else throw "The value provided in 'package' for ${app.name} is not valid.";

  mkVHost = {app, enableACME ? false}: {
    name = app.domain;
    value = {
      inherit enableACME;
      forceSSL = enableACME;
      locations."/" = {
        proxyPass = "http://localhost:${toString app.port}";
        proxyWebsockets = true;
      };
    };
  };

  webApp = types.submodule {
    options = {
      name = mkOption {
        type = types.str;
        description = "Internal Service Name";
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
        type = types.oneOf [ types.package types.attrs ];
        description = "Derivation or Flake Input from which to extract the app wrapper";
      };
      binaryName = mkOption {
        type = types.str;
        default = "";
        description = "If default, will use '{name}-wrapped'";
      };
      environment = mkOption {
        type = types.attrsOf (types.nullOr (types.oneOf [
          types.str
          types.path
          types.package
        ]));
        default = {};
        description = "Environment variables for the app (same type as systemd.services.environment)";
      };
      path = mkOption {
        type = types.listOf (types.oneOf [
          types.path
          types.str
        ]);
        default = [];
        description = "Packages added to the app's 'PATH' environment variable. Both the 'bin' and 'sbin' subdirectories of each package are added.";
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
      };
    };

    config = mkIf cfg.enable {
      assertions = let allApps = cfg.tunnel.apps ++ cfg.nginx.apps;
        in [
          {
            assertion = cfg.email != "";
            message = "webStack requires a valid email";
          }
          {
            assertion = allApps != [];
            message = "webStack requires at least one app";
          }
          {
            assertion = cfg.tunnel.enable -> cfg.tunnel.apps != [];
            message = "webStack: Cloudflare Tunnel is enabled but no apps are defined in 'tunnel.apps'.";
          }
          {
            assertion = cfg.nginx.enable -> cfg.nginx.apps != [];
            message = "webStack: Nginx stack is enabled but no apps are defined in 'nginx.apps'.";
          }
          {
            assertion =
              builtins.length (lib.unique (map (a: a.port) (cfg.tunnel.apps ++ cfg.nginx.apps)))
              == builtins.length allApps;
            message = "webStack apps must have unique ports";
          }
          {
            assertion = 
              builtins.length (lib.unique (map (a: a.domain) allApps)) 
              == builtins.length allApps;
            message = "webStack: Each app must have a unique domain."; 
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
        enable = cfg.nginx.apps != [] || (cfg.tunnel.enable && cfg.tunnel.useNginx);
        virtualHosts = 
          (listToAttrs (map (app: mkVHost { inherit app; enableACME = true; }) cfg.nginx.apps)) //
          (mkIf cfg.tunnel.useNginx (listToAttrs (map (app: mkVHost { inherit app; enableACME = false; }) cfg.tunnel.apps)));
      };

      services.cloudflared = mkIf cfg.tunnel.enable {
        enable = true;
        tunnels.${cfg.tunnel.name} = {
          credentialsFile = cfg.tunnel.credentials;
          ingress = 
            (lib.listToAttrs (map (app: {
              name = app.domain;
              value = if cfg.tunnel.useNginx 
                then "http://${app.domain}" 
                else "http://localhost:${toString app.port}";
            }) cfg.tunnel.apps));
          default = "http_status:404";
        };
      };

      systemd.services = (listToAttrs (
        (map (app:
        let
          pkg = resolvePackage app;
          bin = if app.binaryName == "" then "${app.name}-wrapped" else app.binaryName;
        in {
          name = app.name;
          value = {
            description = "${app.name} web";
            after = [ "network.target" ];
            wantedBy = [ "multi-user.target" ];
            environment = app.environment;
            path = app.path;
            serviceConfig = {
              User = cfg.manager;
              ExecStart = "${pkg}/bin/${bin} --verbose";
              Restart = "always";
            };
          };
        }) (cfg.tunnel.apps ++ cfg.nginx.apps)))
      );
    };
  }