{ lib }:

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
          units = map (a: a.name) (lib.filter (a: a.kind == "managed") apps);
          databases = map (a: a.database.name) (lib.filter (a: a.database != null) apps);
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
                : "''${LIVE_HOST:=${node.hostname}}"
                : "''${LIVE_SSH_USER:=${sshUserOf node}}"
                export LIVE_HOST LIVE_SSH_USER
                export LIVE_MODE=${lib.escapeShellArg mode}
                export LIVE_NODE=${lib.escapeShellArg nodeName}
                export LIVE_PG_MAJOR=${
                  lib.escapeShellArg (if pg.enable then lib.versions.major pg.package.version else "")
                }
                export LIVE_DATA_DIR=${lib.escapeShellArg pg.dataDir}
                export LIVE_UNITS=${lib.escapeShellArg (lib.concatStringsSep " " units)}
                export LIVE_DATABASES=${lib.escapeShellArg (lib.concatStringsSep " " databases)}

                ${builtins.readFile ../scripts/live-checks.sh}
              '';
            };

          gate =
            nodeName: node:
            pkgs.writeShellApplication {
              name = "deploy-${nodeName}";
              runtimeInputs = [
                pkgs.coreutils
                pkgs.nix
                pkgs.openssh
                deployPkg
              ];
              text = ''
                export GATE_FLAKE="''${GATE_FLAKE:-.}"
                export GATE_NODE=${lib.escapeShellArg nodeName}
                export GATE_HOST=${lib.escapeShellArg hostName}
                export GATE_PRE_DEPLOY=${lib.getExe (liveCheck nodeName node "pre-deploy")}
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

          gateApps = lib.mapAttrs' (
            nodeName: node:
            lib.nameValuePair "deploy-${nodeName}" {
              type = "app";
              program = lib.getExe (gate nodeName node);
            }
          ) nodes;
        in
        checkApps // lib.optionalAttrs (deployPkg != null) gateApps;
    in
    lib.foldl' (acc: h: acc // forHost h nixosConfigurations.${h}) { } (
      lib.attrNames nixosConfigurations
    );

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
