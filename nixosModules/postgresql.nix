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
        type = types.nullOr types.str;
        default = null;
        example = "/run/agenix/myapp-db-password";
        description = ''
          Path on the target host to a file holding the role's password. A string
          rather than a path, so a path literal cannot copy the secret into the
          world-readable nix store.

          postgresql-setup runs as the postgres user, so the file has to be
          readable by it: an agenix secret needs owner = "postgres".
        '';
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

      ensureDatabases = lib.optional cfg.initialSetup.enable cfg.initialSetup.database;
      ensureUsers = lib.optional cfg.initialSetup.enable { name = cfg.initialSetup.role; };

      initialScript =
        if cfg.dumpFile != null then
          pkgs.writeText "restore.sql" ''
            \i ${cfg.dumpFile}
          ''
        else
          null;
    };

    systemd.services.postgresql-setup.postStart = mkIf cfg.initialSetup.enable (
      lib.mkAfter ''
        # An unreadable or empty file must stop the unit: psql treats an empty
        # password as "clear it", so without this the role silently loses its
        # password and every client that authenticates starts failing.
        if ! pw="$(${pkgs.coreutils}/bin/cat ${cfg.initialSetup.passwordFile})" || [ -z "$pw" ]; then
          echo "postgresql: ${cfg.initialSetup.passwordFile} is unreadable or empty" >&2
          echo "postgresql-setup runs as postgres, so the file must be readable by it" >&2
          exit 1
        fi
        ${cfg.package}/bin/psql -v ON_ERROR_STOP=1 -d postgres -v pw="$pw" <<'SQL'
        ALTER USER ${cfg.initialSetup.role} WITH PASSWORD :'pw';
        ALTER DATABASE ${cfg.initialSetup.database} OWNER TO ${cfg.initialSetup.role};
        SQL
      ''
    );
  };
}