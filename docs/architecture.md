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

**Modules are listed twice.** The `nixosModules` *output* is a directory sweep, so a new file there is exported to consumers automatically. But the list applied to this repo's own hosts is written out by hand. A module can therefore be shipped and never evaluated here — which has happened. The two agree today; nothing enforces that they keep agreeing.

Both sweeps are one function — `lib.nixFilesIn`, exported like the rest of `lib/` — so the `.nix` filter cannot be present in one and missing in the other. It has to be there: anything else in that directory would be `import`ed as a module and break **the consuming flake**, not this one. That is not hypothetical — the module sweep once lacked the filter, and the failure showed up downstream.

## Deployment architecture

`deployment.nix` defines a declarative DSL for deploy-rs — hostname, `fastConnection`, profiles, activation paths, and the two rollback switches — which `lib.mkDeployNodes` flattens into `deploy.nodes`.

`lib.mkPreDeployApps` generates the gated alternative per node: `deploy-<node>` plus the guards individually. See [the gate and its guards](./scripts/guards.md).

`lib.mkVmApps` generates `run-<host>-vm` for every host that can boot one, so a change can be seen working locally before it reaches a machine. It is the **same** configuration — `vm.nix` fills in NixOS's `vmVariant`, so the host closure does not move. See [local VMs](./modules/vm.md).

`lib.mkLocalRunApps` generates `run-<host>-local`: the same host's app units as plain processes against a throwaway postgres. **Weaker than the VM on purpose** — no activation, no systemd, no nginx — and correspondingly faster. It answers "does the app work", where the VM answers "does the configuration work". See [run-local](./scripts/run-local.md).

Deploys **build where you run them** and only copy the closure, so the servers never compile the apps. That is why binary caches are declared on the host that builds rather than in `common.nix`.

## What `nix flake check` here does and does not see

Two checks:

| | |
| --- | --- |
| `checks.hosts` | forces `system.build.toplevel.drvPath` for **every** host in `hosts/`. That is an *evaluation*, not a build: assertions fire, option types are enforced, and a module that no longer evaluates fails here rather than in the consuming flake after a push |
| `checks.scripts` | shellcheck over all of `scripts/` |

`hosts` discards the string context on purpose, so nothing is built. A package that fails to compile is still invisible here.

**And one host is not a fleet.** The check only sees conflicts this repo's own configuration can produce, which is the narrow case. A module that unconditionally asserts `programs.nix-ld.enable = false` evaluates perfectly here — there is nothing to disagree with it — and breaks every consumer whose own module says `true`. Measured, and the reason an enable-shaped option may only ever turn something on.

`lib/default.nix` is also only half exercised: `deployPkg` is never passed and the single local host declares no `deployment`, so `deploy.nodes` is empty and the **deploy** gate is unreachable from here. The **rebuild** gate is not — every host gets one, so `rebuild-spartanWSL` is built and shellchecked.

Worth knowing before trusting a green check on a change to `lib/` or a module.

## Where things live

| | |
| --- | --- |
| `nixosModules/` | the product: options other flakes consume |
| `lib/` | `nixFilesIn`, `mkDeployNodes`, `mkPreDeployApps`, `mkVmApps`, `mkLocalRunApps` |
| `scripts/` | the two gates, their four guards, and the database rename |
| `hosts/` | this repo's own machines — currently one |
| `hmProfiles/` | per-user Home Manager profiles; searched via `hmProfiles.dirs`, and a consumer's own directory wins |

Secrets are deliberately absent. The agenix module reaches every host, but the recipients and the `.age` files live in the flake that declares the real machines: this one declares an example, and an example has no secrets to keep.
