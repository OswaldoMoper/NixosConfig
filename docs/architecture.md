# Architecture Overview

This repository implements a universal, currently optimized for x86_64-linux systems, modular NixOS architecture:

- **Multihost**: each file in `hosts/` becomes a NixOS configuration
- **Multiuser**: declarative users with Home Manager integration
- **Multiapp**: web applications defined through the `webStack` module
- **Modular**: reusable NixOS modules in `nixosModules/`
- **Single flake**: all systems share the same base

## Host auto-detection

The flake automatically reads all `.nix` files in `hosts/` and generates:

- `nixosConfigurations.<host>`
- `deploy.nodes` (if deployment is declared)
- Every `.nix` file in `hosts/` must be a valid NixOS configuration.

Adding new machines requires zero modifications to `flake.nix`.

## Deployment architecture

The `deployment.nix` module defines a declarative DSL for deploy-rs:

- hostname
- fastConnection
- profiles
- activation paths

The flake flattens all deployment definitions into `deploy.nodes`.
