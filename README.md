<h1 align=center>
  Oswaldo's Universal NixOS configuration<br />
  <a href="https://github.com/NixOS/nixpkgs/tree/nixos-25.11"><img src="https://img.shields.io/badge/nixpkgs-25.11-brightgreen" alt="nixpkgs 25.11" /></a>
</h1>

Modular, multiuser, multiapp and multihost configuration for NixOS (also NixOS-WSL); reproducible, extensible and maintainable in one branch.

- [🔍 General description](#-general-description)
- [🏎️ Quick Start (WSL)](#️-quick-start-wsl)
- [🏎️ Quick Start (Pure NixOS)](#️-quick-start-pure-nixos)
- [⚙️ Project Structure](#️-project-structure)
- [👤 Declaring users (multiuser)](#-declaring-users)
- [🖥️ Declaring hosts (multihost)](#️-declaring-hosts)
- [🧩 Declaring apps (multiapp)](#-declaring-apps)
- [🚀 Deployment](#-deploying-to-remote-servers-deploy-rs)
- [🐘 Deployment + Migration](#-postgresql-migration-deploy-migration)
- [🔧 System rebuild](#-system-rebuild)
- [🐘 Rebuild + Migration](#-postgresql-migration-nixos-rebuild-migration)
- [📚 Documentation](#-documentation)
- [🧠 Notes](#-notes)
- [⚖️ License](#️-license)

## 🔍 General description

This repository defines a universal architecture for multiple NixOS systems management in one flake:

- **Multihost:** each file on `hosts/` represents a different machine
- **Multiuser**: `myUsers` module with Home Manager automatic integration
- **Home Manager Profiles**: configurations per user on `hmProfiles/`
- **Reusable Modules**: PostgreSQL, web stack, graphical environment, WSL, etc
- **One Branch**: all the hosts are built from the same base

The objective is to allow each host to declare only the essentials, while the rest is configured automatically

## 🏎️ Quick Start (WSL)

1. Enable WSL if you haven't done already:

   ```powershell
     wsl --install --no-distribution
   ```

2. Download `nixos-wsl.tar.gz` from [the latest release](https://github.com/nix-community/NixOS-WSL/releases/latest).

3. Import the tarball into WSL:

   ```powershell
     wsl --import NixOS --version 2 $env:USERPROFILE\NixOS\ nixos-wsl.tar.gz
   ```

4. You can now run NixOS:

   ```powershell
     wsl -d NixOS
   ```

5. Clone this repository and rebuild

   ``` bash
     git clone https://github.com/OswaldoMoper/NixosConfig.git
     cd NixosConfig
     sudo nixos-rebuild switch --flake .#spartanWSL
   ```

### More

For more detailed instructions, [refer to the documentation](https://nix-community.github.io/NixOS-WSL/install.html)

For details about the [NixOS-WSL](https://github.com/nix-community/NixOS-WSL) base image, refer to the official project.

## 🏎️ Quick Start (Pure NixOS)

1. Install NixOS from an official ISO: <https://nixos.org/download>
2. Clone this repo:

   ```Bash
     git clone https://github.com/OswaldoMoper/NixosConfig.git
     cd NixosConfig
   ```

3. Rebuild using the corresponding host:

   ```bash
     sudo nixos-rebuild switch --flake .#<hostname>
   ```

   Example:

   ```bash
     sudo nixos-rebuild switch --flake .#laptop
   ```

4. Reboot if necessary:

   ```bash
     sudo reboot now
   ```

## ⚙️ Project structure

``` markdown
├── flake.nix
├── scripts/
│   ├── deploy-migration.sh
│   └── nixos-rebuild-migration.sh
├── hosts/
│   ├── hardware/
│   │   ├── server.nix  ← Not included
│   │   └── laptop.nix  ← Not included
│   ├── spartanWSL.nix
│   ├── laptop.nix      ← Not included
│   └── server.nix      ← Not included
├── nixosModules/
│   ├── common.nix
│   ├── graphical.nix
│   ├── postgresql.nix
│   ├── user.nix        ← multiuser module
│   └── webstack.nix
└── hmProfiles/
    ├── dev.nix         ← Not included yet
    ├── motorsport.nix  ← Not included yet
    └── default.nix     ← Not included yet
```

## 👤 Declaring users

Each user is declared on the corresponding host:

```Nix
{pkgs, ... }: {
  # ... other host configurations ...
  myUsers.omoper = {
    enable = true;
    fullName = "Oswaldo Moper";
    email = "example@gmail.com";
    home = {
      enable = true;
      git = {
        enable = true;
        tag = "OswaldoMoper";
      };
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
  # ... other host configurations ...
}
```

This activates:

- git per user
- msmtp per user
- SSH + ssh-agent
- VSCode
- Declarative config per user

## 🖥️ Declaring hosts

Each file on `hosts/` represents a machine:

```Nix
{ pkgs, ... }: {
  # This repository doesn't include hardware configs
  imports = [ ./hardware/configuration.nix ];

  # You can ignore this attribute and nixos will use the filename
  networking.hostName = "spartanWSL";

  graphical.enable = true;
  wsl.enable = true;
  myUsers.omoper.enable = true;
}
```

The flake automatically detects all hosts in the `hosts/` directory.

## 🧩 Declaring apps

To use an external app, add the input reference in `flake.nix`

```Nix
{
  # ... other inputs ...
  inputs.nixTalk.url = "github:OswaldoMoper/nixTalk";
  # ... other flake configurations ...
}
```

If the app is a web app that you are going to host, define the following in the corresponding host file:

```Nix
{pkgs, ... }: {
  # ... other host configurations ...
  webStack = {
    enable = true;
    email = "example@mail.com";
    manager = "admin";
    nginx.apps = [
      {
        name = "nixTalk";
        domain = "nixTalk.oswaldomoper.com";
        port = 2000;
        environment = {
          nixTalk_STATIC     = "/home/<name>/nixTalk/static";
          nixTalk_PORT       = "2000";
          nixTalk_UPLOAD     = "/home/<name>/upload";
          nixTalk_APPROOT    = "https://nixTalk.oswaldomoper.com";
          nixTalk_PGUSER     = "a postgres user";
          nixTalk_PGPASS     = "a secretly cripted password";
          nixTalk_PGHOST     = "localhost or your db host";
          nixTalk_PGPORT     = "5432 or the port you use";
          nixTalk_PGDATABASE = "nixTalk or the name of your database";
          nixTalk_PGPOOLSIZE = "10";
        };
        package = inputs.nixTalk;
        # Additionally, you can reference the name of the binary
        binaryName = "nixTalk-noWrapped"; # default: ${name}-wrapped
      }
    ];
    tunnel = {
      enable = true;
      # Enable useNginx only if needed
      useNginx = true;
      apps = [
        {
          name   = "blog";
          domain = "oswaldomoper.com";
          port   = 2001;
          package = inputs.moper;
          environment = {
            # ... Environment configurations ...
          };
          binaryName = "blog-noWrapped"; # default: ${name}-wrapped
        }
      ];
    };
  };
  # ... other host configurations ...
}
```

When `webStack.enable = true`

- `webStack.email` must be non-empty
- `webStack.tunnel.apps` or `webStack.nginx.apps` must contain at leat one app

and the module automatically:

- creates one virtualHost per app
- configures ACME certificates only to `nginx.apps` when exists
- configures Cloudflare Tunnel when `tunnel.apps` exists
- creates one systemd service per app
- injects the `environment` variables into the service

**NOTES:**

- `webStack.<mode>.apps.[*].environment` accepts strings, paths, packages and null values (same type as `systemd.services.<name>.environment`).
- `webStack.<mode>.apps.[*].port` values must be unique
- `webStack.<mode>.apps.[*].name` values must be unique
- `webStack.<mode>.apps.[*].domain` values must be unique

## 🚀 Deploying to remote servers (deploy-rs)

This repository supports declarative deployments using a **deploy-rs** based DSL.
Each host can optionally define a remote deployment target.

### 1. Declaring a deployable host

Inside the host file:

```Nix
{pkgs, ... }: {
  # ... other host configurations ...
  deployment.myServer = {
    hostname = "0.0.0.0";
    profiles.system = {
      sshUser = "example";
      path = deploy-rs.lib.activate.nixos self.nixosConfigurations.myServer;
      user = "root"
    };
  };
  environment.systemPackages = [
    # ... other systemPackages ...
    inputs.deploy-rs.defaultPackage.${pkgs.system}
    # ... other systemPackages ...
  ];
  # ... other host configurations ...
}
```

### 2. Running a deployment

```Bash
nix run .#deploy -- --hostname myServer
```

or

```bash
deploy -- --hostname myServer
```

This will:

- build the system
- upload the closure
- activate the new configuration

## 🐘 PostgreSQL migration (deploy-migration)

This flake includes a helper script that performs safe PostgreSQL migrations during deploys.

### What the script does

- connects to the remote server
- creates a full PostgreSQL backup
- downloads the backup locally
- runs `deploy-rs`
- detects if PostgreSQL version changed
- restores the database if needed

### Running a migration deploy

```bash
nix run .#deploy-migration -- myServer
```

or

```bash
deploy-migration -- myServer
```

### Installing deploy-migration on a host

`deploy-migration` is optional. Only hosts that perform remote deployments need it.

To enable it on a specific host:

```nix
{pkgs,...}: {
  # ... other host configurations ...
  deployment.myServer = {
    hostname = "0.0.0.0";
    profiles.system = {
      sshUser = "example";
      path = deploy-rs.lib.activate.nixos self.nixosConfigurations.myServer;
      user = "root"
    };
  };
  environment.systemPackages = [
    # ... other systemPackages ...
    inputs.deploy-rs.defaultPackage.${pkgs.system}
    self.packages.${pkgs.system}.deploy-migration
    # ... other systemPackages ...
  ];
  # ... other host configurations ...
}
```

This keeps deployment tooling out of machines that don't need it (e.g. laptops, WSL, development hosts).

## 🔧 System rebuild

The very first rebuild run

```bash
  sudo nixos-rebuild switch --flake .#<hostname>
```

Example

```bash
  sudo nixos-rebuild switch --flake .#spartanWSL
```

## 🐘 PostgreSQL migration (nixos-rebuild-migration)

This repository includes a local helper tool that extends `nixos-rebuild` with automatic PostgreSQL backup and restore logic.

Use this tool when rebuilding local machines (laptops, desktops, WSL, development servers).

### What the tool does

- creates a full PostgreSQL backup before rebuilding
- runs `nixos-rebuild`
- detects if the PostgreSQL version changed
- restores the databases if needed

This ensures safe upgrades when switching between NixOS generations that includes PostgreSQL version bumps.

### Running a migration rebuild

```bash
  sudo nixos-rebuild-migration switch --flake .#<hostname>
```

Example:

```bash
  sudo nixos-rebuild-migration switch --flake .#spartanWSL
```

### When to use this tool

Use `nixos-rebuild-migration` instead of `nixos-rebuild` when:

- your host uses PostgreSQL module
- you are updating NixOS to a new release
- you suspect PostgreSQL might upgrade
- you want safe, automatic backup/restore behavior

For normal rebuild without PostgreSQL changes, it behaves exactly like `nixos-rebuild`.

### Installing nixos-rebuild-migration on a host

`nixos-rebuild-migration` is also optional.
Only hosts that use PostgreSQL locally should enable it.

To enable it:

```nix
{pkgs,...}: {
  # ... other host configurations ...
  environment.systemPackages = [
    # ... other systemPackages ...
    self.packages.${pkgs.system}.nixos-rebuild-migration
    # ... other systemPackages ...
  ];
  # ... other host configurations ...
}
```

This avoids installing PostgreSQL migration tooling on machines that don't use PostgreSQL.

## 📚 Documentation

Full documentation is available in the [`/docs/`](./docs/) directory:

- [Architecture](./docs/architecture.md)
- [Common Modules](./docs/modules/common.md)
- [Users](./docs/modules/user.md)
- [Graphical configuration](./docs/modules/graphical.md)
- [Hosts](./docs/hosts.md)
- [Web stack](./docs/modules/webstack.md)
- [PostgreSQL](./docs/modules/postgresql.md)
- [Deployment](./docs/modules/deployment.md)
- [Migration scripts](./docs/scripts/)

## 🧠 Notes

This repository is designed to:

- Maintain a single branch
- Build all your systems from a single flake
- Enable declarative users with integrated Home Manager
- Avoid duplication across hosts
- Enable modular growth (roles, profiles, services, etc.)

## ⚖️ License

This project is licensed under the [BSD 3-Clause License](./LICENSE).
