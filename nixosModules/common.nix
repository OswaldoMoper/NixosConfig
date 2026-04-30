{config, pkgs, inputs, ...}:

{
  system.stateVersion = "25.11";
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