# Hosts Overview

This document explains how hosts work in this repository, how they are detected automatically by the flake, and provides several example host configurations:
minimal, WSL, server, and a full example.

## Purpose of a Host

Each file in the `hosts/` directory represents a complete NixOS system. A host file declares only what is unique to that machine:

- hardware configuration  
- enabled modules  
- users  
- web apps  
- PostgreSQL settings  
- WSL settings (if applicable)  
- firewall rules  
- system packages  

Everything else is handled by the shared modules in `nixosModules/`.

## How Hosts Are Loaded

The flake automatically loads **every `.nix` file** inside `hosts/`:

```markdown
hosts/
├── spartanWSL.nix
├── exampleServer.nix
└── laptop.nix
```

Each file becomes:

```nix
nixosConfigurations.<filename>
```

No manual editing of `flake.nix` is required.

## Hardware configuration

Each physical NixOS machine requires a hardware configuration file. This file is generated automatically by the installer using:

```Shell
nixos-generate-config
```

This produces two files:

- `/etc/nixos/configuration.nix`
- `/etc/nixos/hardware-configuration.nix`

Only **hardware-configuration.nix** is machine-specific.
In this repository, hardware files live under:

```Markdown
hosts/hardware/<name>.nix
```

### Why keep hardware files separate?

- They're **machine-specific**
- They shouldn't be mixed with logical host configuration
- They change when disks, partitions or GPUs change
- They keep your host files clean and readable

### How to add hardware for a new host

1. Install NixOS normally
2. Copy the generated hardware file:

   ```Shell
   sudo cp /etc/nixos/hardware-configuration.nix \
     /path/to/repo/hosts/hardware/<hostname>.nix
   ```

3. Import it inside the host file:

   ```nix
   {
     # ... other host configurations ...
     imports = [
       ./hardware/<hostname>.nix
     ];
     # ... other host configurations ...
   }
   ```

### Example

```Nix
{ pkgs, ... }: {
  imports = [
    ./hardware/laptop.nix
  ];

  networking.hostName = "laptop";

  myUsers.omoper.enable = true;
  graphical.enable = true;
  webStack.enable = false;
}
```

### Notes

- Hardware files **mustn't** be shared between machines
- If you reinstall or change disks, regenerate the file
- If you use WSL, you **don't** need a hardware file

## Examples

### Minimal

A minimal host only needs to declare:

- hostname (optional)
- at least one user
- optional modules

```Nix
{ pkgs, ... }: {
  imports = [
    ./hardware/minimal.nix
  ];

  networking.hostName = "minimal";

  myUsers.alice.enable = true;

  graphical.enable = false;
  postgresql.enable = false;
  webStack.enable = false;
}
```

This produces a valid NixOS system with:

- base configuration (`common.nix`)
- user `alice`
- no GUI
- no PostgreSQL
- no web hosting

### WSL

WSL hosts typically enable:

- WSL module
- graphical mode = "WSL"
- a user
- webapps (optional)
- PostgreSQL (optional)
- deployment (optional)

```Nix
{ pkgs, self, inputs, ... }:

let home = "/home/omoper";
in {
  wsl = {
    enable = true;
    defaultUser = "omoper";
  };
  graphical = {
    enable = true;
    mode = "WSL";
  };
  myUsers.omoper = {
    enable = true;
    fullName = "Oswaldo Moper";
    email = "omoper@example.com";
    home = {
      enable = true;
      git.enable = true;
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
  environment.systemPackages = [
    # ... other pkgs
    inputs.deploy-rs.defaultPackage.${pkgs.system}
    self.packages.${pkgs.system}.deploy-migration
    self.packages.${pkgs.system}.nixos-rebuild-migration
  ];

  # Optional
  deployment.Server = {
    hostname = "example.com";
    profiles.system = {
      sshUser = "omoper";
      user = "root";
      path = deploy-rs.lib.activate.nixos self.nixosConfigurations.Server;
    };
  };
  # Optional
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
        environment = {
          nixTalk_STATIC     = "${home}/nixTalk/static";
          nixTalk_PORT       = "2000";
          nixTalk_UPLOAD     = "${home}/upload";
          nixTalk_APPROOT    = "https://nixTalk.oswaldomoper.com";
          nixTalk_PGUSER     = "omoper";
          nixTalk_PGPASS     = "a secretly cripted password";
          nixTalk_PGHOST     = "localhost";
          nixTalk_PGPORT     = "5432";
          nixTalk_PGDATABASE = "nixTalk";
          nixTalk_PGPOOLSIZE = "10";
        };
        package = inputs.nixTalk.packages.${pkgs.system}.nixTalk-wrapper;
      }
    ];
  };
  # Optional
  postgresql = {
    enable = true;
    dumpFile = "${home}/postgres_backup_local.sql";
  };
}
```

### Server

Servers typically enable:

- webStack (nginx mode)
- PostgreSQL
- firewall rules
- system packages for remote managment

```Nix
{ pkgs, self, inputs, ... }:

{
  fileSystems."/".device = "/dev/disk/by-label/nixos";
  boot.loader.grub.enable = true;
  boot.loader.grub.device = "/dev/sda";

  networking.hostName = "Server";

  myUsers.example = {
    enable = true;
    fullName = "Example User";
    email = "example@mail.com";
    home.msmtp = {
      enable = true;
      passwordFile = "/home/example/password.txt";
    };
  };

  users.users.example.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAA..."
  ];

  webStack = {
    enable = true;
    email = "example@mail.com";
    manager = "example";
    mode = "nginx";
    apps = [
      {
        name = "nixTalk";
        domain = "domain.com";
        port = 2000;
        environment = {
          nixTalk_STATIC     = "/home/example/nixTalk/static";
          nixTalk_PORT       = "2000";
          nixTalk_UPLOAD     = "/home/example/upload";
          nixTalk_APPROOT    = "https://domain.com";
          nixTalk_PGUSER     = "omoper";
          nixTalk_PGPASS     = "a secretly cripted password";
          nixTalk_PGHOST     = "localhost";
          nixTalk_PGPORT     = "5432";
          nixTalk_PGDATABASE = "nixTalk";
          nixTalk_PGPOOLSIZE = "10";
        };
        package = inputs.nixTalk.packages.${pkgs.system}.nixTalk-wrapper;
      }
    ];
  };

  postgresql = {
    enable = true;
    dumpFile = "/home/example/postgres_backup_local.sql";
  };
  networking.firewall.allowedTCPPorts = [ 22 80 5432 ];
  environment.systemPackages = [
    self.packages.${pkgs.system}.nixos-rebuild-migration
  ];
}
```

### Full example

```Nix
{ pkgs, self, inputs, ... }:

{
  networking.hostName = "fullExample";
  myUsers.omoper = {
    enable = true;
    fullName = "Oswaldo Moper";
    email = "omoper@example.com";
    home = {
      enable = true;
      profiles = [ "dev" ];
      git.enable = true;
      msmtp = {
        enable = true;
        passwordFile = "/home/omoper/password.txt";
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
  webStack = {
    enable = true;
    email = "omoper@example.com";
    manager = "omoper";
    mode = "nginx";
    apps = [
      {
        name = "nixTalk";
        domain = "nixTalk.oswaldomoper.com";
        port = 2000;
        environment = {
          nixTalk_STATIC     = "/home/omoper/nixTalk/static";
          nixTalk_PORT       = "2000";
          nixTalk_UPLOAD     = "/home/omoper/upload";
          nixTalk_APPROOT    = "https://nixTalk.oswaldomoper.com";
          nixTalk_PGUSER     = "omoper";
          nixTalk_PGPASS     = "a secretly cripted password";
          nixTalk_PGHOST     = "localhost";
          nixTalk_PGPORT     = "5432";
          nixTalk_PGDATABASE = "nixTalk";
          nixTalk_PGPOOLSIZE = "10";
        };
        package = inputs.nixTalk.packages.${pkgs.system}.nixTalk-wrapper;
      }
    ];
  };
  postgresql.enable = true;
  graphical = {
    enable = true;
    mode = "Linux";
  };
  networking.firewall.allowedTCPPorts = [ 22 80 5432 ];
  deployment.Server = {
    hostname = "example.com";
    profiles.system = {
      sshUser = "omoper";
      user = "root";
      path = deploy-rs.lib.activate.nixos self.nixosConfigurations.Server;
    };
  };
  environment.systemPackages = [
    inputs.deploy-rs.defaultPackage.${pkgs.system}
    self.packages.${pkgs.system}.deploy-migration
    self.packages.${pkgs.system}.nixos-rebuild-migration
  ];
}
```

## When to create a new host

create a new host file when:

- you install NixOS on a new machine
- you want a different role (server, WSL, laptop, VM)
- you want different apps or users
- you want different graphical or PostgreSQL settings

Each host is fully isolated and declarative.

## Summary

This repository supports:

- minimal hosts
- WSL hosts
- servers
- full-featured desktop hosts

All using the same shared modules and the same flake.
