# Evaluates each module the flake exports on its own, on a minimal system,
# with only the outside modules and arguments listed in `needs`, so a module
# that uses another one without importing it fails here. Like checks.hosts it
# evaluates and builds nothing; a failure is the evaluation error itself.
{ pkgs, nixpkgs, inputs, modules }:

let
  inherit (pkgs) lib;

  needs = {
    common = {
      modules = [ inputs.home-manager.nixosModules.home-manager ];
      specialArgs = { inherit inputs; };
    };
    user.modules = [ inputs.home-manager.nixosModules.home-manager ];
  };

  minimal = {
    boot.isContainer = true;
    networking.hostName = "alone";
    system.stateVersion = "25.05";
  };

  drvPath = name: module:
    let n = needs.${name} or { }; in
    (nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = n.specialArgs or { };
      modules = [ module minimal ] ++ n.modules or [ ];
    }).config.system.build.toplevel.drvPath;
in
pkgs.writeText "modules-alone"
  (lib.concatStringsSep "\n" (lib.mapAttrsToList
    (name: module: "${name} ${builtins.unsafeDiscardStringContext (drvPath name module)}")
    modules))
