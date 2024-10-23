{ config, pkgs, lib, modulesPath, inputs, ... }:

{
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
  # Enable the Desktop Environment.
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
    # Declare a password it's not necessary in WSL 
    hashedPassword = "$6$IqhGanTrCJ3Y8GMS$2.q7j7DfXCbEEo1zUNkQTsSL5JuPpZbM4AghPXdycMBL6Hond51SCECELA7ufpbdrlq/u5UY/91Ph4Pu5Q/GW.";
    shell = pkgs.zsh;
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
      (import (builtins.fetchTarball {
        url = "https://github.com/nix-community/emacs-overlay/archive/master.tar.gz";
	      sha256 = "1nd1srgsdxzdij5nlgwxzr9imavf430ykm5s7g5dlqkwjpi6c217";
      }))
    ];
  };
  # List packages installed in system profile.
  environment = {
    systemPackages = with pkgs; [
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
      hack-font
      haskellPackages.yesod-bin
      haskell-language-server
      lambda-mod-zsh-theme
      nix-direnv-flakes
      nix-prefetch-git
      oh-my-zsh
      sox
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
    pathsToLink = [
      "/share/nix-direnv"
      "/share/zsh"
    ];
  };
  fonts.fonts = with pkgs; [
    hack-font
  ];
# List programs that you want to enable:
  programs = {
  # Setup VSCode Remote
    nix-ld = {
      enable = true;
      package = pkgs.nix-ld-rs;
    };
  # Enable and config Zsh
    nix-index.enableZshIntegration = true;
    zsh = {
      enable = true;
      enableCompletion = true;
      autosuggestions.enable = true;
      syntaxHighlighting.enable = true;
      ohMyZsh.enable = true;
      ohMyZsh.plugins = ["git" "sudo" "colorize" "extract" "history" "postgres"];
      ohMyZsh.theme = "bira";
      shellInit = ''
      if [ ! -S ~/.ssh/ssh_auth_sock ]; then
        echo  "'ssh-agent' has not been started since the last reboot." \
              "Starting 'ssh-agent' now."
        eval "$(ssh-agent)"
        ln -sf "$SSH_AUTH_SOCK" ~/.ssh/ssh_auth_sock
      fi
      export SSH_AUTH_SOCK=~/.ssh/ssh_auth_sock
      # see if any key files are already added to the ssh-agent, and if not, add them
      ssh-add ~/.ssh/xpsoasis-ed25519
      ssh-add ~/.ssh/github
      ssh-add ~/.ssh/deploy_rsa
      # ssh-add ~/.ssh/id_rsa
      if [ "$?" -ne "0" ]; then
        echo  "No ssh keys have been added to your 'ssh-agent' since the last" \
              "reboot. Adding default keys now."
        ssh-add
      fi
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
  };
# List services that you want to enable:
  services = {
  # Enable the OpenSSH daemon.
    openssh.enable = true;
    sshd.enable = true;
  # Enable and configure postgresql
    postgresql = {
      enable = true;
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
