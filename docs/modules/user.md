# user — Multiuser DSL

This module provides a declarative interface for defining system users with integrated Home Manager configuration. It allows each host to declare users in a clean, structured way without duplicating logic across machines.

## Purpose

- Provide a unified user management DSL
- Integrate system users with Home Manager
- Configure Git, msmtp, SSH keys and VSCode per user
- Support reusable Home Manager profiles
- Avoid repeating user configuration across hosts

This module activates only when a user entry has `enable = true`.

## Structure

A user entry has the following shape:

```nix
myUsers.<name> = { 
  enable = true;
  fullName = "...";
  password = null;
  hashedPassword = null;
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
    vscode.enable = false; 
  }; 
};
```

## System User Configuration

When enable = true, the module creates:

- a normal user
- with Zsh as the default shell
- added to groups: `wheel`, `networkmanager`, `video`, `audio`

Password options:

- `password` → plaintext (for testing only)
- `hashedPassword` → recommended

## Home Manager Integration

When `home.enable = true`, the module:

- creates a Home Manager user
- sets `home.stateVersion = "25.05"`
- enables `ssh-agent` if SSH keys are configured
- imports profiles from `hmProfiles`/

## Home Manager Profiles

Profiles must be stored in:

```code
hmProfiles/<profile>.nix
```

Users may declare:

```Nix
home.profiles = [ "dev" "motorsport" ];
```

The module:

- checks if each profile exists
- imports only existing profiles
- ignores missing ones silently

This allows flexible per-user customization.

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

## VSCode Integration

```Nix
home.vscode.enable = true;
```

Enables VSCode Remote integration via Home Manager.

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
    fullName = "Oswaldo Moper";
    email = "omoper@example.com";

    home = {
      enable = true;
      profiles = [ "dev" ];

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

      vscode.enable = true;
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
