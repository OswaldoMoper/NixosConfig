{ lib }:

{
  mkPreDeployApps =
    { pkgs, nixosConfigurations }:
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
        _hostName: hostConfig:
        let
          cfg = hostConfig.config;
          nodes = if cfg ? deployment then cfg.deployment else { };
          apps = if cfg ? webStack then cfg.webStack.tunnel.apps ++ cfg.webStack.nginx.apps else [ ];
          units = map (a: a.name) (lib.filter (a: a.kind == "managed") apps);
          databases = map (a: a.database.name) (lib.filter (a: a.database != null) apps);
          pg = cfg.services.postgresql;
        in
        lib.mapAttrs' (
          nodeName: node:
          let
            name = "pre-deploy-${nodeName}-live";
          in
          lib.nameValuePair name {
            type = "app";
            program = lib.getExe (
              pkgs.writeShellApplication {
                inherit name;
                runtimeInputs = with pkgs; [ coreutils gnugrep openssh ];
                excludeShellChecks = [ "SC2029" ];
                text = ''
                  # Host and user stay overridable so the checks can be pointed at
                  # a staging box, or at localhost to exercise the script itself.
                  : "''${PRE_DEPLOY_HOST:=${node.hostname}}"
                  : "''${PRE_DEPLOY_SSH_USER:=${sshUserOf node}}"
                  export PRE_DEPLOY_HOST PRE_DEPLOY_SSH_USER
                  export PRE_DEPLOY_NODE=${lib.escapeShellArg nodeName}
                  export PRE_DEPLOY_PG_MAJOR=${
                    lib.escapeShellArg (if pg.enable then lib.versions.major pg.package.version else "")
                  }
                  export PRE_DEPLOY_DATA_DIR=${lib.escapeShellArg pg.dataDir}
                  export PRE_DEPLOY_UNITS=${lib.escapeShellArg (lib.concatStringsSep " " units)}
                  export PRE_DEPLOY_DATABASES=${lib.escapeShellArg (lib.concatStringsSep " " databases)}

                  ${builtins.readFile ../scripts/pre-deploy-live.sh}
                '';
              }
            );
          }
        ) nodes;
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
          profiles = lib.mapAttrs (_: profile: {
            inherit (profile) sshUser user path;
          }) node.profiles;
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
