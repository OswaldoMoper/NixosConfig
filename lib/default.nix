{ lib }:

let
  # A managed app is its own unit; a profile app is named by the module that
  # ships it, and the two need not match, so nothing here can derive it.
  unitOf = a: if a.unit != null then a.unit else (if a.kind == "managed" then a.name else null);
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
// import ./deploy.nix { inherit lib unitOf; }
// import ./local.nix { inherit lib unitOf; }
// import ./vm.nix { inherit lib; }
