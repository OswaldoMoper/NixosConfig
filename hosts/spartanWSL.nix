{ pkgs, self, inputs, lib, ... }@args:

let home = "/home/omoper";
  myEmail = "omoper@example.com";
in
{
  imports = [ ./hardware/WSL.nix ];

  services.openssh.settings = {
    PasswordAuthentication = false;
    AllowUsers = [ "omoper" "guest" ];
  };

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
    {
      guest = {
        enable = true;
        native.description = "Guest User";
        email = "user@example.com";
        home = {
          enable = true;
          git = {
            enable = true;
            tag = "LupitaZP";
          };
          msmtp = {
            enable = true;
            passwordFile = "/home/guest/password.txt";
          };
          sshKeys = {
            enable = true;
            names = [
              "id_ed25519"
              "id_25519"
            ];
          };
        };
        native.openssh.authorizedKeys.keys = [
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJm3IcBc1AhUqWxBbPRbV0R8l+hVhvb3jbE3mH53xDf2 omoper@spartanWSL"
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA guest@conect"
        ];
      };
    }
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
      # Requisites for secrets
      inputs.agenix.packages.${pkgs.stdenv.hostPlatform.system}.default
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
    {
      settings = {
        allowed-users = [ "guest" ];
        trusted-users = [ "guest" ];
      };
    }
  ];
}