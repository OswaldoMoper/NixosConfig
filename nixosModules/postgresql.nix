{ config, pkgs, lib, ... }:
# This module configures PostgreSQL on NixOS
let
  inherit (lib) mkIf mkOption mkEnableOption types;
  cfg = config.postgresql;

  # "scram" is not a pg_hba method; the real spelling is scram-sha-256.
  authMethod = if cfg.authMode == "scram" then "scram-sha-256" else cfg.authMode;

  entries =
    cfg.ensure
    ++ lib.optional cfg.initialSetup.enable {
      inherit (cfg.initialSetup) database role passwordFile;
      owner = true;
    };

  quoted = s: ''"${s}"'';
in
{
  options.postgresql = {
    enable = mkEnableOption "PostgreSQL database server";
    package = mkOption {
      type = types.package;
      default = pkgs.postgresql_17;
    };
    port = mkOption {
      type = types.port;
      default = 5432;
    };

    ensure = mkOption {
      default = [ ];
      example = [ { database = "myapp"; role = "myapp"; } ];
      description = ''
        Databases and roles that must exist, with the role owning its database.

        Additive only: it never drops or renames anything it does not know
        about, because a machine that predates this config holds databases
        nothing declares.

        Creation goes through services.postgresql.ensureDatabases and
        ensureUsers, which create when absent and do nothing when present. The
        rest is reconciled on every activation by postgresql-ensure.service,
        deliberately its own unit rather than a postgresql-setup.postStart
        fragment: that hook is a single script shared with any other module that
        appends to it, so one failure there would silently skip the rest.
      '';
      type = types.listOf (types.submodule {
        options = {
          database = mkOption {
            type = types.str;
            description = "Database that must exist.";
          };
          role = mkOption {
            type = types.str;
            description = "Role that must exist, and that the app connects as.";
          };
          owner = mkOption {
            type = types.bool;
            default = true;
            description = ''
              Make the role own the database.

              Upstream's ensureDBOwnership only covers a database named after
              its role, which the historical pairs here are not, so ownership is
              transferred explicitly.
            '';
          };
          passwordFile = mkOption {
            type = types.nullOr types.str;
            default = null;
            example = "/run/agenix/myapp-db-password";
            description = ''
              Path on the target host to a file holding the role's password. A
              string rather than a path, so a path literal cannot copy the secret
              into the world-readable nix store.

              Null leaves the role's password alone, which is what authMode =
              "trust" wants. The unit reads this as root, so the file does not
              have to be readable by postgres.
            '';
          };
        };
      });
    };

    initialSetup = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          The single-pair form of `ensure`, kept for compatibility and stricter:
          it requires a password file where `ensure` allows none.

          The name misleads. Its SQL runs on every activation, not only the
          first.
        '';
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
      description = ''
        Authentication mode for local connections. "scram" is emitted as
        scram-sha-256, which is what pg_hba actually accepts.
      '';
    };

    logStatements = mkOption {
      type = types.enum [ "all" "mod" "none" ];
      default = "none";
      description = "PostgreSQL log_statement level";
    };
  };
  config = mkIf cfg.enable {
    warnings = lib.optional cfg.initialSetup.enable ''
      postgresql.initialSetup is the single-pair form of postgresql.ensure, and
      its name misleads: the SQL runs on every activation, not only the first.
      Prefer postgresql.ensure, which expresses more than one pair and does not
      require a password file.
    '';

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
      {
        assertion = lib.all (e: e.database != "" && e.role != "") entries;
        message = "postgresql.ensure: every entry needs a database and a role";
      }
      {
        assertion =
          let names = map (e: e.database) entries;
          in lib.length (lib.unique names) == lib.length names;
        message = "postgresql.ensure: two entries name the same database, so they would fight over its owner";
      }
      {
        assertion =
          let
            all = config.services.postgresql.ensureDatabases;
            twice = lib.filter (d: lib.count (x: x == d) all > 1) (map (e: e.database) entries);
          in
          twice == [ ];
        message = "postgresql.ensure: a database here is already declared by another module in services.postgresql.ensureDatabases";
      }
    ];

    services.postgresql = {
      enable = true;
      package = cfg.package;
      settings.port = cfg.port;
      enableTCPIP = cfg.tcp.enable;

      authentication = pkgs.lib.mkOverride 10 ''
        local all all ${authMethod}
        host all all ::1/128 ${authMethod}
        host all all 127.0.0.1/32 ${authMethod}
      '';
      settings.log_statement = cfg.logStatements;

      ensureDatabases = map (e: e.database) entries;
      ensureUsers = map (e: { name = e.role; }) entries;

      initialScript =
        if cfg.dumpFile != null then
          pkgs.writeText "restore.sql" ''
            \i ${cfg.dumpFile}
          ''
        else
          null;
    };

    systemd.services.postgresql-ensure = mkIf (entries != [ ]) {
      description = "Reconcile the roles and databases postgresql.ensure declares";
      after = [ "postgresql-setup.service" ];
      requires = [ "postgresql-setup.service" ];
      wantedBy = [ "multi-user.target" ];
      path = [ cfg.package pkgs.util-linux pkgs.coreutils ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = lib.concatMapStringsSep "\n" (
        e:
        let
          setPassword = pkgs.writeText "ensure-${e.role}-password.sql" ''
            ALTER USER ${quoted e.role} WITH PASSWORD :'pw';
          '';
        in
        lib.optionalString e.owner ''
          runuser -u postgres -- psql -v ON_ERROR_STOP=1 -d postgres \
            -c 'ALTER DATABASE ${quoted e.database} OWNER TO ${quoted e.role}'
        ''
        + lib.optionalString (e.passwordFile != null) ''
          # An unreadable or empty file must stop the unit: psql treats an empty
          # password as "clear it", so without this the role silently loses its
          # password and every client that authenticates starts failing.
          if ! pw="$(cat ${e.passwordFile})" || [ -z "$pw" ]; then
            echo "postgresql.ensure: ${e.passwordFile} is unreadable or empty" >&2
            exit 1
          fi
          runuser -u postgres -- psql -v ON_ERROR_STOP=1 -d postgres \
            -v pw="$pw" -f ${setPassword}
        ''
      ) entries;
    };
  };
}
