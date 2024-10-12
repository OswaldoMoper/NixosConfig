{ config, pkgs, lib, modulesPath, inputs, ... }:

{
  imports = [
    # include NixOS-WSL modules
    # <nixos-wsl/modules>
  ];

  services = {
  # Enable the X11 windowing system.
    xserver.enable = true;
  # Enable the Plasma 6 Desktop Environment.
    displayManager = {
      sddm = {
        enable = true;
        wayland.enable = true;
      };
      defaultSession = "plasma";
    # Enable automatic login for the user.
      # autoLogin = {
      #   enable = true;
      #   user = "omoper";
      # };
    };
    desktopManager.plasma6.enable = true;
  };
  # Define a user account.
  users.users.omoper = {
    isNormalUser = true;
    description = "Oscar Oswaldo Moya Perez";
    extraGroups = [ "networkmanager" "wheel" "video" "audio" ];
    # Declare a password it's not recommended in WSL 
    # hashedPassword = "your hashedPassword";
    # password = "your password";
    shell = pkgs.zsh;
    # packages = with pkgs; [
    #   microsoft-edge
    # ];
  };
  # Packages config
  nixpkgs = {
    config.allowUnfree = true;
    config.permittedInsecurePackages = [
      "haskell.compiler.ghc924"
      "haskell.compiler.ghc966"
    ];
    overlays = [
      # This is to install emacs-overlys and be able to configure doomemacs 
      (import (builtins.fetchTarball https://github.com/nix-community/emacs-overlay/archive/master.tar.gz))
    ];
  };
  # List packages installed in system profile.
  environment.systemPackages = with pkgs; [
    # Common packages
    rename
    texlive.combined.scheme-basic
    wget
    scrot
    dmenu
    tabbed
    gparted
    xdotool
    xvkbd
    hunspell
    hunspellDicts.es-any
    hunspellDicts.es-mx
    hunspellDicts.en-us
    aspellDicts.en
    aspellDicts.en-computers
    aspellDicts.en-science
    aspellDicts.es
    inkscape
    cachix
    tree
    gnumake
    gmp
    # Requisites for my work
    any-nix-shell
    cabal-install
    curl
    direnv
    # stack
    # ghc
    # ghcid
    hack-font
    haskellPackages.yesod-bin
    # haskell.compiler.ghc924
    haskell-language-server
    insomnia
    lambda-mod-zsh-theme
    microsoft-edge
    nix-direnv-flakes
    nix-prefetch-git
    oh-my-zsh
    sox
    # sshpass
    stylish-haskell
    zlib
    # Requsites for doomemacs
    emacs-git
    ripgrep
    coreutils
    fd
    clang
    tmux
  ];

  environment.pathsToLink = [
    "/share/nix-direnv"
  ];

  programs = {
  # Enable and config Zsh
    nix-index.enableZshIntegration = true;
    zsh = {
      enable = true;
      enableCompletion = true;
      autosuggestions.enable = true;
      interactiveShellInit = ''
        # z - jump around
        save_saliases=$(alias -L)
        export ZSH=${pkgs.oh-my-zsh}/share/oh-my-zsh
        export ZSH_THEME="bira" #"lambda"
        plugins=(git sudo colorize extract history postgres)
        source $ZSH/oh-my-zsh.sh
        eval $save_aliases; unset save_aliases
      '';
      promptInit = ''
        any-nix-shell zsh --info-right | source /dev/stdin
      '';
      };
  # Enable brightness monitoring
    light.enable = true;
  # Enable and config git
    git = {
      enable = true;
      config = {
        user = {
          name = "MOPER";
          email = "oswaldomoyap@gmail.com";
        };
      };
    };
  };# Enable the OpenSSH daemon.
  services = {
    openssh.enable = true;
    sshd.enable = true;
  };
  # List services that you want to enable:
  services.postgresql = {
      enable = true;
      # package = pkgs.postgresql_15;
      enableTCPIP = true;
      authentication = pkgs.lib.mkOverride 10 ''
        #type database DBUser address      auth-method
        local all      all                 trust
        # ipv4
	      host all       all    127.0.0.1/32 trust
        # ipv6
        host all       all    ::1/128      trust
      '';
      initialScript = pkgs.writeText "backend-initScript" ''
        CREATE ROLE analyzer WITH LOGIN PASSWORD 'anapass';
        CREATE DATABASE aanalyzer_yesod;
        GRANT ALL PRIVILEGES ON DATABASE aanalyzer_yesod TO analyzer;
	      GRANT ALL ON SCHEMA public TO analyzer;
      '';
  };
  # General Nix config
  nix = {
    settings = {
      allow-import-from-derivation = true;
      # Nix users config
      trusted-public-keys = [ "hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ=" ];
      substituters = [ "https://cache.iog.io" ];
      allowed-users = [ "@wheel" "omoper" ];
      trusted-users = [ "root" "omoper" ];
    };
    # Nix packages config
    package = pkgs.nixFlakes;
    extraOptions = ''
      experimental-features = nix-command flakes
      keep-outputs = true
      keep-derivations = true
    '';
  };
  # General Nixos configurations
  system.configurationRevision = inputs.nixpkgs.lib.mkIf (inputs.self ? rev) inputs.self.rev;
}
