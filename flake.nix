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
    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  outputs = inputs@ { self
                    , nixpkgs
                    , nixos-wsl
                    , flake-utils
                    , home-manager
                    , deploy-rs
                    , agenix
                    , ... }:
  let
    system = "x86_64-linux";
    lib = nixpkgs.lib;
    myLib = import ./lib { inherit lib; };
    modules = [
        nixos-wsl.nixosModules.default
        home-manager.nixosModules.home-manager
        agenix.nixosModules.default
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
    myPackages = let
      pkgs = nixpkgs.legacyPackages.${system};
      common = with pkgs; [ coreutils gnugrep gawk util-linux systemd ];
    in {
      nixos-rebuild-migration = pkgs.writeShellApplication {
        name = "nixos-rebuild-migration";
        runtimeInputs = common ++ [ pkgs.nixos-rebuild ];
        text = builtins.readFile ./scripts/nixos-rebuild-migration.sh;
      };
      deploy-migration = pkgs.writeShellApplication {
        name = "deploy-migration";
        excludeShellChecks = [ "SC2029" ];
        runtimeInputs = common ++ [
          pkgs.nix
          pkgs.openssh
          deploy-rs.packages.${system}.default
        ];
        text = builtins.readFile ./scripts/deploy-migration.sh;
      };
    };
  in {
    inherit nixosConfigurations;
    lib = myLib;
    deploy.nodes = myLib.mkDeployNodes nixosConfigurations;
    apps.${system} = myLib.mkPreDeployApps {
      inherit nixosConfigurations;
      pkgs = nixpkgs.legacyPackages.${system};
    };
    packages.${system} = myPackages;
    checks.${system} = myPackages // {
      scripts =
        (nixpkgs.legacyPackages.${system}).runCommand "shellcheck-scripts"
          { nativeBuildInputs = [ (nixpkgs.legacyPackages.${system}).shellcheck ]; }
          ''
            shellcheck -s bash -e SC2029 ${./scripts}/*.sh
            touch "$out"
          '';
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
