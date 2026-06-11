{ pkgs, self, inputs, lib, ... }@args:

let home = "/home/omoper";
  myEmail = "omoper@example.com";
  nixTalk = builtins.getFlake "github:OswaldoMoper/nixTalk?rev=2c2250d4afb4c5cc7fad5f064694269720129e58";
  moper   = builtins.getFlake "github:OswaldoMoper/blog?rev=a97f2a0a8fc07f9e99b81bcd65731e9fe2c7f935";
  secrets = builtins.getFlake "git+ssh://git@github.com/redacted/ConfigsSecrets.git?rev=d8f8451cf28c8be59eeb19980f278a2fd897f9f8";
  remote  = secrets.rcs.spartanWSL;
in
{
  imports = [ ./hardware/WSL.nix ];

  deployment = secrets.deployment;

  services.openssh.settings = lib.mkMerge [
    remote.services.openssh.settings
  ];

  myUsers = lib.mkMerge [
    {
      omoper = {
        enable = true;
        native.description = "Oswaldo Moper";
        email = myEmail;
        # native.hashedPassword = "$6$IqhGanTrCJ3Y8GMS$2.q7j7DfXCbEEo1zUNkQTsSL5JuPpZbM4AghPXdycMBL6Hond51SCECELA7ufpbdrlq/u5UY/91Ph4Pu5Q/GW.";
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
        };
      };
    }
    remote.myUsers
  ];
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
          package = nixTalk;
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
          package = moper;
          environment = {
            YESOD_STATIC_DIR = "${home}/blog/static";
            YESOD_PORT       = "2001";
            YESOD_APPROOT    = "https://oswaldomoper.com";
          };
        }
      ];
      ssh = {
        enable = true;
        domain = "ssh.oswaldomoper.com";
        port = 22;
      };
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
    tarball.configPath = "/home/omoper/NixosConfig";
  };
  # Enable and configure networking and firewall
  networking = {
    networkmanager.enable = true;
    wireless.enable = lib.mkForce false;
    # Open ports in the firewall
    firewall = {
      enable = true;
      trustedInterfaces = [ "lo" "eth0" ];
      allowedTCPPorts = [  ];
      allowedUDPPorts = [  ];
    };
  };
  # List packages installed in system profile.
  environment = {
    systemPackages = with pkgs; [
      # Common packages
      rename
      wget
      gparted
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
      # Requisites for PostgreSQL
      self.packages.x86_64-linux.nixos-rebuild-migration
      # Requisites for oswaldomoper.com
      cloudflared
      sops
      # Requisites for deploying tools
      inputs.deploy-rs.packages.${pkgs.stdenv.hostPlatform.system}.default
      self.packages.${pkgs.stdenv.hostPlatform.system}.deploy-migration
    ];
  };
  # General Nix config
  nix = lib.mkMerge [
    {
      settings = {
        # Nix users config
        allowed-users = [ "@wheel" "omoper" ];
        trusted-users = [ "root" "omoper" ];
      };
    }
    remote.nix
  ];
}