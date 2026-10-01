{ lib, unitOf }:

{
  mkLocalRunApps =
    { pkgs, nixosConfigurations }:
    let
      forHost =
        hostName: hostConfig:
        let
          cfg = hostConfig.config;
          apps = if cfg ? webStack then cfg.webStack.tunnel.apps ++ cfg.webStack.nginx.apps else [ ];

          hasUnit = a: unitOf a != null && cfg.systemd.services ? ${unitOf a};

          pg = cfg.services.postgresql;
          ensure = lib.optionals (cfg ? postgresql && cfg.postgresql.enable) cfg.postgresql.ensure;
          secretValues = if cfg ? vm then cfg.vm.secretValues else { };

          stateDirsOf =
            svc:
            let
              sd = svc.serviceConfig.StateDirectory or null;
            in
            if sd == null then
              [ ]
            else if lib.isList sd then
              sd
            else
              lib.filter (s: s != "") (lib.splitString " " sd);

          spec = {
            host = hostName;
            postgres =
              if pg.enable then
                {
                  port = pg.settings.port or 5432;
                  databases = lib.unique pg.ensureDatabases;
                  roles = map (e: { inherit (e) database role; }) ensure;
                }
              else
                null;
            secrets = lib.mapAttrs (n: s: {
              inherit (s) path;
              value = secretValues.${n} or "";
            }) (if cfg ? age then cfg.age.secrets else { });
            skipped = map (a: a.name) (lib.filter (a: !(hasUnit a)) apps);
            units = map (
              a:
              let
                svc = cfg.systemd.services.${unitOf a};
              in
              {
                name = unitOf a;
                exec = toString (svc.serviceConfig.ExecStart or "");
                environment = lib.mapAttrs (_: toString) (lib.filterAttrs (_: v: v != null) svc.environment);
                environmentFile = svc.serviceConfig.EnvironmentFile or null;
                workingDirectory = svc.serviceConfig.WorkingDirectory or null;
                stateDirectory = stateDirsOf svc;
              }
            ) (lib.filter hasUnit apps);
          };

          runner = pkgs.writeShellApplication {
            name = "run-${hostName}-local";
            runtimeInputs =
              (with pkgs; [
                coreutils
                gawk
                gnugrep
                gnused
                jq
              ])
              ++ lib.optional pg.enable pg.package;
            text = ''
              export LOCAL_SPEC=${pkgs.writeText "run-${hostName}-local.json" (builtins.toJSON spec)}
              export LOCAL_SHELL=${pkgs.runtimeShell}

              ${builtins.readFile ../scripts/run-local.sh}
            '';
          };
        in
        lib.optionalAttrs (apps != [ ]) {
          "run-${hostName}-local" = {
            type = "app";
            program = lib.getExe runner;
          };
        };
    in
    lib.foldl' (acc: h: acc // forHost h nixosConfigurations.${h}) { } (
      lib.attrNames nixosConfigurations
    );
}
