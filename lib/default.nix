{ lib }:

let
  inherit (import ./units.nix) unitOf appUnitsOf;
in
{
  nixFilesIn =
    dir:
    lib.listToAttrs (
      map (file: {
        name = builtins.replaceStrings [ ".nix" ] [ "" ] file;
        value = dir + "/${file}";
      }) (lib.filter (name: builtins.match ".*\\.nix$" name != null)
            (lib.attrNames (builtins.readDir dir)))
    );

  appModules =
    apps:
    let
      withProfile = lib.filter (a: a.profile or null != null) apps;
    in
    map (
      a:
      { config, ... }:
      {
        imports = lib.optional (a.profile.module or null != null) a.profile.module;

        config.services.${a.profile.attr}.profile = lib.mkMerge [
          config.webStack.profiles.${a.name}
          (a.profile.settings or { })
        ];
      }
    ) withProfile;
}
// import ./deploy.nix { inherit lib appUnitsOf; }
// import ./local.nix { inherit lib unitOf; }
// import ./vm.nix { inherit lib; }
