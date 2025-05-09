{ config, pkgs, lib, modulesPath, inputs, ... }@args:

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
      autoLogin = {
        enable = true;
        user = "omoper";
      };
    };
    desktopManager.plasma6.enable = true;
  };
  # Enable network manager
  networking.networkmanager.enable = true;
  # Define a user account.
  users.users.omoper = {
    isNormalUser = true;
    description = "Oswaldo Moper";
    extraGroups = [ "networkmanager" "wheel" "video" "audio" ];
    # Declare a password it's not necessary in WSL 
    hashedPassword = "$6$IqhGanTrCJ3Y8GMS$2.q7j7DfXCbEEo1zUNkQTsSL5JuPpZbM4AghPXdycMBL6Hond51SCECELA7ufpbdrlq/u5UY/91Ph4Pu5Q/GW.";
    shell = pkgs.zsh;
  };
  # TODO: Move packages settings to a module
  # Packages config
  nixpkgs = {
    config.allowUnfree = true;
    config.permittedInsecurePackages = [
      "haskell.compiler.ghc924"
      "haskell.compiler.ghc966"
    ];
#     overlays = [
      # This is to install emacs-overlys and be able to configure doomemacs 
#       (import (builtins.fetchTarball {
#         url = "https://github.com/nix-community/emacs-overlay/archive/master.tar.gz";
# 	      sha256 = "11m28vljiz8a6yw84skgv7gw09j353zmjjzkq68zgy05srh1pfj7";
#       }))
#     ];
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
      # emacs-git
      ripgrep
      coreutils
      fd
      clang
      tmux
      # Requisites for PostgreSQL
      args.self.packages.x86_64-linux.nixos-rebuild-migration
    ];
    pathsToLink = [
      "/share/nix-direnv"
      "/share/zsh"
    ];
  };
  fonts.packages = with pkgs; [
    hack-font
  ];
# TODO: Move program settings to a module
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
      touch ~/.zshrc
      if [ ! -d ~/.zshrc ]; then
        echo "creating ~/.zshrc"
        touch ~/.zshrc
      fi

      REPO_PATH="/etc/nixos"
      REPO_URL="https://github.com/OswaldoMoper/NixosConfig.git"
      if [ ! -d "$REPO_PATH/.git" ]; then
          echo "Configuring the $REPO_PATH directory"
          sudo rm -rf "$REPO_PATH"
          git clone --recursive "$REPO_URL" "$REPO_PATH"
          sudo chmod -R u+w "$REPO_PATH"
          sudo chown -R omoper:users "$REPO_PATH"
          cd "$REPO_PATH"
          git config --global --add safe.directory "$REPO_PATH"
          git checkout spartanWSL
          git remote set-url origin git@github.com:OswaldoMoper/NixosConfig.git
      fi

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

      eval "$(direnv hook zsh)"
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
        from = "omoper@example.com";
        user = "omoper@example.com";
        passwordeval = "cat /home/omoper/password.txt";
      };
    };
  # Enable and config git
    git = {
      enable = true;
      config = {
        user = {
          name = "MOPER";
          email = "omoper@example.com";
        };
      };
    };
  };
# List services that you want to enable:
  services = {
  # Enable the OpenSSH daemon.
    openssh.enable = true;
    sshd.enable = true;
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
    package = pkgs.nixVersions.stable;
    extraOptions = ''
      experimental-features = nix-command flakes
      keep-outputs = true
      keep-derivations = true
    '';
  };
  # General Nixos configurations
  system.configurationRevision = inputs.nixpkgs.lib.mkIf (inputs.self ? rev) inputs.self.rev;
}
