# nixos-rebuild-migration — Local PostgreSQL Migration Helper

This script extends `nixos-rebuild` with automatic PostgreSQL backup, version detection and conditional restoration. It ensures that local PostgreSQL upgrades never break a rebuild by creating a full backup before rebuilding and restoring it only when required.

All operations are logged to:

```Shell
$HOME/postgres_migration.log
```

## Purpose

- Protect local PostgreSQL data during system rebuilds
- Automatically detect PostgreSQL version upgrades
- Create full backups before `nixos-rebuild`
- Restore data only when required
- Validate service health after rebuild
- Abort rebuild safely on any failure

This script is intended to be run locally:

```Shell
sudo nixos-rebuild-migration switch
```

## Workflow

### 1. Determine real user and HOME

The script resolves:

- `TARGET_USER` (from `SUDO_USER` or `$USER`)
- `USER_HOME` (via `getent passwd`)

If the home directory is invalid, the script aborts.

### 2. Detect PostgreSQL version (before rebuild)

The script runs:

```Shell
runuser -u postgres -- psql -tAc 'SHOW server_version_num'
```

`server_version_num` is the **server's** version (major × 10000 + minor). Reading `psql --version` instead would report the *client's*, which is a different number, and asking the wrong one is the original bug this script exists to avoid.

If the value is not a number, the rebuild is aborted before anything is touched.

### 3. Create local PostgreSQL backup

A full backup is created in:

```Shell
$USER_HOME/backups/postgres_backup.sql
```

using:

```Shell
runuser -u postgres -- pg_dumpall
```

The redirection runs as the invoking user, so the file lands in their home and belongs to them — which is why the restore in step 8 is piped rather than opened by `postgres`.

If this fails, the rebuild is aborted.

### 4. Copy backup to a secondary location

The backup is duplicated to:

```Shell
$USER_HOME/postgres_backup_local.sql
```

This ensures a safe copy exists even if the restore fails.

### 5. Run nixos-rebuild

The script executes:

```Shell
nixos-rebuild <original arguments>
```

If the rebuild fails, the migration is canceled.

### 6. Ensure PostgreSQL is running

If PostgreSQL is not active after the rebuild, the script attempts:

```Shell
systemctl restart postgresql
```

If this fails, the script aborts.

### 7. Detect PostgreSQL version change

The script compares:

- version before rebuild
- version after rebuild

If PostgreSQL was upgraded, a restore is required.

### 8. Restore (only if needed)

Only when the major version went **up** — an unchanged or lower version exits 0 with no restore.

Two guards first: the file must be non-empty, and must contain `PostgreSQL database dump`. The second is a shape check, because a truncated dump restores happily into a fresh cluster and leaves it half empty.

The restore is piped rather than `psql -f`:

```Shell
runuser -u postgres -- psql postgres < $BACKUP
```

`postgres` cannot traverse a `0700` home to open a file written by the invoking user, so the file is read by whoever owns it and handed to `psql` on stdin.

On success the working backup is removed; `$USER_HOME/postgres_backup_local.sql` is always kept.

## Error Handling

The script is packaged with `pkgs.writeShellApplication`, which prepends:

```Shell
set -o errexit -o nounset -o pipefail
```

The script itself does not set these, and that matters in one place: a command substitution whose command fails takes the script down **at the assignment**, before any check of the captured value. The version reads are therefore written as

```Shell
before="$(server_major || true)"
```

so the "could not read the version" message is reachable at all. Without the `|| true` the operator gets exit 1 and no output.

Everything else uses explicit blocks:

```Shell
|| { log "ERROR: ..."; exit 1; }
```

Failures in any of these steps abort the migration:

- version detection  
- backup creation  
- backup copy  
- nixos-rebuild execution  
- PostgreSQL restart  
- restore execution  
- backup validation  

## Logging

All actions are logged with timestamps to:

```Shell
$HOME/postgres_migration.log
```

This includes:

- user resolution
- the version before and after the rebuild
- backup creation and copy
- rebuild execution
- whether a restore was needed, and its outcome

## When to use this script

Use it when:

- Running `nixos-rebuild` on a host with PostgreSQL
- You want safe, automatic migrations
- You want guaranteed backups before every rebuild

Do **not** use it for:

- Remote deploys (use `GATE_MIGRATE=1` with the deploy gate instead)
- Hosts without PostgreSQL installed

## Example

```Shell
sudo nixos-rebuild-migration switch
```

This will:

- Back up PostgreSQL locally  
- Run nixos-rebuild  
- Restore only if PostgreSQL was upgraded  
- Log everything  
