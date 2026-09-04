# vm — every host as a local QEMU machine

Fills in NixOS's own `virtualisation.vmVariant` so any host can be booted locally before a change reaches a machine anyone depends on.

## Purpose

**It is the same configuration, not a lookalike.** `vmVariant` is a NixOS mechanism: the host's closure is byte-identical whether or not the VM exists, so what boots locally is what will boot there. Anything else — a second host file, a "dev" profile — drifts from the real one the moment someone forgets to change both.

That matters because a whole class of failure is invisible to pure evaluation. Two found this way:
a directory the app could not create because it sat at the filesystem root, and a tmpfiles rule whose `-` for owner means *root*, not *leave it alone*. Neither shows up in `nix flake check`.

## What it changes, and nothing else

Five deltas from the real host. Everything else is the host.

| Delta | Why |
| --- | --- |
| One nginx port per vhost, from `vm.portBase` | A VM has no DNS, so `Host` headers cannot tell the vhosts apart |
| No TLS, no ACME | There is no public name to order a certificate for |
| Test contents where the agenix secrets go | They are encrypted to the real host's keys |
| `root` and the web stack manager get `vm.password` | Their real hashes come from agenix, so otherwise there is no way in |
| The guest firewall opens the forwarded ports | The real hosts only allow 22, 80 and 443 |

The forwarding itself is **not** baked in: `run-<host>-vm` builds `QEMU_NET_OPTS` at run time, so the host side can move when a port is already taken.

## Options

### `vm.portBase`

First guest-side nginx port, default `8080`. One port per vhost, in declaration order.

### `vm.password`

Console password for `root` and for `webStack.manager` inside the VM. Default `"dev"`.

It gates on the manager account **existing**: a host that serves no app never imports the profile that declares it, and `users.users.x = mkIf false {}` still creates the name — so the attribute itself has to be conditional, not its contents.

### `vm.secretValues`

Test contents for named agenix secrets. A secret not named here gets an **empty file**, which is what most consumers want.

```Nix
vm.secretValues = {
  myapp-db-password = "test";
  myapp-env = "MYAPP_PGPASS=test";
};
```

Name the ones whose consumer **rejects** an empty value. A `passwordFile` does, deliberately: psql reads an empty password as "clear it", so the unit aborts rather than silently dropping a role's password. Without an entry here, wiring a `passwordFile` makes `postgresql-ensure` fail in the VM by design.

And usually a role password has to be named **twice** — once for the `.age` the database reconciles from, once inside the `environmentFile` the app reads. Miss one and the app sends a password the cluster does not have, which reads as "postgres rejects the backend", not as "the test values disagree".

> ⚠️ **Never a real secret.** These land in the nix store, world-readable.

## Running one

`lib.mkVmApps` generates `run-<host>-vm` per host in the consuming flake:

```bash
nix run .#run-myHost-vm
nix run .#run-myHost-vm -- --port-base 19000
VM_PORT_BASE=19000 nix run .#run-myHost-vm
```

It prints the domain-to-port table on startup and forwards ssh one port past the last vhost. A fixed host port is a trap — 8080 is often taken, and on WSL by something Windows holds that `ss` inside WSL cannot even see.

**Hosts with no initrd are skipped**, because a VM boots and they cannot. WSL is the case. The test is `system.build ? initialRamdisk`: `system.build.vm` exists on every host, so it cannot be the one.

A host that declares no vhost still gets a VM — it forwards ssh and nothing else.

## Limits worth knowing before trusting it

An app that needs state living on the machine rather than in its closure will not come up. The measured case is a Yesod wrapper that does `cd ~/app && touch src/Settings/StaticFiles.hs` before starting: it needs a checkout of its own source tree on disk, so its vhost answers 502 in a fresh VM until someone puts one there.

That is a fact about the app, not about the VM — and finding it is the point.
