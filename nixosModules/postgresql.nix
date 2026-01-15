{ config, pkgs, lib, ... }:
# This module configures PostgreSQL on NixOS
let
  inherit (lib) mkIf mkOption mkEnableOption types listToAttrs;
  cfg = config.postgresql;
in
{
  options.postgresql = {
    enable = mkEnableOption "PostgreSQL database server";
    package = mkOption {
      type = types.package;
      default = pkgs.postgresql_17;
    };
    port = mkOption {
      type = types.int;
      default = 5432;
    };

    initialSetup = {
      enable = mkOption {
        type = types.bool;
        default = false;
      };
      role = mkOption {
        type = types.str;
        default = "postgres";
      };
      passwordFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Path to a file containing the password for the initial role";
      };
      database = mkOption {
        type = types.str;
        default = "";
      };
    };

    dumpFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "SQL dump to restore if initialSetup is disabled";
    };

    tcp.enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable TCP/IP connections";
    };
    authMode = mkOption {
      type = types.enum [ "trust" "md5" "scram" ];
      default = "trust";
      description = "Authentication mode for local connections";
    };

    logStatements = mkOption {
      type = types.enum [ "all" "mod" "none" ];
      default = "none";
      description = "PostgreSQL log_statement level";
    };
  };
  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.initialSetup.enable -> (
          cfg.initialSetup.role != "" &&
          cfg.initialSetup.passwordFile != null &&
          cfg.initialSetup.database != ""
        );
        message = "postgresql.initialSetup requires role, passwordFile and database";
      }
      {
        assertion = !(cfg.initialSetup.enable && cfg.dumpFile != null);
        message = "postgresql: initialSetup and dumpFile can't be used together";
      }
    ];
    services.postgresql = {
      enable = true;
      package = cfg.package;
      settings.port = cfg.port;
      enableTCPIP = cfg.tcp.enable;

      authentication = pkgs.lib.mkOverride 10 ''
        local all all ${cfg.authMode}
        host all all ::1/128 ${cfg.authMode}
        host all all 127.0.0.1/32 ${cfg.authMode}
      '';
      settings.log_statement = cfg.logStatements;

      initialScript =
        if cfg.initialSetup.enable then
          pkgs.writeText "init.sql" ''
            DO $$
            BEGIN
              IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${cfg.initialSetup.role}') THEN
                CREATE ROLE ${cfg.initialSetup.role} LOGIN;
              END IF;
            END
            $$;

            \password ${cfg.initialSetup.role} < ${cfg.initialSetup.passwordFile};

            CREATE DATABASE ${cfg.initialSetup.database} OWNER ${cfg.initialSetup.role};

            DO $$
            BEGIN
              IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${cfg.initialSetup.role}') THEN
                GRANT ALL PRIVILEGES ON DATABASE ${cfg.initialSetup.database} TO ${cfg.initialSetup.role};
              END IF;
            END
            $$;
          ''
        else if cfg.dumpFile != null then
          pkgs.writeText "restore.sql" ''
            \i ${cfg.dumpFile}
          ''
        else
          null;
    };
  };
}