{ pkgs, self, inputs, ... }@args:

let home = "/home/omoper";
  myEmail = "omoper@example.com";
in
{
  # dummy deploy example
  deployment.nodes.exampleServer = {
    hostname = "0.0.0.0";
    fastConnection = false;
    profiles.system = {
      sshUser = "example";
      path = inputs.deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.exampleServer;
      user = "root";
    };
  };
  myUsers.omoper = {
    enable = true;
    fullName = "Oswaldo Moper";
    email = myEmail;
    # hashedPassword = "$6$IqhGanTrCJ3Y8GMS$2.q7j7DfXCbEEo1zUNkQTsSL5JuPpZbM4AghPXdycMBL6Hond51SCECELA7ufpbdrlq/u5UY/91Ph4Pu5Q/GW.";
    home = {
      enable = true;
      git = {
        enable = true;
        tag = "Oswaldo Moper";
      };
      msmtp = {
        enable = true;
        passwordFile = "${home}/password.txt";
      };
      sshKeys = {
        enable = true;
        baseName = {
          enable = true;
          name = "OswaldoMoper";
        };
      };
      vscode.enable = false;
    };
  };
  # Web Hosting Service
  webStack = {
    enable = true;
    email = myEmail;
    manager = "omoper";
    tunnel = {
      enable = true;
      credentials = "${home}/.cloudflared/uuid.json";
      useNginx = false;
      apps = [
        {
          name = "nixTalk";
          domain = "nixTalk.oswaldomoper.com";
          port = 2000;
          package = inputs.nixTalk;
          environment = {
            YESOD_STATIC_DIR = "${home}/nixTalk/static";
            YESOD_PORT       = "2000";
            YESOD_APPROOT    = "https://nixTalk.oswaldomoper.com";
          };
        }
        {
          name = "blog";
          domain = "oswaldomoper.com";
          port = 2001;
          package = inputs.moper;
          environment = {
            YESOD_STATIC_DIR = "${home}/blog/static";
            YESOD_PORT       = "2001";
            YESOD_APPROOT    = "https://oswaldomoper.com";
          };
        }
      ];
    };
  };
  # PostgreSQL server
  postgresql = {
    enable = true;
    package = pkgs.postgresql_17;
    port = 5432;
    dumpFile = "${home}/postgres_backup_local.sql";
    logStatements = "all";
  };
  # Graphical Environment
  graphical = {
    enable = true;
    mode = "WSL";
  };
  # WSL config
  wsl = {
    enable = true;
    defaultUser = "omoper";
    tarball.configPath = "/etc/nixos";
  };
  # Enable and configure networking and firewall
  networking = {
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
      nix-direnv
      nix-prefetch-git
      oh-my-zsh
      zlib
      # Requsites for doomemacs
      coreutils
      tmux
      # Requisites for PostgreSQL
      self.packages.x86_64-linux.nixos-rebuild-migration
      # Requisites for oswaldomoper.com
      cloudflared
      wslu
      sops
      # Requisites for deploying tools
      inputs.deploy-rs.packages.${pkgs.stdenv.hostPlatform.system}.default
      self.packages.${pkgs.stdenv.hostPlatform.system}.deploy-migration
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