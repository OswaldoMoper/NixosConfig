{ pkgs, self, inputs, ... }@args:

{
  # WSL config
  wsl = {
    enable = true;
    defaultUser = "omoper";
    tarball.configPath = "/etc/nixos";
  };
  # Enable and configure networking and firewall
  networking = {
    hostName = "spartanWSL";
    networkmanager.enable = true;
    # Open ports in the firewall
    firewall = {
      allowedTCPPorts = [ 3000 5432 587 5938 57621 ];
      allowedUDPPorts = [ 5938 5353 ];
    };
  };
  # List packages installed in system profile.
  environment = {
    systemPackages = with pkgs; [
      # Common packages
      rename
      wget
      gparted
      hunspell
      hunspellDicts.es-mx
      hunspellDicts.en-us
      aspellDicts.en
      aspellDicts.en-computers
      # aspellDicts.en-science
      cachix
      tree
      gnumake
      gmp
      # Requisites for my work
      any-nix-shell
      curl
      direnv
      hack-font
      lambda-mod-zsh-theme
      nix-direnv-flakes
      nix-prefetch-git
      oh-my-zsh
      zlib
      # Requsites for doomemacs
      coreutils
      tmux
      # Requisites for PostgreSQL
      self.packages.x86_64-linux.nixos-rebuild-migration
    ];
  };
  # General Nix config
  nix = {
    settings = {
      # Nix users config
      allowed-users = [ "@wheel" "omoper" ];
      trusted-users = [ "root" "omoper" ];
    };
  };
}