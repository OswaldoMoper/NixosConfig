#!/usr/bin/env zsh
set -e

TARGET_USER=${SUDO_USER:-$USER}

USER_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)

if [ -z "$USER_HOME" ] || [ ! -d "$USER_HOME" ]; then
    echo "ERROR: No se pudo determinar un directorio HOME válido para $TARGET_USER"
    exit 1
fi

log() {
  echo "[$(date)] - $1" | tee -a "$USER_HOME/postgres_migration.log"
}
perform_migration() {
  log "INFO: Starting PostgreSQL restore..."

  if [ -s $USER_HOME/backups/postgres_backup.sql ]; then
    log "INFO: Restoring PostgreSQL database..."
    if ! grep -q "PostgreSQL database dump" "$USER_HOME/backups/postgres_backup.sql"; then
        log "ERROR: Backup file appears to be invalid or corrupted. Aborting migration."
        exit 1
    else
      psql -U postgres < $USER_HOME/backups/postgres_backup.sql || {
        log "ERROR: Restore failed. Aborting migration."
        exit 1
      }
    fi
  else
    log "ERROR: Backup file is empty or missing ($USER_HOME/backups/postgres_backup.sql). Aborting migration."
    exit 1
  fi

  log "INFO: Restore completed..."
  rm -f $USER_HOME/backups/postgres_backup.sql
  psql -U analyzer -d aanalyzer_yesod -c '\dt'
  log "INFO: PostgreSQL migration script executed. Backup directory: $USER_HOME/postgres_backup_local.sql"
}

postgresql_version_before=$(psql --version | awk '{print $3}' || {
  log "ERROR: Could not retrieve PostgreSQL version before nixos-rebuild. Exiting."
  exit 1
})

log "INFO: PostgreSQL version before nixos-rebuild: $postgresql_version_before. Backing up PostgreSQL..."
mkdir -p $USER_HOME/backups && pg_dumpall -U postgres > $USER_HOME/backups/postgres_backup.sql || {
  log "ERROR: Backup failed. Aborting nixos-rebuild."
  exit 1
}

log "INFO: Backup completed. Copying backup locally..."
cp $USER_HOME/backups/postgres_backup.sql $USER_HOME/postgres_backup_local.sql || {
  log "ERROR: Backup copy failed. Aborting nixos-rebuild."
  exit 1
}

log "INFO: Backup copied in $USER_HOME/postgres_backup_local.sql. Running nixos-rebuild..."
nixos-rebuild "$@" || {
  log "ERROR: Could not execute nixos-rebuild. Aborting migration. See nix logs for details."
  exit 1
}

log "INFO: Rebuild completed. Initializing Zsh..."
if [ ! -f "$USER_HOME"/.zshrc ]; then
  touch "$USER_HOME"/.zshrc
fi

if ! systemctl is-active postgresql > /dev/null 2>&1; then
    log "WARN: PostgreSQL service is not running after nixos-rebuild. Attempting restart..."
    systemctl restart postgresql || {
        log "ERROR: Unable to restart PostgreSQL. Manual intervention may be required."
        exit 1
    }
fi

log "INFO: Zsh has been initialized successfully. Checking if restore is needed..."
postgresql_version_after=$(psql --version | awk '{print $3}' || {
  log "ERROR: Could not retrieve PostgreSQL version after nixos-rebuild. Exiting."
  exit 1
})

if [[ "$(echo -e "$postgresql_version_before\n$postgresql_version_after" | sort -V | head -n1)" == "$postgresql_version_before"  && "$postgresql_version_before" != "$postgresql_version_after" ]]; then
  log "INFO: PostgreSQL version upgraded from $postgresql_version_before to $postgresql_version_after."
  perform_migration
  if ! psql -U postgres -c "SELECT 1;" > /dev/null 2>&1; then
      log "ERROR: PostgreSQL might not be running correctly after restoration. Consider manual verification."
  fi
else
  log "INFO: PostgreSQL version remains unchanged or downgraded ($postgresql_version_before → $postgresql_version_after). No migration required."
fi
