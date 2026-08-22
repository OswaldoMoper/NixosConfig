# user — Multiuser DSL

This module provides a declarative interface for defining system users with integrated Home Manager configuration. It allows each host to declare users in a clean, structured way without duplicating logic across machines.

## Purpose

- Provides a direct bridge to NixOS native user settings via the `native` block.
- Automatically maps system users to Home Manager configurations.
- Configure Git, msmtp, SSH keys and VSCode per user
- Support reusable Home Manager profiles
- Avoid repeating user configuration across hosts

This module is only active when a user entry has `enable = true`.

## Structure

A user entry has the following shape:

```nix
{  
  myUsers.<name> = { 
    enable = true;
    native = {
      description = "...";
      password = null;
      hashedPassword = null;
    };
    email = "...";
    home = { 
      enable = false;
      profiles = [ ];
      git = { 
        enable = false;
        email = <defaults to user email>;
        tag = ""; 
      };
      msmtp = {
        enable = false;
        email = <defaults to user email>;
        passwordFile = "";
      };
      sshKeys = { 
        enable = false;
        baseName = {
          enable = false;
          name = "";
        };
        names = [ ];
      };
    }; 
  };
}
```

## System User Configuration

This module acts as a **wrapper** for the standard NixOS `users.users.<name>` option.

- **Automatic Defaults**: When `enable = true`, the module automatically configures the user as a `isNormalUser`, sets `zsh` as the shell, and adds essential groups (`wheel`, `networkmanager`, etc.).
- **Native Pass-through**: Any attribute defined inside the `native` block is passed directly to the underlying NixOS user configuration. This allows you to use 100% of NixOS native features without limitations.

## Home Manager Integration

When `home.enable = true`, the module:

- creates a Home Manager user
- sets `home.stateVersion = "26.05"`
- enables `ssh-agent` if SSH keys are configured
- imports the profiles listed in `home.profiles`

## Home Manager Profiles

Profiles live at the root of the flake, one file per profile:

```Markdown
hmProfiles/<profile>.nix
```

Each is an ordinary Home Manager module:

```Nix
{ pkgs, ... }:
{
  home.packages = [ pkgs.ripgrep ];
}
```

Users declare the ones they want by basename:

```Nix
home.profiles = [ "dev" ];
```

A profile that does not resolve **fails evaluation**, naming the file it looked
for. That includes a file that exists on disk but is untracked by git: Nix does
not see it once this flake is consumed by rev, so it would silently do nothing
on the machine that matters.

## Git Configuration

When `home.git.enable = true`, the module configures:

- `userName = tag`
- `userEmail = email`

Defaults:

- `email` defaults to `myUsers.<name>.email`

## msmtp Configuration

When `home.msmtp.enable = true`, the module:

- installs `msmtp`
- generates `~/.config/msmtp/config`
- uses `passwordFile` for authentication

```Nix
home.msmtp = {
  enable = true;
  passwordFile = "/home/user/pgpass.txt";
};
```

## SSH Key Auto-loading

When `home.sshKeys.enable = true`, the module:

- enables `ssh-agent`
- loads keys automatically

Supports

### Base name keys

```Nix
sshKeys.baseName = {
  enable = true;
  name = "MyKey";
};
```

Loads:

- `~/.ssh/MyKey`
- `~/.ssh/MyKey_ed25519`
- `~/.ssh/MyKey_rsa`

### Additional keys

```Nix
sshKeys.names = [ "work" "github" ];
```

Loads:

- `~/.ssh/work`
- `~/.ssh/github`

## Examples

### Minimal user

```Nix
{pkgs, ...}: {
  # ... other host configurations ...
  myUsers.alice.enable = true;
  # ... other host configurations ...
}
```

### User with Home Manager

```Nix
{pkgs, ...}: {
  # ... other host configurations ...
  myUsers.bob = {
    enable = true;
    email = "bob@example.com";
    home.enable = true;
  };
  # ... other host configurations ...
}
```

### Full configuration

```Nix
{pkgs, ...}: {
  # ... other host configurations ...
  myUsers.omoper = {
    enable = true;
    native.description = "Oswaldo Moper";
    email = "omoper@example.com";

    home = {
      enable = true;
      git = {
        enable = true;
        tag = "Oswaldo Moper";
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
    };
  };
  # ... other host configurations ...
}
```

## When to use this module

Use it when:

- A host needs declarative users
- You want consistent user configuration across machines
- You want Home Manager integration

Do **not** use it for:

- System services
- Machine-wide configuration
- Hardware-specific settings
