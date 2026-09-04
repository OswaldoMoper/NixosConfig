# run-local — the app stack as plain processes

`lib.mkLocalRunApps` generates `run-<host>-local` for every host that serves something. It starts a throwaway PostgreSQL and runs the host's app units as ordinary user processes.

```bash
nix run .#run-myHost-local
```

Ctrl-C stops everything and removes the directory it made.

## What it is for, and what it is not

**For iterating on an app.** It starts in seconds, needs no root, and leaves nothing behind.

**Not for testing a configuration change.** It does not run the activation, does not run systemd, does not run nginx, and does not render `pg_hba.conf`. A change to a module, a unit's ordering, a tmpfiles rule or an authentication method is invisible here — [the VM](../modules/vm.md) is the instrument for that, and it is the same configuration rather than an approximation.

Knowing which of the two answers a question is most of the value of having both.

## How it decides what to run

Everything comes from the host's own evaluated configuration. Nothing is written twice.

| What | Where it comes from |
| --- | --- |
| Which units | `webStack` apps — `name` for a `managed` one, the app's `unit` field for a `profile` one |
| The command | that unit's `serviceConfig.ExecStart` |
| The environment | that unit's `environment`, which already carries its resolved `PATH` |
| Databases and roles | `services.postgresql.ensureDatabases` and `postgresql.ensure` |
| Secret contents | `vm.secretValues`, the same option [the VM](../modules/vm.md) uses |

A `profile` app whose host never declared `unit` is **skipped with a message naming it**, because nothing can derive the unit name: an app called `MoperApp` runs as `moperapp`.

## The two rewrites, and why they are not guesswork

An app built for a machine holds absolute paths. Only paths **the unit itself declares** get moved:

**`StateDirectory`** is systemd's own statement of "these are mine under `/var/lib`". Each top-level entry is redirected into the run directory, in the `ExecStart` arguments and in every environment value, and `STATE_DIRECTORY` is set. This is what lets a hardened profile app run — one whose command embeds `--scratch /var/lib/myapp/scratch` follows along.

**`EnvironmentFile`** points into `/run/agenix`, which does not exist here. It resolves to the test file written from `vm.secretValues`, and its `KEY=value` lines join the environment.

Anything else absolute is left exactly as it is, and an app that needs it will say so by failing.

## PostgreSQL

A fresh cluster in the run directory, **never the machine's** — a local run must not be able to reach real data.

It listens on a **Unix socket only**. That is the reason there is no port probing and no port juggling: with no TCP and a socket directory unique to each run, the declared port cannot collide with anything, not even with another `run-<host>-local`. libpq reads a `PGHOST` beginning with `/` as a socket directory, so `PGHOST` and `PGPORT` are set for every unit, and any variable ending in `PGHOST` or `PGPORT` — an app that named its own — is pointed at the same place.

`LOCAL_PG_PORT` overrides the port if an app hardcodes one somewhere this cannot see.

## Limits worth knowing before trusting it

- **App ports are not moved.** Where the port lives differs per app — an environment variable for one, an `ExecStart` argument for another — so moving it generically would be guessing. If one is taken, the app says so and the others keep running.
- **Hardening is ignored.** A profile app in production mode carries `ProtectSystem`, `DynamicUser` and a dozen more keys that a user process cannot honour. Only `ExecStart`, `WorkingDirectory`, `EnvironmentFile` and `StateDirectory` are read.
- **State the machine holds is not conjured.** An app needing a checkout of its own source tree on disk fails here exactly as it does in a fresh VM. That is a fact about the app.
- **No nginx, so no vhosts.** Apps answer on their own ports, not through a domain.
