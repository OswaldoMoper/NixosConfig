# Architecture Overview

This repository is a **library of NixOS modules**. That is the fact that explains most of the rest: `spartanWSL` is the only host it configures directly, while the modules, `lib/` and `scripts/` are the product.

Currently optimized for `x86_64-linux`.

- **Multihost**: each file in `hosts/` becomes a NixOS configuration
- **Multiuser**: declarative users with Home Manager integration
- **Multiapp**: web applications defined through the `webStack` module
- **Modular**: reusable NixOS modules in `nixosModules/`
- **Single flake**: all systems share the same base

## Two sweeps, and only one of them is automatic

**Hosts are auto-detected.** The flake reads every `.nix` file in `hosts/` and generates `nixosConfigurations.<host>`, plus `deploy.nodes` where a `deployment` is declared. Adding a machine needs zero changes to `flake.nix`.

**Modules are listed twice.** The `nixosModules` *output* is a directory sweep, so a new file there is exported to consumers automatically. But the list applied to this repo's own hosts is written out by hand. A module can therefore be shipped and never evaluated here — which has happened.

Both sweeps filter on `.nix`. The module one must, because anything else in that directory would be `import`ed as a module and break **the consuming flake**, not this one.

## Deployment architecture

`deployment.nix` defines a declarative DSL for deploy-rs — hostname, `fastConnection`, profiles, activation paths, and the two rollback switches — which `lib.mkDeployNodes` flattens into `deploy.nodes`.

`lib.mkPreDeployApps` generates the gated alternative per node: `deploy-<node>` plus the guards individually. See [the gate and its guards](./scripts/guards.md).

`lib.mkVmApps` generates `run-<host>-vm` for every host that can boot one, so a change can be seen working locally before it reaches a machine. It is the **same** configuration — `vm.nix` fills in NixOS's `vmVariant`, so the host closure does not move. See [local VMs](./modules/vm.md).

Deploys **build where you run them** and only copy the closure, so the servers never compile the apps. That is why binary caches are declared on the host that builds rather than in `common.nix`.

## What this repo cannot check about itself

`nix flake check` here runs shellcheck over `scripts/` and nothing else. `lib/default.nix` is exercised only by the consuming flake: `deployPkg` is never passed, so the gate is unreachable, and the single local host declares no `deployment`, so `deploy.nodes` is empty.

Worth knowing before trusting a green check on a change to `lib/` or a module.

## Where things live

| | |
| --- | --- |
| `nixosModules/` | the product: options other flakes consume |
| `lib/` | `mkDeployNodes`, `mkPreDeployApps`, `mkVmApps` |
| `scripts/` | the gate, its guards, the migration helpers |
| `hosts/` | this repo's own machines — currently one |
| `hmProfiles/` | per-user Home Manager profiles; searched via `hmProfiles.dirs`, and a consumer's own directory wins |
| `secrets/` | agenix recipients |
