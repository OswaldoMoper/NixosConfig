# deploy-migration — Remote PostgreSQL Migration Helper

This script performs safe PostgreSQL migrations during **remote deploys** using `deploy-rs`. It ensures that database upgrades never break a production deployment by automatically backing up, restoring and validating PostgreSQL data on the remote server. All operations are logged to:

```bash
$HOME/deploy_migration.log
```

## Purpose

- Protect remote PostgreSQL instances during deploys
- Automatically detect PostgreSQL version upgrades
- Create and download full backups before deployment
- Restore data only when required
- Abort deployment safely on any failure
- Provide clear logging for auditing and debugging

This script is intended to be run locally:

```Shell
deploy-migration .#myServer
```

## Workflow

### 1. Resolve deployment target

The script extracts:

- `TARGET` (flake deploy target)
- `HOST` (remote hostname)
- `USER` (SSH user)
- `REMOTE_HOME` (remote user's home directory)
- `APP` (derived from remote home path)

These values are obtained using:

- `nix eval`
- `ssh getent passwd`

### 2. Create remote PostgreSQL backup

The script runs on the remote server:

```Shell
pg_dumpall -U postgres > $REMOTE_HOME/backups/postgres_deploy_backup.sql
```

If this fails, the deployment is aborted.

### 3. Download backup locally

The backup is copied to:

```Shell
$HOME/postgres_backup_<APP>.sql
```

This ensures a local copy exists even if the remote restore fails.

### 4. Run deploy-rs

The script executes:

```Shell
deploy .#<TARGET>
```

If deploy-rs fails, the migration is canceled.

### 5. Detect PostgreSQL version change

The script compares:

- version before deploy
- version after deploy

If PostgreSQL was upgraded, a restore is required.

### 6. Restore (only if needed)

If a version upgrade is detected:

- The backup is restored on the remote server:

```Shell
psql -U postgres < postgres_deploy_backup.sql
```

### 7. Cleanup

Temporary remote backup files are deleted.

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

- remote backup creation  
- backup download  
- deploy-rs execution  
- version detection  
- restore execution  

## Logging

All actions are logged with timestamps to:

```Shell
$HOME/deploy_migration.log
```

This includes:

- variable resolution  
- backup creation  
- backup download  
- deploy execution  
- version comparison  
- restore operations  
- validation queries  

## When to use this script

Use it when:

- Deploying to a remote NixOS host with PostgreSQL
- You want safe, automatic migrations
- You want deploy-rs to be database-aware
- You want guaranteed backups before every deploy

Do **not** use it for:

- Local rebuilds (`nixos-rebuild`)
- Non-PostgreSQL services
- Hosts without PostgreSQL installed

## Example

```Shell
deploy-migration .#hetzner
```

This will:

- Back up PostgreSQL on the remote server  
- Download the backup  
- Deploy the new system  
- Restore only if PostgreSQL was upgraded  
- Log everything  
