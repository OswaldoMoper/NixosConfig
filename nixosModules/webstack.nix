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
      mode = mkOption {
        type = types.enum ["tunnel" "nginx"];
        default = "tunnel";
        description = "Hosting mode: cloudflared tunnel or pure nginx";
      };
      tunnelName = mkOption {
        type = types.str;
        default = "main";
      };
      tunnelCredentials = mkOption {
        type = types.str;
        default = "/etc/.cloudflared/uuid.json";
      };
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
      apps = mkOption {
        type = types.listOf webApp;
        default = [];
        description = "List of web apps";
      };
    };

    config = mkIf cfg.enable {
      assertions = [
        {
          assertion = cfg.email != "";
          message = "webStack requires a valid email";
        }
        {
          assertion = cfg.apps != [];
          message = "webStack requires at least one app";
        }
        {
          assertion =
            builtins.length (lib.unique (map (a: a.port) cfg.apps))
            == builtins.length cfg.apps;
          message = "webStack apps must have unique ports";
        }
      ];

      security.acme = {
        acceptTerms = true;
        defaults.email = cfg.email;
      };

      services.nginx = {
        enable = true;
        virtualHosts =
          (lib.listToAttrs (map (app: {
            name = app.domain;
            value = {
              enableACME = (cfg.mode == "nginx");
              forceSSL = (cfg.mode == "nginx");
              locations."/" = {
                proxyPass = "http://localhost:${toString app.port}";
                proxyWebsockets = true;
              };
            };
          }) cfg.apps));
      };

      services.cloudflared = mkIf (cfg.mode == "tunnel") {
        enable = true;
        tunnels.${cfg.tunnelName} = {
          credentialsFile = cfg.tunnelCredentials;
          ingress = 
            (lib.listToAttrs (map (app: {
              name = app.domain;
              value = "http://localhost:${toString app.port}";
            }) cfg.apps));
          default = "http_status:404";
        };
      };

      systemd.services = (listToAttrs (
        (map (app:
        let pkg = resolvePackage app;
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
              ExecStart = "${pkg}/bin/${app.name}-wrapped --verbose";
              Restart = "always";
            };
          };
        }) cfg.apps))
      );
    };
  }