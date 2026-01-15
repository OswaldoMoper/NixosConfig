{config, pkgs, inputs, ...}:

{
  system.stateVersion = "25.05";
  # TODO: I don't know which module to put this in, 
  #       so I'll leave it here.
  # Packages config
  # nixpkgs = {
  #   config.allowUnfree = true;
  #   config.permittedInsecurePackages = [
  #     "haskell.compiler.ghc924"
  #     "haskell.compiler.ghc966"
  #   ];
  #   overlays = [
  #     This is to install emacs-overlys and be able to configure doomemacs 
  #     (import (builtins.fetchTarball {
  #       url = "https://github.com/nix-community/emacs-overlay/archive/master.tar.gz";
	#       sha256 = "11m28vljiz8a6yw84skgv7gw09j353zmjjzkq68zgy05srh1pfj7";
  #     }))
  #   ];
  # };
  environment.pathsToLink = [
    "/share/nix-direnv"
    "/share/zsh"
  ];
  fonts.packages = with pkgs; [
    hack-font
  ];
# List services that you want to enable:
  services = {
  # Enable the OpenSSH daemon.
    openssh.enable = true;
    sshd.enable = true;
  };
# General Nix Config
  nix = {
    settings = {
      allow-import-from-derivation = true;
      auto-optimise-store = true;
      download-buffer-size = 671088640;
      trusted-public-keys = [ "hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ=" ];
      substituters = [ "https://cache.iog.io" ];
    };
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 30d";
    };
    # Nix packages config
    package = pkgs.nixVersions.stable;
    extraOptions = ''
      experimental-features = nix-command flakes
      keep-outputs = true
      keep-derivations = true
    '';
  };
  nixpkgs.config.allowUnfree = true;
  home-manager.useGlobalPkgs = true;
  home-manager.useUserPackages = true;
  # General Nixos configurations
  system.configurationRevision = inputs.nixpkgs.lib.mkIf (inputs.self ? rev) inputs.self.rev;
}