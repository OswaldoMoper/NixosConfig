#!/usr/bin/env zsh
set -e

TARGET=$(echo "$1" | sed 's/\.#//')

HOST=$(nix eval --raw .#deploy.nodes.${TARGET}.hostname)
USER=$(nix eval --raw .#deploy.nodes.${TARGET}.profiles.system.sshUser)
REMOTE_HOME=$(ssh "${USER}@${HOST}" "getent passwd ${USER} | cut -d: -f6")

APP=${REMOTE_HOME//\/home\//}

SSH_SERVER="ssh ${USER}@${HOST}"
SCP_SERVER="scp ${USER}@${HOST}:"

DEPLOY_CMD="deploy .#${TARGET}"

log() {
  echo "[$(date)] - $1" | tee -a "$HOME/deploy_migration.log"
}

log "TARGET: ${TARGET}"
log "HOST: ${HOST}"
log "USER: ${USER}"
log "REMOTE_HOME: ${REMOTE_HOME}"
log "APP: ${APP}"
log "SSH_SERVER: ${SSH_SERVER}"
log "SCP_SERVER: ${SCP_SERVER}"
log "DEPLOY_CMD: ${DEPLOY_CMD}"

perform_migration() {
  log "INFO: Starting PostgreSQL restore on the remote server..."
  
  $SSH_SERVER "set -e; if [ -s ${REMOTE_HOME}/backups/postgres_deploy_backup.sql ]; then psql -U postgres < ${REMOTE_HOME}/backups/postgres_deploy_backup.sql; else echo 'ERROR: No valid backup found in ${REMOTE_HOME}/backups/postgres_backup.sql' >&2; exit 1; fi" || {
    log "ERROR: Remote server restore failed. Migration canceled."
    exit 1
  }

  log "INFO: Restore completed on remote server."
  $SSH_SERVER "rm -f ${REMOTE_HOME}/backups/postgres_deploy_backup.sql"
  # $SSH_SERVER "psql -d ${APP} -c '\dt'" refactor this
  log "INFO: PostgreSQL migration script executed. Backup directory: $HOME/postgres_backup_${APP}.sql"
}

postgresql_version_before=$($SSH_SERVER "psql --version" | awk '{print $3}' || {
  log "ERROR: Could not retrieve PostgreSQL version before deploy. Exiting."
  exit 1
})

log "INFO: PostgreSQL version before deploy: $postgresql_version_before. Backing up PostgreSQL on the remote server..."
$SSH_SERVER "mkdir -p ${REMOTE_HOME}/backups && pg_dumpall -U postgres > ${REMOTE_HOME}/backups/postgres_deploy_backup.sql" || {
  log "ERROR: Remote server backup failed. Deployment is being canceled."
  exit 1
}

log "INFO: Backup completed on remote server. Downloading backup..."
$SCP_SERVER"${REMOTE_HOME}/backups/postgres_deploy_backup.sql" "$HOME/postgres_backup_${APP}.sql" || {
  log "ERROR: Backup download failed. Deployment is being canceled."
  exit 1
}

log "INFO: Backup downloaded in $HOME/postgres_backup_${APP}.sql. Deployment running..."
$DEPLOY_CMD || {
  log "ERROR: Deployment failed. Migration canceled."
  exit 1
}

log "INFO: Deployment completed. Checking if restore is needed..."
postgresql_version_after=$($SSH_SERVER "psql --version" | awk '{print $3}' || {
  log "ERROR: Could not retrieve PostgreSQL version after deploy. Exiting."
  exit 1
})

if [[ "$(echo -e "$postgresql_version_before\n$postgresql_version_after" | sort -V | head -n1)" == "$postgresql_version_before"  && "$postgresql_version_before" != "$postgresql_version_after" ]]; then
  log "INFO: PostgreSQL version upgraded from $postgresql_version_before to $postgresql_version_after."
  perform_migration
else
  log "INFO: PostgreSQL version remains unchanged or downgraded ($postgresql_version_before → $postgresql_version_after). No migration required."
fi
