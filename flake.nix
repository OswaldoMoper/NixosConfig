{
  description = "Oswaldo's wsl config";
  inputs = {
    nix.url = "github:nixos/nix/master";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";
    nixos-wsl.url = "github:nix-community/NixOS-WSL/main";
  };

  outputs = inputs@ { self
                    , nixpkgs
                    , nixos-wsl
                    , ... }:
  {
    nixosConfigurations = {
      spartanWSL = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          nixos-wsl.nixosModules.default
          {
	          system.stateVersion = "24.05";
            wsl.enable = true;
            wsl.defaultUser = "omoper";
            # Enable and configure networking and firewall
            networking = {
              hostName = "spartanWSL";
              networkmanager.enable = true;
              # wireless.enable = true; # Enables wireless support via wpa_supplicant.
              # Open ports in the firewall.
              firewall.allowedTCPPorts = [ 3000 5432 587 5938 57621 ];
              firewall.allowedUDPPorts = [ 5938 5353 ];
            };
          }
          (import ./configuration.nix)
        ];
        specialArgs = { inherit inputs; };
      };
    };
  };
}
