{ pkgs, self, inputs, ... }@args:

let home = "/home/omoper";
in
{
  myUsers.omoper = {
    enable = true;
    fullName = "Oswaldo Moper";
    email = "omoper@example.com";
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
      vscode.enable = true;
    };
  };
  # Web Hosting Service
  webStack = {
    enable = true;
    email = "omoper@example.com";
    manager = "omoper";
    tunnelCredentials = "${home}/.cloudflared/uuid.json";
    apps = [
      {
        name = "nixTalk";
        domain = "nixTalk.oswaldomoper.com";
        port = 2000;
        static = "${home}/nixTalk/static";
        package = inputs.nixTalk.packages.${pkgs.system}.nixTalk-wrapper;
      }
      {
        name = "oswaldomoper";
        domain = "oswaldomoper.com";
        port = 2001;
        static = "${home}/oswaldomoper.com/static";
        package = inputs.moper.packages.${pkgs.system}.oswaldomoper-wrapper;
      }
    ];
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
      inputs.deploy-rs.packages.${pkgs.system}.default
      self.packages.${pkgs.system}.deploy-migration
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