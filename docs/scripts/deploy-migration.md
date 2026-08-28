# deploy-migration — Remote PostgreSQL Migration Helper

This script performs safe PostgreSQL migrations during **remote deploys** using `deploy-rs`. It backs up the remote cluster before deploying, and restores into the new one only when the deploy moved PostgreSQL to a new major version. All operations are logged to:

```bash
$HOME/deploy_migration.log
```

## Purpose

- Protect remote PostgreSQL instances during deploys
- Automatically detect PostgreSQL major version upgrades
- Create and download full backups before deployment
- Restore data only when required
- Abort deployment safely on any failure
- Provide clear logging for auditing and debugging

This script runs on your machine, not on the server:

```Shell
deploy-migration .#myServer
```

The flake defaults to `.` and can be overridden with `DEPLOY_MIGRATION_FLAKE`.

## Workflow

### 1. Resolve deployment target

The script resolves, using `nix eval` against the flake and one `ssh getent passwd`:

| Variable | Where it comes from |
| --- | --- |
| `TARGET` | the argument, with a leading `.#` stripped |
| `HOST` | `deploy.nodes.<TARGET>.hostname` |
| `SSH_USER` | `GATE_SSH_USER` if set, otherwise `deploy.nodes.<TARGET>.profiles.system.sshUser` |
| `REMOTE_HOME` | `getent passwd` on the remote |
| `BACKUP` | `$REMOTE_HOME/backups/postgres_deploy_backup.sql` |
| `LOCAL_COPY` | `$HOME/postgres_backup_$TARGET.sql` |

`GATE_SSH_USER` is the same override the deploy gate takes, so someone deploying under their own name can use this path too. When it is set, `--ssh-user` is also passed through to `deploy`.

### 2. Read the version before anything happens

```Shell
sudo -u postgres psql -tAc 'SHOW server_version_num'
```

`server_version_num` is the **server's** version (major × 10000 + minor). Not `psql --version`, which reports the client's and is a different number — that confusion is the bug these scripts exist to avoid.

If the value is not a number, the script aborts before touching anything.

### 3. Create remote PostgreSQL backup

On the remote:

```Shell
mkdir -p $REMOTE_HOME/backups && sudo -u postgres pg_dumpall > $BACKUP
```

The redirection runs as `SSH_USER`, so the file lands in their home and belongs to them. That matters in step 6.

If this fails, the deployment is aborted.

### 4. Download backup locally

```Shell
scp $REMOTE:$BACKUP $HOME/postgres_backup_$TARGET.sql
```

This ensures a local copy exists even if the remote restore fails. It is **kept**, never deleted.

### 5. Run deploy-rs

```Shell
deploy .#<TARGET> [--ssh-user <GATE_SSH_USER>]
```

If deploy-rs fails, the migration is canceled.

### 6. Detect the version change, and restore only if it went up

The version is read again the same way. Then:

- **`after <= before`** — no restore is needed. The remote dump is removed and the script exits 0.
- **`after > before`** — the cluster is new and empty, so the dump is restored.

Before restoring, two guards:

```Shell
test -s $BACKUP
grep -q 'PostgreSQL database dump' $BACKUP
```

The second is a shape check: a truncated dump restores happily into a fresh cluster and leaves it half empty.

The restore itself is piped, not `psql -f`:

```Shell
cat $BACKUP | sudo -u postgres psql postgres
```

`postgres` cannot traverse a `0700` home to open a file written by `SSH_USER`, so the file is read by whoever owns it and handed to `psql` on stdin.

### 7. Cleanup

The remote dump is removed on **both** paths — after a restore, and when no restore was needed. The local copy is always kept.

## Error Handling

The script is packaged with `pkgs.writeShellApplication`, which prepends:

```Shell
set -o errexit -o nounset -o pipefail
```

The script itself does not set these, which matters in one place: a command substitution whose command fails takes the whole script down **at the assignment**, before any check of the captured value. The version reads are therefore written as

```Shell
before="$(server_major || true)"
```

so the "could not read the version" message is reachable at all. Without the `|| true` the operator gets exit 1 and no output.

Everything else uses explicit blocks:

```Shell
|| { log "ERROR: ..."; exit 1; }
```

Failures in any of these abort the migration: remote backup creation, backup download, deploy-rs execution, version detection, restore execution.

## Logging

All actions are logged with timestamps to `$HOME/deploy_migration.log`:

- resolved target, host, ssh user and backup path
- the version before and after the deploy
- backup creation and download
- deploy execution
- whether a restore was needed, and its outcome

## When to use this script

Use it when:

- Deploying to a remote NixOS host with PostgreSQL
- The deploy may change the PostgreSQL major version
- You want a guaranteed backup before every deploy

Do **not** use it for:

- Local rebuilds — use `nixos-rebuild-migration`
- Non-PostgreSQL services
- Hosts without PostgreSQL installed

> **It does not run the deploy gate.** `deploy-migration` calls `deploy` directly, so the cache guard, the access guard and the post-deploy verification do **not** run. `nix run .#deploy-<node>` is the path that has them. Folding the two together is planned.

## Example

```Shell
deploy-migration .#hetzner
```

This will back up PostgreSQL on the remote server, download the backup, deploy the new system, restore only if the major version went up, and log everything.
