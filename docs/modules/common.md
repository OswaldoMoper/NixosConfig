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

Ensures stable behavior across NixOS upgrades. Currently, `26.05`

### Nix settings

- `allow-import-from-derivation`
- `auto-optimise-store`
- `download-buffer-size`
- `gc.automatic`
- `gc.dates` (weekly)
- `gc.options` (delete older than 30 days)
- `package` (set stable nixVersions)
- `extraOptions` (enables flakes and keeps derivations)

### nixpkgs configuration

- `allowUnfree = true`

### Home Manager defaults

- `home-manager.useGlobalPkgs = true`
- `home-manager.useUserPackages = true`

### SSH

- Enables `services.openssh`

### Fonts

Adds shared fonts such as:

- `hack-font`

### pathsToLink

Ensures tools like `direnv` and Zsh completions are available globally.

### configurationRevision

Automatically embeds the flake revision into the system configuration.

### `NetworkManager-wait-online`, off under WSL

`nm-online` waits for NetworkManager to declare startup complete, and under WSL it never does: the interface arrives already configured, NM reports it `connected (externally)`, and the unit **fails on every switch** for nothing. Nothing depends on it — `cloudflared` reaches `network-online.target` and starts while it is still failing.

Two things about how it is written, and both are deliberate:

- guarded on `config ? wsl` and not only on its value, because a consuming flake that does not import `nixos-wsl` has no `wsl` namespace at all and reading it would fail evaluation there
- `mkDefault`, so a host that wants the unit back only has to say `= true`

This is the one piece of conditional logic in a module whose job is what is always true. It earns the place by being a **derived fact** rather than a preference: on WSL the unit cannot succeed, so there is nothing for a host to decide.

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
