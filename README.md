<h1 align=center>
  Oswaldo's Universal NixOS configuration<br />
  <a href="https://github.com/NixOS/nixpkgs/tree/nixos-25.05"><img src="https://img.shields.io/badge/nixpkgs-25.05-brightgreen" alt="nixpkgs 25.05" /></a>
</h1>

Modular, multiuser and multihost configuration for NixOS (also NixOS-WSL); reproducible, extensible and maintainable in one branch.

---

- [General description](#-general-description)
- [Quick Start (WSL)](#-quick-start-wsl)
- [Quick Start (Pure NixOS)](#️-quick-start-pure-nixos)
- [Project Structure](#️-project-structure)
- [Declaring users (multiuser)](#-declaring-users)
- [Declaring hosts (multihost)](#️-declaring-hosts)
- [System rebuild](#-system-rebuild)
- [Notes](#-notes)
- [License](#️-license)

---

## 🔍 General description

This repository defines a universal architecture for multiple NixOS systems management in one flake:

- **Multihost:** each file on `hosts/` represents a different machine
- **Multiuser**: `myUsers` module with Home Manager automatic integration
- **Home Manager Profiles**: configurations per user on `hmProfiles/`
- **Reusable Modules**: PostgreSQL, web stack, graphical environment, WSL, etc
- **One Branch**: all the hosts are built from the same base

The objective is to allow each host to declare only the essentials, while the rest is configured automatically

---

## 🚀 Quick Start (WSL)

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

---

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
     sudo nixos-rebuild switch --flake .#tank
   ```

4. Reboot if necessary:

   ```bash
     sudo reboot now
   ```

---

## ⚙️ Project structure

``` markdown
├── flake.nix
├── hosts/
│   ├── spartanWSL.nix
│   ├── laptop.nix
│   └── server.nix
├── nixosModules/
│   ├── common.nix
│   ├── graphical.nix
│   ├── postgresql.nix
│   ├── user.nix        ← multiuser module
│   └── webstack.nix
└── hmProfiles/
    ├── dev.nix
    ├── motorsport.nix
    └── default.nix
```

## 👤 Declaring users

Each user is declared on the corresponding host:

```Nix
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
```

This activates:

- git per user
- msmtp per user
- SSH + ssh-agent
- VSCode
- Declarative config per user

---

## 🖥️ Declaring hosts

Each file on `hosts/` represents a machine:

```Nix
{ pkgs, ... }: {
  networking.hostName = "spartanWSL";
  graphical.enable = true;
  wsl.enable = true;
  myUsers.omoper.enable = true;
}
```

The flake automatically detects all hosts in the `hosts/` directory.

---

## 🔧 System rebuild

```bash
  sudo nixos-rebuild switch --flake .#<hostname>
```

Example

```bash
  sudo nixos-rebuild switch --flake .#spartanWSL
```

---

## 🧠 Notes

This repository is designed to:

- Maintain a single branch
- Build all your systems from a single flake
- Enable declarative users with integrated Home Manager
- Avoid duplication across hosts
- Enable modular growth (roles, profiles, services, etc.)

---

## ⚖️ License

This project is licensed under the [BSD 3-Clause License](./LICENSE).
