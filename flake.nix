{
  description = "Oswaldo's Universal NixOS configuration";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixos-wsl.url = "github:nix-community/NixOS-WSL/release-26.05";
    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-utils.url = "github:numtide/flake-utils";
    deploy-rs = {
      url = "github:serokell/deploy-rs";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  outputs = inputs@ { self
                    , nixpkgs
                    , nixos-wsl
                    , flake-utils
                    , home-manager
                    , deploy-rs
                    , ... }:
  let
    system = "x86_64-linux";
    lib = nixpkgs.lib;
    myLib = import ./lib { inherit lib; };
    modules = [
        nixos-wsl.nixosModules.default
        home-manager.nixosModules.home-manager
        (import ./nixosModules/common.nix)
        (import ./nixosModules/graphical.nix)
        (import ./nixosModules/webstack.nix)
        (import ./nixosModules/postgresql.nix)
        (import ./nixosModules/user.nix)
        (import ./nixosModules/deployment.nix)
      ];
    hostDir = ./hosts;
    hostFiles = builtins.filter
      (name: builtins.match ".*\\.nix$" name != null)
      (builtins.attrNames (builtins.readDir hostDir));
    mkHost = hostName: nixpkgs.lib.nixosSystem {
      inherit system;
      specialArgs = {
        inherit self inputs nixpkgs nixos-wsl;
      };
      modules = modules ++ [
        { networking.hostName = hostName; }
        (import (hostDir + "/${hostName}.nix"))
      ];
    };
    nixosConfigurations =
      builtins.listToAttrs (map (file: {
        name = builtins.replaceStrings [".nix"] [""] file;
        value = mkHost (builtins.replaceStrings [".nix"] [""] file);
      }) hostFiles);
  in {
    inherit nixosConfigurations;
    lib = myLib;
    deploy.nodes = myLib.mkDeployNodes nixosConfigurations;
    packages.${system} = let
      pkgs = nixpkgs.legacyPackages.${system};
      rebuildMigration = builtins.readFile ./scripts/nixos-rebuild-migration.sh;
      deployMigration = builtins.readFile ./scripts/deploy-migration.sh;
    in {
      nixos-rebuild-migration = pkgs.writeShellScriptBin "nixos-rebuild-migration" rebuildMigration;
      deploy-migration = pkgs.writeShellScriptBin "deploy-migration" deployMigration;
    };
    nixosModules = let
        moduleDir = ./nixosModules;
        moduleFiles = builtins.attrNames (builtins.readDir moduleDir);
      in builtins.listToAttrs (map (file: {
        name = builtins.replaceStrings [".nix"] [""] file;
        value = import (moduleDir + "/${file}");
      }) moduleFiles);
  };
}
