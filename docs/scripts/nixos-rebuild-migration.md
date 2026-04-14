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
psql --version
```

If this fails, the rebuild is aborted.

### 3. Create local PostgreSQL backup

A full backup is created in:

```Shell
$USER_HOME/backups/postgres_backup.sql
```

using:

```Shell
pg_dumpall -U postgres
```

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

If a version upgrade is detected:

- The backup is validated (must contain “PostgreSQL database dump”)

If the restore fails, the script aborts.

## Error Handling

The script uses:

```Shell
set -e
```

and explicit error blocks:

```Shell
|| { log "ERROR: ..."; exit 1 }
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
- backup creation  
- backup copy  
- rebuild execution  
- version comparison  
- restore operations  
- validation queries  

## When to use this script

Use it when:

- Running `nixos-rebuild` on a host with PostgreSQL
- You want safe, automatic migrations
- You want guaranteed backups before every rebuild

Do **not** use it for:

- Remote deploys (use `deploy-migration.sh` instead)
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
