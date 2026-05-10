# common — Base System Module

This module defines the shared baseline configuration for all hosts.  
It contains settings that should apply universally across machines, ensuring
consistency, reproducibility and minimal duplication.

## Purpose

- Provide a unified NixOS base configuration
- Define global Nix and nixpkgs settings
- Enable common services (e.g., SSH)
- Configure Home Manager defaults
- Set fonts and shared paths
- Ensure consistent garbage collection and store behavior

This module is imported by **every host** through the flake.

## Included Configuration

### `system.stateVersion`

Ensures stable behavior across NixOS upgrades. Currently, `25.11`

### Nix settings

- `allow-import-from-derivation`
- `auto-optimise-store`
- `download-buffer-size`
- `gc.automatic`
- `gc.options`
- `extraOptions` (enables flakes and keeps derivations)

### nixpkgs configuration

- `allowUnfree = true`
- Optional overlays (commented out)

### Home Manager defaults

- `home-manager.useGlobalPkgs = true`
- `home-manager.useUserPackages = true`

### SSH

- Enables both `openssh` and `sshd`

### Fonts

Adds shared fonts such as:

- `hack-font`

### pathsToLink

Ensures tools like `direnv` and Zsh completions are available globally.

### configurationRevision

Automatically embeds the flake revision into the system configuration.

## When to modify this module

Add configuration here when:

- It applies to **all** machines
- It is not user-specific
- It is not hardware-specific
- It is not tied to a particular role (server, desktop, WSL, etc.)

## When NOT to modify this module

Avoid placing:

- Host-specific settings  
- Hardware configuration  
- User accounts  
- Web stack configuration  
- PostgreSQL configuration  
- Deployment definitions  

Those belong in their respective modules or host files.
