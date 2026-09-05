# postgresql — PostgreSQL DSL

This module provides a declarative interface for configuring PostgreSQL on NixOS. It supports initial database setup, dump restoration, authentication modes, logging configuration and TCP settings.

## Purpose

- Provide a unified PostgreSQL configuration for all hosts
- Support both fresh installations and database restoration
- Avoid manual SQL initialization steps
- Integrate cleanly with migration scripts
- Ensure safe and predictable PostgreSQL behavior

This module is only active when `postgresql.enable = true`.

## Features

- Version selection
- Initial setup (role, password, database)
- Dump restoration
- Authentication modes
- TCP enable/disable
- Logging configuration

## Options

### `postgresql.enable`

Enables the PostgreSQL service.

### `postgresql.package`

PostgreSQL version to install. Defaults to `pkgs.postgresql_17`.

### `postgresql.port`

Port for the PostgreSQL server. Defaults to `5432`.

## `postgresql.ensure` — the main path

Databases and roles that must exist, with the role owning its database:

```nix
{
  postgresql.ensure = [
    { database = "myapp"; role = "myapp"; }
    { database = "other"; role = "other"; passwordFile = "/run/agenix/other-db"; }
  ];
}
```

| Field | Default | |
| --- | --- | --- |
| `database` | — | required |
| `role` | — | required; the role the app connects as |
| `owner` | `true` | transfer ownership of the database to the role |
| `passwordFile` | `null` | path **on the target host**; `null` leaves the password alone, which is what `authMode = "trust"` wants |

`owner` exists because upstream's `ensureDBOwnership` only covers a database named after its role, and the historical pairs here are not.

`passwordFile` is a **string, not a path**: interpolating a path copies the file into the world-readable store. The reconciling unit reads it as root, so it need not be readable by `postgres`.

### Additive only, on purpose

It **never drops or renames anything it does not know about**, because these machines predate this config and hold databases nothing declares. A "desired state" that also removed would have destroyed them.

### How it is applied

Creation goes through `services.postgresql.ensureDatabases` and `ensureUsers`, which create when absent and do nothing when present. Everything else — ownership, passwords — is reconciled on every activation by **`postgresql-ensure.service`**.

That unit is deliberately its own, rather than a `postgresql-setup.postStart` fragment: that hook is a **single script shared with every other module that appends to it**, so one failure there would silently skip whatever came after — including another module's `ALTER USER`.

### Assertions

- every entry needs a non-empty database and role
- two entries cannot name the same database, or they would fight over its owner
- a database already declared by another module in `ensureDatabases` is refused

## Initial Setup

> The single-pair form of `ensure`, kept for compatibility and **stricter**: it requires a password file where `ensure` allows none. The module emits a warning when it is used.
>
> The name misleads: its SQL runs on **every** activation, not only the first.

```nix
postgresql.initialSetup = {
  enable = true;
  role = "myuser";
  passwordFile = "/path/to/password.txt";
  database = "mydb";
};
```

When enabled, the module:

- Creates the role if it doesn't exist
- Sets the password using the provided file
- Creates the database
- Grants privileges

### Requirements

If `initialSetup.enable = true`, then:

- `role` must not be empty (defaults to `postgres` )
- `passwordFile` mustn't be null
- `database` mustn't be empty

These are enforced via Nix assertions.

## Dump Restoration

Instead of initial setup, you may restore a SQL dump:

```nix
postgresql.dumpFile = "/path/to/dump.sql";
```

This generates an `initialScript` that runs:

```psql
\i /path/to/dump.sql
```

### Mutual exclusion

You cannot use both:

- `initialSetup.enable = true`
- `dumpFile != null`

at the same time. This is enforced by assertions.

## Authentication

The module owns `pg_hba.conf` outright: it fixes `services.postgresql.authentication` at a priority that discards every other definition, including upstream's defaults and a `mkAfter` from an application's own module. That is deliberate — on a host several applications share, **one place decides who may authenticate** — and it has two consequences worth stating plainly.

### The file it writes

```text
local all postgres peer map=postgres     ← always, whatever authMode says
<postgresql.authRules, in order>
local all all <authMode>
host all all ::1/128 <authMode>
host all all 127.0.0.1/32 <authMode>
```

`pg_hba` is **first-match-wins**, which is why the specific rules come first and the catch-all last.

### `postgresql.authMode`

```Nix
postgresql.authMode = "trust" | "md5" | "scram";
```

Governs **application traffic**: the local socket and both loopback addresses. `"scram"` is emitted as `scram-sha-256`, which is what `pg_hba` actually accepts.

### The administrative rule, and why it is not optional

`local all postgres peer map=postgres` is emitted whatever `authMode` says, because `postgresql-setup`, `postgresql-ensure`, the migration scripts and the live checks all reach the socket as the `postgres` system user with **no password**.

Without it, `authMode = "scram"` is a deadlock at the first activation: the unit that sets the role passwords cannot connect, because there are no passwords yet. Measured against a real cluster — the connection is refused with `Password for user postgres`, and every dump and restore path goes with it.

Upstream's other default, `local all all peer`, is deliberately **not** emitted. It would require each application's system user to match the role it connects as, which is rarely true — an app running as `myapp-svc` and connecting as `myapp` would stop working the moment it appeared.

### `postgresql.authRules`

Per-role exceptions, emitted before the catch-all.

```Nix
postgresql.authRules = [
  { role = "devrole"; address = "127.0.0.1/32"; method = "trust"; }
  { type = "local"; role = "devrole"; method = "trust"; }
];
```

| Field | Default | |
| --- | --- | --- |
| `type` | `"host"` | `local`, `host`, `hostssl`, `hostnossl`. `local` is the socket and takes no address |
| `database` | `"all"` | |
| `role` | — | required |
| `address` | `null` | required unless `type = "local"` |
| `method` | — | written as `pg_hba` spells it: `scram-sha-256`, not `scram` |

This is the supported way for a role to keep an exception when the host moves to `scram` — an application still in a development mode that expects `trust`, for instance. Because the module discards a `mkAfter` from elsewhere, injecting the rule from the application's own module would fail **silently**: the lines simply never reach the file.

Two assertions guard it: an address on a `local` rule, or a missing one anywhere else, and two rules matching the same connection — where the second is dead rather than wrong, which is worse.

## TCP Settings

```Nix
postgresql.tcp.enable = true;
```

Controls:

```Nix
services.postgresql.enableTCPIP
```

## Logging

```Nix
postgresql.logStatements = "all" | "mod" | "none";
```

Controls:

```nix
settings.log_statement
```

## Behavior Summary

| Feature            | initialSetup | dumpFile | Notes                 |
|--------------------|--------------|----------|-----------------------|
| Role creation      | ✔️           | ❌       | Only in initial setup |
| Password assignment| ✔️           | ❌       | Uses passwordFile     |
| Database creation  | ✔️           | ❌       | Only in initial setup |
| Dump restoration   | ❌           | ✔️       | Uses \i dump.sql      |
| Authentication     | ✔️           | ✔️       | Via authMode          |
| Logging            | ✔️           | ✔️       | Via logStatements     |

## Examples

### Fresh installation

```Nix
{pkgs, ...}: {
  # ... other host configurations ...
  postgresql = {
    enable = true;
    initialSetup = {
      enable = true;
      role = "app";
      passwordFile = "/home/app/pgpass.txt";
      database = "appdb";
    };
    authMode = "scram";
  };
  # ... other host configurations ...
}
```

### Restore from dump

```Nix
{pkgs, ...}: {
  # ... other host configurations ...
  postgresql = {
    enable = true;
    dumpFile = "/home/app/backup.sql";
    authMode = "md5";
  };
  # ... other host configurations ...
}
```

### Development environment

```Nix
{pkgs, ...}: {
  # ... other host configurations ...
  postgresql = {
    enable = true;
    authMode = "trust";
    logStatements = "all";
  };
  # ... other host configurations ...
}
```

## Relationship with the migration paths

Two things migrate a major, and both depend on this module to know which one is pinned:

| | |
| --- | --- |
| `GATE_MIGRATE=1` with the [deploy gate](../scripts/guards.md) | a remote deploy that means to change the major |
| [`nixos-rebuild-migration`](../scripts/nixos-rebuild-migration.md) | the same, rebuilding on the machine itself |

Both detect the version change, back up before it and restore after. What they read from here is `postgresql.package`, which is why it is pinned per host and asserted against what the machine really runs — a shared pin would point one host at a stale data directory.

## When to use this module

Use it when:

- A host needs PostgreSQL
- You want declarative initialization
- You want safe upgrades and migrations

Do **not** use it for:

- External PostgreSQL servers
- Containers with ephemeral storage
