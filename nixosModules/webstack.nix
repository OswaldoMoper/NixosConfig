{ config, pkgs, lib, ... }:

let 
  inherit (lib) mkIf mkOption mkEnableOption types listToAttrs mkMerge;
  cfg = config.webStack;
  yesodApp = types.submodule {
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
      static = mkOption {
        type = types.str;
        description = "Static directory for the app";
      };
      package = mkOption {
        type = types.package;
        description = "Wrapped executable package for the app";
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
        type = types.listOf yesodApp;
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
        virtualHosts = lib.listToAttrs (map (app: {
          name = app.domain;
          value = {
            enableACME = (cfg.mode == "nginx");
            forceSSL = (cfg.mode == "nginx");
            locations."/" = {
              proxyPass = "http://localhost:${toString app.port}";
              proxyWebsockets = true;
            };
          };
        }) cfg.apps);
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

      systemd.services = listToAttrs (
        (map (app: {
          name = app.name;
          value = {
            description = "${app.name} web";
            after = [ "network.target" ];
            wantedBy = [ "multi-user.target" ];
            environment = {
              YESOD_STATIC_DIR = "${app.static}";
              YESOD_PORT = toString app.port;
              YESOD_APPROOT = "https://${app.domain}";
            };
            serviceConfig = {
              User = cfg.manager;
              WorkingDirectory = app.static;
              ExecStart = "${app.package}/bin/${app.name}-wrapped --verbose";
              Restart = "always";
            };
          };
        }) cfg.apps)
      );
    };
  }