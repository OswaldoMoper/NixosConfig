TARGET_USER="${SUDO_USER:-$USER}"
USER_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

if [ -z "$USER_HOME" ] || [ ! -d "$USER_HOME" ]; then
  echo "ERROR: no valid HOME for ${TARGET_USER}" >&2
  exit 1
fi

BACKUP="${USER_HOME}/backups/postgres_backup.sql"
LOCAL_COPY="${USER_HOME}/postgres_backup_local.sql"

log() {
  echo "[$(date --iso-8601=seconds)] $1" | tee -a "${USER_HOME}/postgres_migration.log"
}

server_major() {
  runuser -u postgres -- psql -tAc 'SHOW server_version_num' | tr -d '[:space:]'
}

before="$(server_major || true)"
if ! [[ "$before" =~ ^[0-9]+$ ]]; then
  log "ERROR: could not read the local PostgreSQL version; aborting"
  exit 1
fi
log "PostgreSQL server_version_num before rebuild: ${before}"

log "backing up to ${BACKUP}"
mkdir -p "${USER_HOME}/backups"
runuser -u postgres -- pg_dumpall > "$BACKUP" || {
  log "ERROR: backup failed; rebuild cancelled"
  exit 1
}
cp "$BACKUP" "$LOCAL_COPY" || {
  log "ERROR: could not copy the backup to ${LOCAL_COPY}; rebuild cancelled"
  exit 1
}

log "running nixos-rebuild $*"
nixos-rebuild "$@" || {
  log "ERROR: nixos-rebuild failed; migration cancelled"
  exit 1
}

if ! systemctl is-active --quiet postgresql; then
  log "WARN: postgresql is not active after the rebuild; restarting"
  systemctl restart postgresql || {
    log "ERROR: could not restart postgresql; manual intervention needed"
    exit 1
  }
fi

after="$(server_major || true)"
if ! [[ "$after" =~ ^[0-9]+$ ]]; then
  log "ERROR: could not read the PostgreSQL version after the rebuild"
  exit 1
fi
log "PostgreSQL server_version_num after rebuild: ${after}"

if [ "$after" -le "$before" ]; then
  log "version unchanged or downgraded (${before} -> ${after}); no restore needed"
  exit 0
fi

log "version upgraded (${before} -> ${after}); restoring into the fresh cluster"
if [ ! -s "$BACKUP" ]; then
  log "ERROR: ${BACKUP} is missing or empty; restore aborted"
  exit 1
fi
if ! grep -q "PostgreSQL database dump" "$BACKUP"; then
  log "ERROR: ${BACKUP} does not look like a pg_dumpall output; restore aborted"
  exit 1
fi

runuser -u postgres -- psql postgres < "$BACKUP" || {
  log "ERROR: restore failed"
  exit 1
}
rm -f "$BACKUP"
log "restore complete; copy kept at ${LOCAL_COPY}"
