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
        configFile = "";
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

### The generated file puts the address in the store

Measured on a live machine: `~/.config/msmtp/config` is a symlink into the Nix store, and the store is world-readable.

```text
-r--r--r-- root root   .../home-manager-files/.config/msmtp/config
   from <address>
   user <address>
```

So **every account on the machine can read the address**, not only whoever can read this repo. Encrypting `email` does not help: Nix interpolates it while building.

There is no half fix. msmtp has a `passwordeval` and **no `fromeval`** — checked against `msmtp(1)` — so `from` and `user` can only come from somewhere else if the whole file does.

### `home.msmtp.configFile`

A complete `msmtprc` on the target machine, used **instead of** generating one.

```Nix
home.msmtp = {
  enable = true;
  configFile = "/run/agenix/msmtp-omoper";
};
```

| | |
| --- | --- |
| Type | **string, not path** — interpolating a path copies the file into the store, which is the thing being avoided |
| How it is applied | symlinked, never copied, so the file keeps its own owner and mode. What lands in the store is a **symlink and nothing else** |
| `passwordFile` | must be empty. An assertion says so, because `configFile` supplies the whole file and a `passwordFile` beside it is read by nothing |

### Why the password can only live here

`passwordeval "cat <file>"` exists in the generated file because the plain `password` directive **cannot** be used there. msmtp checks the mode itself and refuses:

```text
msmtp: <file>: contains secrets and therefore must have no more than
       user read/write permissions
```

A store file is `444`, so that is a hard failure rather than a quiet leak. Move the file out of the store and `password` becomes available — which is the point of `configFile`: `from`, `user` and the password in **one** agenix secret, and no separate cleartext password file at all.

Measured: the check applies to the **resolved** file, not to the symlinks pointing at it, so the chain this module builds passes at `0400` and is refused at `444`.

### The agenix secret needs an `owner`

agenix writes `root:root 0400` by default, and msmtp runs as the user, so without

```Nix
age.secrets.msmtp-omoper = {
  file = ../secrets/msmtp-omoper.age;
  owner = "omoper";     # not optional
  mode = "0400";
};
```

the file is unreadable by the one process that needs it — and mail simply stops going out. Same rule as `passwordFile`, and it bites harder here because the whole configuration is in that file.

## SSH Key Auto-loading

The module does not load keys. It writes an `ssh_config` that **names** them, and turns on the agent so that whatever ssh unlocks stays unlocked:

- `services.ssh-agent.enable`, gated on `home.sshKeys.enable`
- `AddKeysToAgent yes` plus one `IdentityFile` line per name below, under `Host *`

The distinction matters: an identity named here that has no file on disk is still **offered** by ssh, and each offer costs an attempt against a server's `MaxAuthTries`.

### Base name keys

```Nix
sshKeys.baseName = {
  enable = true;
  name = "MyKey";
};
```

Names:

- `~/.ssh/MyKey`
- `~/.ssh/MyKey_ed25519`
- `~/.ssh/MyKey_rsa`

**Both `enable` and a non-empty `name` are required.** With an empty name the three would become `~/.ssh/_ed25519`, `~/.ssh/_rsa` and `~/.ssh/` — the directory itself — so the block is skipped entirely instead.

### Additional keys

```Nix
sshKeys.names = [ "work" "github" ];
```

Names `~/.ssh/work` and `~/.ssh/github`, independently of `baseName`.

### `home.sshHosts` — per-host blocks

```Nix
sshHosts."203.0.113.7" = {
  User = "root";
  IdentityFile = [ "~/.ssh/id_ed25519" ];
  IdentitiesOnly = true;
};
```

Attribute names are written into `ssh_config` verbatim; its keywords are case-insensitive.

Two things worth knowing before using it:

- `IdentityFile` **accumulates** across every matching block. A host block **adds to** the global ones rather than replacing them, which is why `IdentitiesOnly = true` belongs here: it is what stops ssh from also offering everything in the agent.
- The blocks are merged as `sshHosts // { "*" = … }`, so a pattern literally named `*` would be silently discarded. Put global directives in the module, not in a `"*"` entry.

## Examples

### Minimal user

```Nix
{pkgs, ...}: {
  # ... other host configurations ...
  myUsers.omoper.enable = true;
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
