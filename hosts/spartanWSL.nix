{ pkgs, self, inputs, lib, ... }:

# A worked example, not a machine anyone owns.
#
# It is a real host definition -- it evaluates, and it is what exercises the
# modules in this repo -- but every name, address and domain in it comes from
# the ranges reserved for documentation (RFC 2606, RFC 5737). Real machines
# belong in the private flake that consumes this one, which is the whole point
# of the split described in docs/architecture.md.

let
  home = "/home/omoper";
  exampleEmail = "omoper@example.com";
in
{
  imports = [ ./hardware/WSL.nix ];

  services.openssh.settings = {
    PasswordAuthentication = false;
    AllowUsers = [ "omoper" "guest" ];
  };

  # Two users, to show both shapes: one that drives every Home Manager feature,
  # and one that only needs an account and a key.
  myUsers = lib.mkMerge [
    {
      omoper = {
        enable = true;
        native.description = "Oswaldo Moper";
        email = exampleEmail;
        home = {
          enable = true;
          git = {
            enable = true;
            tag = "OswaldoMoper";
          };
          msmtp = {
            enable = true;
            passwordFile = "${home}/password.txt";
          };
          sshKeys = {
            enable = true;
            # Both fields are required together: an enabled basename with an
            # empty name would emit ~/.ssh/_ed25519 and ~/.ssh/ -- the directory.
            baseName = {
              enable = true;
              name = "OswaldoMoper";
            };
            names = [ "id_ed25519" ];
          };
          # IdentityFile accumulates across matching blocks, so IdentitiesOnly
          # is what stops ssh also offering everything in the agent.
          sshHosts."203.0.113.7" = {
            User = "root";
            IdentityFile = [ "~/.ssh/id_ed25519" ];
            IdentitiesOnly = true;
          };
        };
      };
    }
    {
      guest = {
        enable = true;
        native.description = "Guest User";
        native.openssh.authorizedKeys.keys = [
          # Replace with real public keys. These are syntactically valid and
          # belong to nobody.
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA guest@example"
        ];
      };
    }
  ];

  # Web Hosting Service
  webStack = {
    enable = true;
    email = exampleEmail;
    manager = "omoper";
    tunnel = {
      enable = true;
      credentials = "${home}/.cloudflared/uuid.json";
      useNginx = false;
      ssh = {
        enable = true;
        domain = "ssh.example.com";
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
    tarball.configPath = "${home}/NixosConfig";
  };

  networking = {
    networkmanager.enable = true;
    wireless.enable = lib.mkForce false;
    firewall = {
      enable = true;
      trustedInterfaces = [ "lo" "eth0" ];
      allowedTCPPorts = [ ];
      allowedUDPPorts = [ ];
    };
  };

  environment = {
    systemPackages = with pkgs; [
      rename
      wget
      gparted
      cachix
      tree
      gnumake
      gmp
      any-nix-shell
      curl
      direnv
      hack-font
      lambda-mod-zsh-theme
      nix-direnv
      nix-prefetch-git
      oh-my-zsh
      cloudflared
      sops
      self.packages.x86_64-linux.nixos-rebuild-migration
      inputs.agenix.packages.${pkgs.stdenv.hostPlatform.system}.default
      inputs.deploy-rs.packages.${pkgs.stdenv.hostPlatform.system}.default
      self.packages.${pkgs.stdenv.hostPlatform.system}.deploy-migration
    ];
  };

  # A safety cue, not decoration: give every machine a different one, and make
  # the dangerous one look alarming. Green here means "local, nothing to lose".
  tmux.accent = "#7fff00";

  nix = lib.mkMerge [
    {
      settings = {
        allowed-users = [ "@wheel" "omoper" ];
        trusted-users = [ "root" "omoper" ];

        # Public third-party caches. Without them a Haskell closure compiles
        # GHC from source on the machine that builds, which is this one.
        extra-substituters = [
          "https://cache.iog.io"
          "https://nixcache.reflex-frp.org"
        ];
        extra-trusted-public-keys = [
          "hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ="
          "ryantrinkle.com-1:JJiAKaRv9mWgpVAz8dwewnZe0AzzEAzPkagE9SP5NWI="
        ];
      };
    }
    # A second definition to show that these lists concatenate rather than
    # override -- which is why "root" appears once here and still ends up in
    # the generated nix.conf twice.
    {
      settings = {
        allowed-users = [ "guest" ];
        trusted-users = [ "guest" ];
      };
    }
  ];
}
