{ config, pkgs, lib, modulesPath, inputs, ... }:

{
  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
      ./other.nix
    ];
  # Enable and config bootloader
  boot.loader = {
    efi = {
      canTouchEfiVariables = true;
      efiSysMountPoint = "/boot/efi";
    };
    # Using grub boot loader
    grub = {
      enable = true;
      devices = ["nodev"];
      efiSupport = true;
    };
    timeout = 20;
  };
  # Enable and configure networking and firewall
  networking = {
    hostName = "spartan"; #Define your hostname.
    networkmanager = {
      enable = true;
    #   insertNameservers = [ "1.1.1.1" "8.8.8.8"];
    };
    # wireless.enable = true; # Enables wireless support via wpa_supplicant.
    # Open ports in the firewall.
    firewall.allowedTCPPorts = [ 3000 5432 587 5938 57621 ];
    firewall.allowedUDPPorts = [ 5938 5353 ];
  };
  # Set your time zone.
  time.timeZone = "America/Mexico_City";
  # Select internationalisation properties.
  i18n.defaultLocale = "es_MX.utf8";

  services = {
  # Enable the X11 windowing system.
    xserver = {
      enable = true;
    # Configure keymap in X11
      xkb = {
        layout = "us";
        variant = "altgr-intl";
      };
    };
  # Enable the Plasma 6 Desktop Environment.
    displayManager = {
      sddm = {
        enable = true;
        wayland.enable = true;
      };
      defaultSession = "plasma";
    # Enable automatic login for the user.
      autoLogin = {
        enable = true;
        user = "omoper";
      };
    };
    desktopManager.plasma6.enable = true;
  # Enable CUPS to print documents.
    printing.enable = true;
  };
  # Enable and config sound
  sound = {
    enable =  true;
    mediaKeys.enable = true;
  };
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    jack.enable = true;
  };
  # hardware.pulseaudio.enable = true;
  # Configure Bluetooth
  hardware.bluetooth.enable = true;
  services.blueman.enable = true;
  # Allow to use Xbox Headset's (USB or Xbox Wireless Dongle)
  # hardware.xone.enable = true;
  # Define a user account.
  users.users.omoper = {
    isNormalUser = true;
    description = "Oscar Oswaldo Moya Perez";
    extraGroups = [ "networkmanager" "wheel" "video" "audio" ];
    hashedPassword = "$6$IqhGanTrCJ3Y8GMS$2.q7j7DfXCbEEo1zUNkQTsSL5JuPpZbM4AghPXdycMBL6Hond51SCECELA7ufpbdrlq/u5UY/91Ph4Pu5Q/GW.";
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
      "haskell.compiler.ghc924Binary"
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
    # git
    # Requisites for my work
    any-nix-shell
    cabal-install
    curl
    direnv
    stack
    ghc
    ghcid
    hack-font
    haskellPackages.yesod-bin
    # haskell.compiler.ghc924
    haskell-language-server
    insomnia
    lambda-mod-zsh-theme
    microsoft-edge
    # msmtp
    nix-direnv-flakes
    nix-prefetch-git
    oh-my-zsh
    # postgresql
    sox
    # sshpass
    stylish-haskell
    zlib
    # zsh
    # Requsites for doomemacs
    emacs
    ripgrep
    coreutils
    fd
    clang
    tmux
  # Optional packages
    # Requisites for xone
    # linuxKernel.packages.linux_zen.xone
    # cabextract
    spotify
    obs-studio
    krita
  ];

  environment.pathsToLink = [
    "/share/nix-direnv"
  ];

  programs = {
  # Enable and config Zsh
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
  # Enable and config msmtp
    msmtp = {
      enable = true;
      accounts.default = {
        tls  = true;
        auth = true;
        # auth = "SCRAM-SHA-256";
        host = "smtp.gmail.com";
        port = 587;
        from = "oswaldomoyap@gmail.com";
        user = "oswaldomoyap@gmail.com";
        passwordeval = "cat ./password.txt";
      };
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
        aliases = {
          crf = "commit 'Refactor'";
          spo = "stash pop";
          spu = "stash push";
          ssp = "stash show -p";
          sli = "stash list";
          };
      };
    };
  };
  # Enable the OpenSSH daemon.
  services = {
    openssh.enable = true;
    sshd.enable = true;
  };
  # List services that you want to enable:
  services.postgresql = {
      enable = true;
      # package = pkgs.postgresql_12;
      enableTCPIP = true;
      authentication = pkgs.lib.mkOverride 10 ''
        local all all trust
        host all all ::1/128 trust
      '';
      initialScript = pkgs.writeText "backend-initScript" ''
        CREATE ROLE analyzer WITH LOGIN PASSWORD 'anapass';
        CREATE DATABASE aanalyzer_yesod;
        GRANT ALL PRIVILEGES ON DATABASE aanalyzer_yesod TO analyzer;
      '';
  };
  # General Nix config
  nix = {
    settings = {
      auto-optimise-store = true;
      allow-import-from-derivation = true;
      # Nix users config
      trusted-public-keys = [ "hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ=" ];
      substituters = [ "https://cache.iog.io" ];
      allowed-users = [ "@wheel" "omoper" ];
      trusted-users = [ "root" "omoper" ];
    };
    # Nix derivations config
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 7d";
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
  system.stateVersion = "24.05"; # Did you read the comment?
  system.configurationRevision = inputs.nixpkgs.lib.mkIf (inputs.self ? rev) inputs.self.rev;
}
