{ config, options, lib, pkgs, ... }:

let
  inherit (lib) mkIf mkOption mkEnableOption types;
  cfg = config.watcher;

  watched = lib.filterAttrs (_: site: site.enable) cfg.sites;

  mailed = with cfg.alert;
    "{ ${pkgs.gnused}/bin/sed -e '$a\\' ${recipientsFile}; "
    + "printf 'Subject: %s: %s\\n\\n' \"$CATTLE_URL\" \"$CATTLE_VERDICT\"; ${pkgs.coreutils}/bin/cat; } "
    + "| ${pkgs.msmtp}/bin/msmtp -t --set-to-header=undisclosed_recipients"
    + lib.optionalString (passwordFile != null)
        " --passwordeval='${pkgs.coreutils}/bin/cat ${passwordFile}'";

  command = if cfg.alert.recipientsFile != null then mailed else cfg.alertCommand;

  entry = name: site: {
    appConfig = { name = "watch-" + builtins.replaceStrings [ "." ] [ "-" ] name; structure = "/var/empty"; };
    databaseConfig = { name = "none"; structure = "none"; };
    serviceConfig = {
      remoteHost = { hostName = "127.0.0.1"; userName = "nobody"; userHome = "/var/empty"; };
      keyDirectory = { name = "none"; structure = "/var/empty"; };
      deleteFrequency = { unit = "Days"; times = 30; };
      watch = { url = "https://${name}"; }
        // lib.optionalAttrs (!site.proxied && cfg.hostAddresses != [ ]) {
          addresses = cfg.hostAddresses;
        };
    };
  };
in
{
  options.watcher = {
    enable = mkEnableOption ''
      a cattleServer watch on every name in sites. Needs cattleServer's NixOS
      module imported by the host; this library does not bring it'';
    sites = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          enable = mkOption {
            type = types.bool;
            default = true;
            description = "Whether this name is watched, so one that something else declared can be left out.";
          };
          proxied = mkOption {
            type = types.bool;
            default = false;
            description = ''
              The name resolves to a proxy in front of this machine rather than
              to the machine, so it is not held to hostAddresses: demanding the
              machine's address of it would alert on every pass.
            '';
          };
        };
      });
      default = { };
      example = lib.literalExpression ''{ "example.org" = { }; "example.net".proxied = true; }'';
      description = ''
        The names watched, each asked over https the way a visitor would.
        webStack adds every name it serves; a host adds its own, and
        lib.mkForce replaces the lot.
      '';
    };
    hostAddresses = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "203.0.113.10" ];
      description = ''
        Addresses every site that is not proxied must resolve to. Empty accepts
        any, which leaves a name pointed somewhere else unnoticed.
      '';
    };
    alertCommand = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Shell command run once a name has failed its checks, with the detail on
        standard input. Null logs and never alerts. Excludes alert.recipientsFile.
      '';
    };
    alert = {
      recipientsFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "/run/agenix/watcher-recipients";
        description = ''
          Path on the machine to mail headers naming who is alerted, such as
          `Bcc: a@example.org, b@example.org`, and nothing else: no blank line.
          Read when an alert goes out, so it can be a secret the service user
          reads. Sent through the system msmtp account; every recipient sees
          only `undisclosed-recipients`.
        '';
      };
      passwordFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Path on the machine to the SMTP password, readable by the service
          user. Null keeps the msmtp account's own.
        '';
      };
    };
  };

  config = lib.mkMerge [
    {
      assertions = lib.optionals cfg.enable [
        {
          assertion = options ? services.cattleServer;
          message = "watcher writes services.cattleServer, so the host has to import cattleServer's NixOS module (inputs.cattleServer.nixosModules.default).";
        }
        {
          assertion = cfg.alertCommand == null || cfg.alert.recipientsFile == null;
          message = "watcher: set alertCommand or alert.recipientsFile, not both; the second builds the first.";
        }
        {
          assertion = cfg.alert.passwordFile == null || cfg.alert.recipientsFile != null;
          message = "watcher.alert.passwordFile is only read with alert.recipientsFile.";
        }
      ];
    }

    (lib.optionalAttrs (options ? services.cattleServer) {
      services.cattleServer = mkIf cfg.enable {
        enable = true;
        settings = {
          localHost = {
            hostName = config.networking.hostName;
            userName = config.services.cattleServer.user;
            userHome = config.services.cattleServer.stateDir;
          };
          alertCommand = command;
          apps = lib.mapAttrsToList entry watched;
        };
      };
    })
  ];
}
