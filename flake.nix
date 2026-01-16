{
  description = "Oswaldo's Universal NixOS configuration";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    nixos-wsl.url = "github:nix-community/NixOS-WSL/main";
    home-manager = {
      url = "github:nix-community/home-manager/release-25.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-utils.url = "github:numtide/flake-utils";
    nixTalk.url = "github:OswaldoMoper/nixTalk";
    moper = {
      type = "path";
      path = "/home/omoper/oswaldomoper.com";
    };
  };
  outputs = inputs@ { self
                    , nixpkgs
                    , nixos-wsl
                    , flake-utils
                    , home-manager
                    , ... }:
  let
    system = "x86_64-linux";
    modules = [
        nixos-wsl.nixosModules.default
        home-manager.nixosModules.home-manager
        (import ./nixosModules/common.nix)
        (import ./nixosModules/graphical.nix)
        (import ./nixosModules/webstack.nix)
        (import ./nixosModules/postgresql.nix)
        (import ./nixosModules/user.nix)
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
        (import (hostDir + "/${hostName}.nix"))
      ];
    };
  in {
    nixosConfigurations =
      builtins.listToAttrs (map (file: {
        name = builtins.replaceStrings [".nix"] [""] file;
        value = mkHost (builtins.replaceStrings [".nix"] [""] file);
      }) hostFiles);
    packages.${system} = let
      pkgs = nixpkgs.legacyPackages.${system};
      migrationScript = builtins.readFile ./scripts/nixos-rebuild-migration.sh;
    in {
      nixos-rebuild-migration = pkgs.writeShellScriptBin "nixos-rebuild-migration" migrationScript;
    };
    nixosModules = modules;
  };
}
