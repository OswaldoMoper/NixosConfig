{ lib }:

{
  mkDeployNodes =
    nixosConfigurations:
    let
      byHost = lib.mapAttrs (
        _: hostConfig: if hostConfig.config ? deployment then hostConfig.config.deployment else { }
      ) nixosConfigurations;
    in
    lib.foldl' (
      acc: hostName:
      acc
      // lib.mapAttrs (_: node: {
        inherit (node) hostname fastConnection;
        profiles = lib.mapAttrs (_: profile: {
          inherit (profile) sshUser user path;
        }) node.profiles;
      }) byHost.${hostName}
    ) { } (lib.attrNames byHost);
}
