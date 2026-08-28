FLAKE="${DEPLOY_MIGRATION_FLAKE:-.}"

if [ "$#" -ne 1 ]; then
  echo "usage: deploy-migration <node>   (flake via DEPLOY_MIGRATION_FLAKE, default .)" >&2
  exit 2
fi

TARGET="${1#.#}"

HOST="$(nix eval --raw "${FLAKE}#deploy.nodes.${TARGET}.hostname")"

DEPLOY_ARGS=()
if [ -n "${GATE_SSH_USER:-}" ]; then
  SSH_USER="$GATE_SSH_USER"
  DEPLOY_ARGS+=(--ssh-user "$GATE_SSH_USER")
else
  SSH_USER="$(nix eval --raw "${FLAKE}#deploy.nodes.${TARGET}.profiles.system.sshUser")"
fi
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

before="$(server_major || true)"
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
deploy "${FLAKE}#${TARGET}" ${DEPLOY_ARGS[@]+"${DEPLOY_ARGS[@]}"} || {
  log "ERROR: deployment failed; migration cancelled"
  exit 1
}

after="$(server_major || true)"
if ! [[ "$after" =~ ^[0-9]+$ ]]; then
  log "ERROR: could not read the remote PostgreSQL version after deploy"
  exit 1
fi
log "PostgreSQL server_version_num after deploy: ${after}"

if [ "$after" -le "$before" ]; then
  log "version unchanged or downgraded (${before} -> ${after}); no restore needed"
  ssh "$REMOTE" "rm -f ${BACKUP}"
  log "removed the remote dump; local copy kept at ${LOCAL_COPY}"
  exit 0
fi

log "version upgraded (${before} -> ${after}); restoring into the fresh cluster"
if ! ssh "$REMOTE" "test -s ${BACKUP}"; then
  log "ERROR: no usable backup at ${BACKUP} on the remote; restore aborted"
  exit 1
fi

if ! ssh "$REMOTE" "grep -q 'PostgreSQL database dump' ${BACKUP}"; then
  log "ERROR: ${BACKUP} does not look like a pg_dumpall output; restore aborted"
  exit 1
fi

ssh "$REMOTE" "cat ${BACKUP} | sudo -u postgres psql postgres" || {
  log "ERROR: remote restore failed"
  exit 1
}
ssh "$REMOTE" "rm -f ${BACKUP}"
log "restore complete; local copy kept at ${LOCAL_COPY}"
