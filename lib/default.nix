{ lib }:

let
  # A managed app is its own unit; a profile app is named by the module that
  # ships it, and the two need not match, so nothing here can derive it.
  unitOf = a: if a.unit != null then a.unit else (if a.kind == "managed" then a.name else null);
in
{
  mkPreDeployApps =
    {
      pkgs,
      nixosConfigurations,
      deployPkg ? null,
    }:
    let
      sshUserOf =
        node:
        let
          profiles = lib.attrValues node.profiles;
        in
        if node.profiles ? system then
          node.profiles.system.sshUser
        else if profiles != [ ] then
          (lib.head profiles).sshUser
        else
          "root";

      forHost =
        hostName: hostConfig:
        let
          cfg = hostConfig.config;
          nodes = if cfg ? deployment then cfg.deployment else { };
          apps = if cfg ? webStack then cfg.webStack.tunnel.apps ++ cfg.webStack.nginx.apps else [ ];
          hmUsers = if cfg ? myUsers then lib.filter (n: cfg.myUsers.${n}.home.enable) (lib.attrNames cfg.myUsers) else [ ];
          units =
            # Every app, not only the ones webStack builds the unit for: a
            # profile app's unit was the one nothing verified.
            lib.filter (u: u != null) (map unitOf apps)
            ++ map (u: "home-manager-${u}") hmUsers
            # A host whose whole job is CI serves no app and has no home-manager
            # user, so without this its verify step passes while the one thing
            # it exists to run is dead.
            ++ map (n: "github-runner-${n}") (
              lib.attrNames (cfg.services.github-runners or { })
            );
          ensure = lib.optionals (cfg ? postgresql && cfg.postgresql.enable) cfg.postgresql.ensure;
          databases = lib.unique (
            map (a: a.database.name) (lib.filter (a: a.database != null) apps)
            ++ lib.optionals pg.enable pg.ensureDatabases
          );
          owners = map (e: "${e.database}=${e.role}") (lib.filter (e: e.owner) ensure);
          pg = cfg.services.postgresql;

          liveCheck =
            nodeName: node: mode:
            pkgs.writeShellApplication {
              name = "${mode}-${nodeName}-live";
              runtimeInputs = with pkgs; [ coreutils gnugrep openssh ];
              excludeShellChecks = [ "SC2029" ];
              text = ''
                # Host and user stay overridable so the checks can be pointed at
                # a staging box, or at localhost to exercise the script itself.
                #
                # GATE_SSH_USER is honoured too: it is the name the README gives
                # for "deploy as yourself", and running a check on its own with
                # only that set used to fall back to the node's declared user and
                # fail as root, which reads as a dead host.
                : "''${LIVE_HOST:=${node.hostname}}"
                : "''${LIVE_SSH_USER:=''${GATE_SSH_USER:-${sshUserOf node}}}"
                : "''${LIVE_SSH_CONFIG:=''${GATE_SSH_CONFIG:-}}"
                export LIVE_HOST LIVE_SSH_USER LIVE_SSH_CONFIG
                export LIVE_MODE=${lib.escapeShellArg mode}
                export LIVE_NODE=${lib.escapeShellArg nodeName}
                export LIVE_PG_MAJOR=${
                  lib.escapeShellArg (if pg.enable then lib.versions.major pg.package.version else "")
                }
                export LIVE_DATA_DIR=${
                  lib.escapeShellArg (if pg.enable then pg.dataDir else "")
                }
                export LIVE_UNITS=${lib.escapeShellArg (lib.concatStringsSep " " units)}
                export LIVE_DATABASES=${lib.escapeShellArg (lib.concatStringsSep " " databases)}
                export LIVE_DB_OWNERS=${lib.escapeShellArg (lib.concatStringsSep " " owners)}

                ${builtins.readFile ../scripts/live-checks.sh}
              '';
            };

          accessGuard =
            nodeName: node:
            pkgs.writeShellApplication {
              name = "pre-deploy-${nodeName}-access";
              runtimeInputs = with pkgs; [ coreutils openssh ];
              excludeShellChecks = [ "SC2029" ];
              text = ''
                : "''${ACCESS_HOST:=${node.hostname}}"
                : "''${ACCESS_SSH_USER:=''${GATE_SSH_USER:-${sshUserOf node}}}"
                : "''${ACCESS_SSH_CONFIG:=''${GATE_SSH_CONFIG:-}}"
                export ACCESS_HOST ACCESS_SSH_USER ACCESS_SSH_CONFIG
                export ACCESS_NODE=${lib.escapeShellArg nodeName}

                ${builtins.readFile ../scripts/access-guard.sh}
              '';
            };

          freshnessGuard =
            nodeName:
            pkgs.writeShellApplication {
              name = "pre-deploy-${nodeName}-fresh";
              runtimeInputs = with pkgs; [
                coreutils
                git
              ];
              text = ''
                : "''${FRESH_FLAKE:=''${GATE_FLAKE:-.}}"
                export FRESH_FLAKE
                export FRESH_NODE=${lib.escapeShellArg nodeName}

                ${builtins.readFile ../scripts/freshness-guard.sh}
              '';
            };

          cacheGuard =
            nodeName:
            pkgs.writeShellApplication {
              name = "pre-deploy-${nodeName}-caches";
              runtimeInputs = with pkgs; [
                coreutils
                gawk
                gnugrep
                nix
              ];
              text = ''
                export CACHE_SUBSTITUTERS=${
                  lib.escapeShellArg (lib.concatStringsSep " " (cfg.nix.settings.extra-substituters or [ ]))
                }
                export CACHE_KEYS=${
                  lib.escapeShellArg (
                    lib.concatStringsSep " " (cfg.nix.settings.extra-trusted-public-keys or [ ])
                  )
                }

                ${builtins.readFile ../scripts/cache-guard.sh}
              '';
            };

          gate =
            nodeName: node:
            pkgs.writeShellApplication {
              name = "deploy-${nodeName}";
              runtimeInputs = [
                pkgs.coreutils
                pkgs.gnugrep
                pkgs.nix
                pkgs.openssh
                deployPkg
              ];
              text = ''
                export GATE_FLAKE="''${GATE_FLAKE:-.}"
                export GATE_NODE=${lib.escapeShellArg nodeName}
                export GATE_HOST=${lib.escapeShellArg hostName}
                export GATE_HOST_ADDR=${lib.escapeShellArg node.hostname}
                export GATE_HOST_USER="''${GATE_SSH_USER:-${sshUserOf node}}"
                export GATE_FRESH=${lib.getExe (freshnessGuard nodeName)}
                export GATE_CACHES=${lib.getExe (cacheGuard nodeName)}
                export GATE_PRE_DEPLOY=${lib.getExe (liveCheck nodeName node "pre-deploy")}
                export GATE_ACCESS=${lib.getExe (accessGuard nodeName node)}
                export GATE_VERIFY=${lib.getExe (liveCheck nodeName node "verify")}

                ${builtins.readFile ../scripts/deploy-gate.sh}
              '';
            };

          checkApps = lib.concatMapAttrs (
            nodeName: node:
            lib.listToAttrs (
              map
                (
                  mode:
                  let
                    pkg = liveCheck nodeName node mode;
                  in
                  lib.nameValuePair pkg.name {
                    type = "app";
                    program = lib.getExe pkg;
                  }
                )
                [
                  "pre-deploy"
                  "verify"
                ]
            )
          ) nodes;

          accessApps = lib.mapAttrs' (
            nodeName: node:
            let
              pkg = accessGuard nodeName node;
            in
            lib.nameValuePair pkg.name {
              type = "app";
              program = lib.getExe pkg;
            }
          ) nodes;

          cacheApps = lib.mapAttrs' (
            nodeName: _:
            let
              pkg = cacheGuard nodeName;
            in
            lib.nameValuePair pkg.name {
              type = "app";
              program = lib.getExe pkg;
            }
          ) nodes;

          freshApps = lib.mapAttrs' (
            nodeName: _:
            let
              pkg = freshnessGuard nodeName;
            in
            lib.nameValuePair pkg.name {
              type = "app";
              program = lib.getExe pkg;
            }
          ) nodes;

          gateApps = lib.mapAttrs' (
            nodeName: node:
            lib.nameValuePair "deploy-${nodeName}" {
              type = "app";
              program = lib.getExe (gate nodeName node);
            }
          ) nodes;
        in
        checkApps // accessApps // cacheApps // freshApps // lib.optionalAttrs (deployPkg != null) gateApps;
    in
    lib.foldl' (acc: h: acc // forHost h nixosConfigurations.${h}) { } (
      lib.attrNames nixosConfigurations
    );

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

  # One `run-<host>-vm` per host, wrapping NixOS's own VM runner with the port
  # forwarding its vmVariant implies.
  mkVmApps =
    { pkgs, nixosConfigurations }:
    let
      runner =
        name: hostConfig:
        let
          vhosts = hostConfig.config.virtualisation.vmVariant.services.nginx.virtualHosts;
          guestPort = domain: (lib.head vhosts.${domain}.listen).port;
          domains = lib.sort (a: b: guestPort a < guestPort b) (lib.attrNames vhosts);
          first = guestPort (lib.head domains);
        in
        pkgs.writeShellApplication {
          name = "run-${name}-vm";
          text = ''
            base=''${VM_PORT_BASE:-18080}
            if [ "''${1:-}" = "--port-base" ]; then
              [ $# -ge 2 ] || { echo "--port-base needs a number" >&2; exit 1; }
              base=$2; shift 2
            fi

            fwd=""
            ${lib.concatMapStringsSep "\n" (d: ''
              printf '  %-26s http://localhost:%s\n' ${lib.escapeShellArg d} \
                "$((base + ${toString (guestPort d - first)}))"
              fwd="$fwd,hostfwd=tcp::$((base + ${toString (guestPort d - first)}))-:${toString (guestPort d)}"
            '') domains}
            printf '  %-26s ssh -p %s root@localhost\n' "(the machine)" \
              "$((base + ${toString (lib.length domains)}))"
            fwd="$fwd,hostfwd=tcp::$((base + ${toString (lib.length domains)}))-:22"
            echo

            export QEMU_NET_OPTS="''${QEMU_NET_OPTS:+''${QEMU_NET_OPTS},}''${fwd#,}"
            exec ${lib.getExe hostConfig.config.system.build.vm} "$@"
          '';
        };
    in
    lib.mapAttrs' (
      name: hostConfig:
      lib.nameValuePair "run-${name}-vm" {
        type = "app";
        program = lib.getExe (runner name hostConfig);
      }
    )
      (lib.filterAttrs (_: h: h.config.system.build ? initialRamdisk) nixosConfigurations);

  mkDeployNodes =
    nixosConfigurations:
    let
      byHost = lib.mapAttrs (
        _: hostConfig: if hostConfig.config ? deployment then hostConfig.config.deployment else { }
      ) nixosConfigurations;

      hosts = lib.attrNames byHost;
      owners = node: lib.filter (h: byHost.${h} ? ${node}) hosts;
      collisions = lib.filter (n: lib.length (owners n) > 1) (
        lib.unique (lib.concatMap (h: lib.attrNames byHost.${h}) hosts)
      );

      flattened = lib.foldl' (
        acc: hostName:
        acc
        // lib.mapAttrs (_: node: {
          inherit (node) hostname fastConnection;
          profiles = lib.mapAttrs (
            _: profile:
            {
              inherit (profile) sshUser user path;
            }
            // lib.optionalAttrs (profile.magicRollback != null) { inherit (profile) magicRollback; }
            // lib.optionalAttrs (profile.autoRollback != null) { inherit (profile) autoRollback; }
          ) node.profiles;
        }) byHost.${hostName}
      ) { } hosts;
    in
    lib.throwIf (collisions != [ ]) ''
      mkDeployNodes: deploy node names must be unique across hosts. Collisions: ${
        lib.concatMapStringsSep "; "
          (n: "'${n}' declared by ${lib.concatStringsSep " and " (owners n)}")
          collisions
      }
    '' flattened;
}
