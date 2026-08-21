FLAKE="${DEPLOY_MIGRATION_FLAKE:-.}"

if [ "$#" -ne 1 ]; then
  echo "usage: deploy-migration <node>   (flake via DEPLOY_MIGRATION_FLAKE, default .)" >&2
  exit 2
fi

TARGET="${1#.#}"

HOST="$(nix eval --raw "${FLAKE}#deploy.nodes.${TARGET}.hostname")"
SSH_USER="$(nix eval --raw "${FLAKE}#deploy.nodes.${TARGET}.profiles.system.sshUser")"
REMOTE="${SSH_USER}@${HOST}"
REMOTE_HOME="$(ssh "$REMOTE" "getent passwd ${SSH_USER} | cut -d: -f6")"
BACKUP="${REMOTE_HOME}/backups/postgres_deploy_backup.sql"
LOCAL_COPY="${HOME}/postgres_backup_${TARGET}.sql"

log() {
  echo "[$(date --iso-8601=seconds)] $1" | tee -a "${HOME}/deploy_migration.log"
}

server_major() {
  ssh "$REMOTE" "sudo -u postgres psql -tAc 'SHOW server_version_num'" | tr -d '[:space:]'
}

log "target=${TARGET} host=${HOST} user=${SSH_USER} backup=${BACKUP}"

before="$(server_major)"
if ! [[ "$before" =~ ^[0-9]+$ ]]; then
  log "ERROR: could not read the remote PostgreSQL version; aborting"
  exit 1
fi
log "PostgreSQL server_version_num before deploy: ${before}"

log "backing up on the remote"
ssh "$REMOTE" "mkdir -p ${REMOTE_HOME}/backups && sudo -u postgres pg_dumpall > ${BACKUP}" || {
  log "ERROR: remote backup failed; deployment cancelled"
  exit 1
}

log "downloading the backup to ${LOCAL_COPY}"
scp "${REMOTE}:${BACKUP}" "$LOCAL_COPY" || {
  log "ERROR: backup download failed; deployment cancelled"
  exit 1
}

log "deploying"
deploy "${FLAKE}#${TARGET}" || {
  log "ERROR: deployment failed; migration cancelled"
  exit 1
}

after="$(server_major)"
if ! [[ "$after" =~ ^[0-9]+$ ]]; then
  log "ERROR: could not read the remote PostgreSQL version after deploy"
  exit 1
fi
log "PostgreSQL server_version_num after deploy: ${after}"

if [ "$after" -le "$before" ]; then
  log "version unchanged or downgraded (${before} -> ${after}); no restore needed"
  exit 0
fi

log "version upgraded (${before} -> ${after}); restoring into the fresh cluster"
if ! ssh "$REMOTE" "test -s ${BACKUP}"; then
  log "ERROR: no usable backup at ${BACKUP} on the remote; restore aborted"
  exit 1
fi
ssh "$REMOTE" "sudo -u postgres psql -f ${BACKUP} postgres" || {
  log "ERROR: remote restore failed"
  exit 1
}
ssh "$REMOTE" "rm -f ${BACKUP}"
log "restore complete; local copy kept at ${LOCAL_COPY}"
