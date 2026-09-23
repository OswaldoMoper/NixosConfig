step() { printf '\n=== %s\n' "$1"; }

printf 'deploy gate for %s (flake %s)\n' "$GATE_NODE" "$GATE_FLAKE"

# The node's declared sshUser is root or admin, and neither belongs to whoever
# is deploying today. One name has to reach the guards and deploy alike, or the
# live preconditions fail as themselves before the deploy is even attempted.
if [ -n "${GATE_SSH_USER:-}" ]; then
  export LIVE_SSH_USER="$GATE_SSH_USER"
  export ACCESS_SSH_USER="$GATE_SSH_USER"
  set -- --ssh-user "$GATE_SSH_USER" "$@"
fi

# Same fan-out for the config file, and for the same reason: the guards run
# their own ssh, so a path only deploy-rs knows about leaves them failing as if
# the host were unreachable. First in the argument list, so an explicit
# --ssh-opts from the caller still wins.
ssh_cfg=()
if [ -n "${GATE_SSH_CONFIG:-}" ]; then
  export LIVE_SSH_CONFIG="$GATE_SSH_CONFIG"
  export ACCESS_SSH_CONFIG="$GATE_SSH_CONFIG"
  ssh_cfg=(-F "$GATE_SSH_CONFIG")
  set -- --ssh-opts "-F $GATE_SSH_CONFIG" "$@"
fi

gate_ssh() {
  ssh ${ssh_cfg[@]+"${ssh_cfg[@]}"} -o BatchMode=yes -o ConnectTimeout=10 \
    "${GATE_HOST_USER}@${GATE_HOST_ADDR}" "$@"
}

# server_version_num is major*10000 + minor. psql --version reports the client's,
# which is a different number and the original bug in the migration scripts.
# Empty output rather than a number means the question could not be asked.
remote_major() {
  local num
  num="$(gate_ssh "sudo -u postgres psql -tAc 'SHOW server_version_num'" 2>/dev/null | tr -d '[:space:]')"
  case "$num" in
    '' | *[!0-9]*) return 0 ;;
    *) printf '%s' "$((num / 10000))" ;;
  esac
}

GATE_DUMP_DIR="${GATE_DUMP_DIR:-/var/tmp}"
GATE_DUMP_LOCAL="${GATE_DUMP_LOCAL:-${HOME}/postgres_backup_${GATE_NODE}.sql}"

step "1/8 is this checkout current"
# First because it is the cheapest and because every later step inherits its
# answer: a stale tree's own checks are stale too.
#
# Findings warn and never block. Exit 2 is not a finding, it means the remote
# could not be asked -- and "I did not look" must not read as "nothing to
# report", which is the whole lesson of the access guard.
fresh_rc=0
"$GATE_FRESH" || fresh_rc=$?
if [ "$fresh_rc" -eq 2 ]; then
  printf '\nnothing was deployed\n' >&2
  exit 1
fi

step "2/8 binary caches on this machine"
# Only a human answering "abort" makes this stop.
"$GATE_CACHES" || {
  printf '\nnothing was deployed\n' >&2
  exit 1
}

step "3/8 pure checks"
# Empty GATE_CHECKS means every check in the flake, which is right while they
# all speak for every host. A node that names its own gets those and no more:
# a flake with per-environment application checks would otherwise build
# websites for environments this host has nothing to do with, and a gate that
# does the wrong work is a gate people learn to skip.
if [ -n "${GATE_CHECKS:-}" ]; then
  read -r -a gate_checks <<< "$GATE_CHECKS"
  attrs=()
  for c in "${gate_checks[@]}"; do
    attrs+=("${GATE_FLAKE}#checks.${GATE_SYSTEM:-x86_64-linux}.${c}")
  done
  printf 'checks this node names: %s\n' "$GATE_CHECKS"
  nix build --no-link "${attrs[@]}" || {
    printf 'pure checks failed; nothing was deployed\n' >&2
    exit 1
  }
else
  nix flake check "$GATE_FLAKE" || {
    printf 'pure checks failed; nothing was deployed\n' >&2
    exit 1
  }
fi

step "4/8 live preconditions"
# The gate has to be overridable or it gets bypassed by hand, which is worse:
# the recovery deploy for a host whose Postgres major moved is exactly the case
# where a human has to look and decide.
if [ "${GATE_SKIP_PREFLIGHT:-0}" = "1" ]; then
  printf 'SKIPPED because GATE_SKIP_PREFLIGHT=1\n' >&2
  printf 'you are deploying without checking the machine first\n' >&2
else
  "$GATE_PRE_DEPLOY" || {
    printf '\nlive preconditions failed; nothing was deployed\n' >&2
    printf 'if this is deliberate, re-run with GATE_SKIP_PREFLIGHT=1\n' >&2
    exit 1
  }
fi

step "5/8 build the toplevel"
# Building here rather than letting deploy do it keeps an evaluation error from
# reaching the machine at all. --print-out-paths because the next step needs the
# closure to compare against the live host.
built="$(nix build --no-link --print-out-paths \
  "${GATE_FLAKE}#nixosConfigurations.${GATE_HOST}.config.system.build.toplevel")" || {
  printf 'build failed; nothing was deployed\n' >&2
  exit 1
}

step "6/8 ssh access this deploy would remove"
# A finding warns and never blocks: a deliberate revocation should not need a
# flag, and this must never be the reason an urgent deploy cannot go out.
#
# Exit 2 is not a finding, it means the guard never looked -- and a check that
# silently does not run is the thing it exists to prevent.
access_rc=0
"$GATE_ACCESS" "$built" || access_rc=$?
if [ "$access_rc" -eq 2 ]; then
  printf '\nnothing was deployed\n' >&2
  exit 1
fi

# A major bump orphans the old data directory, so the dump goes between the
# last check and the deploy: late enough that nothing else can abort after it,
# early enough that the machine is still serving the old cluster.
#
# It lives here rather than in a script of its own because a parallel path ran
# none of the six steps above, and drifted.
migrate_before=""
if [ "${GATE_MIGRATE:-0}" = "1" ]; then
  step "6b/8 dump before migrating"
  migrate_before="$(remote_major)"
  if [ -z "$migrate_before" ]; then
    printf 'could not read the remote postgres version; nothing was deployed\n' >&2
    exit 1
  fi
  printf '  server_version_num before: %s\n' "$migrate_before"

  gate_ssh "mkdir -p ${GATE_DUMP_DIR} && sudo -u postgres pg_dumpall > ${GATE_DUMP_DIR}/${GATE_NODE}.sql" || {
    printf 'remote dump failed; nothing was deployed\n' >&2
    exit 1
  }
  # Off the box before the deploy, because a dump that only exists on the
  # machine being changed is not a backup.
  scp ${ssh_cfg[@]+"${ssh_cfg[@]}"} -q \
    "${GATE_HOST_USER}@${GATE_HOST_ADDR}:${GATE_DUMP_DIR}/${GATE_NODE}.sql" "$GATE_DUMP_LOCAL" || {
    printf 'could not download the dump; nothing was deployed\n' >&2
    exit 1
  }
  if ! grep -q 'PostgreSQL database dump' "$GATE_DUMP_LOCAL"; then
    printf '%s does not look like pg_dumpall output; nothing was deployed\n' "$GATE_DUMP_LOCAL" >&2
    exit 1
  fi
  printf '  dumped to %s (%s bytes)\n' "$GATE_DUMP_LOCAL" "$(wc -c < "$GATE_DUMP_LOCAL")"
fi

census_before=""
if [ -n "${GATE_CENSUS:-}" ]; then
  step "6c/8 what the machine holds now"
  census_before="$(mktemp)"
  "$GATE_CENSUS" > "$census_before" || {
    printf 'could not take a census; nothing was deployed\n' >&2
    exit 1
  }
  printf '  %s thing(s) counted\n' "$(grep -cE '^(table|rows|files) ' "$census_before" || true)"
fi

# Last, so nothing can abort after it: a copy is only worth taking if the thing
# it protects against is the next step.
if [ -n "${GATE_BACKUP_BIN:-}" ]; then
  step "6d/8 back up before touching anything"
  "$GATE_BACKUP_BIN" --once "$GATE_BACKUP_APP" "$GATE_BACKUP_CONFIG" || {
    printf 'the backup did not complete; nothing was deployed\n' >&2
    printf 'if this is deliberate, say so out loud rather than here\n' >&2
    exit 1
  }
fi

step "7/8 deploy"
# The exit code is recorded, not obeyed. Measured on 2026-08-25: a per-user
# activation warning for an account this deploy had just removed made deploy-rs
# report failure and attempt a revoke, while the machine finished activating and
# came up clean. Aborting here left the operator believing a successful deploy
# had failed, with step 8 never run.
#
# --skip-checks because step 3 IS the checks step. Without it deploy-rs runs
# `nix flake check` on the whole flake again, which costs twice and can fail
# for a reason that has nothing to do with this host: a full-flake check
# evaluates every OTHER host too, so one whose input the caller cannot fetch
# blocks a deploy it is unrelated to. A node that names its checks is saying
# which ones concern it, and this is what makes that mean something.
deploy_rc=0
deploy --skip-checks "${GATE_FLAKE}#${GATE_NODE}" "$@" || deploy_rc=$?

if [ "${GATE_MIGRATE:-0}" = "1" ]; then
  step "7b/8 restore if the major moved"
  migrate_after="$(remote_major)"
  if [ -z "$migrate_after" ]; then
    printf 'could not read the remote postgres version after the deploy\n' >&2
    printf 'the dump is at %s; nothing was restored\n' "$GATE_DUMP_LOCAL" >&2
    exit 1
  fi
  if [ "$migrate_after" -le "$migrate_before" ]; then
    printf '  %s -> %s: unchanged or lower, nothing to restore\n' "$migrate_before" "$migrate_after"
    gate_ssh "rm -f ${GATE_DUMP_DIR}/${GATE_NODE}.sql" || true
  else
    printf '  %s -> %s: restoring into the fresh cluster\n' "$migrate_before" "$migrate_after"
    gate_ssh "cat ${GATE_DUMP_DIR}/${GATE_NODE}.sql | sudo -u postgres psql postgres" || {
      printf 'restore failed. The dump is at %s\n' "$GATE_DUMP_LOCAL" >&2
      exit 1
    }
    gate_ssh "rm -f ${GATE_DUMP_DIR}/${GATE_NODE}.sql" || true
  fi
  printf '  local copy kept at %s\n' "$GATE_DUMP_LOCAL"
fi

step "8/8 verify the result"
# The machine is the authority. Two questions, in order: is it running the exact
# closure we built, and does it work? The first is what tells a false alarm apart
# from a real rollback -- verify alone cannot, because the previous generation
# also has its units up.
live="$(gate_ssh readlink -f /run/current-system 2>/dev/null || true)"

if [ "$live" != "$built" ]; then
  printf '\nthe host is NOT running what we built\n' >&2
  printf '  built: %s\n' "$built" >&2
  printf '  live:  %s\n' "${live:-<unreachable>}" >&2
  [ "$deploy_rc" -eq 0 ] || printf '  deploy exited %s\n' "$deploy_rc" >&2
  exit 1
fi

if ! "$GATE_VERIFY"; then
  printf '\nthe host runs the new closure but does not verify clean\n' >&2
  exit 1
fi

if [ -n "$census_before" ]; then
  step "8b/8 account for what the deploy removed"
  census_after="$(mktemp)"
  tables_of() { grep '^table ' "$1" | cut -d' ' -f3 | sort; }

  # Compares census_before with census_after and leaves the verdict in four
  # variables: unaccounted (names lost that GATE_SHRINK_OK does not excuse),
  # lost_db and lost_files (the same names split by where they live), and
  # db_new (1 when every counted table that had rows now has none -- a
  # database that came back new rather than behind).
  account() {
    local gone shrank name bare kind what n_before n_after watched=0
    gone="$(comm -23 <(tables_of "$census_before") <(tables_of "$census_after") || true)"
    shrank=""
    db_new=1
    while read -r kind what n_before; do
      case "$kind" in rows|files) ;; *) continue ;; esac
      n_after="$(grep -E "^${kind} ${what} " "$census_after" | cut -d' ' -f3 || true)"
      # Either side unreadable means the question was not answered, which is not
      # the same answer as "fewer", and must not be reported as one.
      case "$n_before" in ''|*[!0-9]*) continue ;; esac
      case "$n_after"  in ''|*[!0-9]*) printf '  could not count %s after the deploy\n' "$what"; db_new=0; continue ;; esac
      if [ "$kind" = rows ] && [ "$n_before" -gt 0 ]; then
        watched=1
        [ "$n_after" -eq 0 ] || db_new=0
      fi
      if [ "$n_after" -lt "$n_before" ]; then
        shrank="$shrank ${kind}:${what}($n_before->$n_after)"
      fi
    done < <(grep -E '^(rows|files) ' "$census_before" || true)
    [ "$watched" = 1 ] || db_new=0

    local lost=""
    for name in $gone; do lost="$lost table:$name"; done
    unaccounted=""; lost_db=""; lost_files=""
    for name in $lost $shrank; do
      bare="${name#*:}"; bare="${bare%%(*}"
      case " ${GATE_SHRINK_OK:-} " in *" $bare "*) continue ;; esac
      unaccounted="$unaccounted $bare"
      case "$name" in files:*) lost_files="$lost_files $bare" ;; *) lost_db="$lost_db $bare" ;; esac
    done
  }

  # A migration runs as the application starts, so the first look can catch a
  # schema halfway through one. Only worth a second look when something is
  # missing, which is the answer that would stop the gate.
  "$GATE_CENSUS" > "$census_after" || true
  account
  if [ -n "$unaccounted" ]; then
    sleep 10
    "$GATE_CENSUS" > "$census_after" || true
    account
  fi

  appeared="$(comm -13 <(tables_of "$census_before") <(tables_of "$census_after") || true)"
  [ -n "$appeared" ] && printf '  new: %s\n' "$(echo "$appeared" | tr '\n' ' ')"

  restore=()
  [ -z "${GATE_BACKUP_BIN:-}" ] || restore=("$GATE_BACKUP_BIN" --restore "$GATE_BACKUP_APP")
  empty_tables="$(printf '%s' "${GATE_CENSUS_ROWS:-}" | tr ' ' ',')"

  # Only what cannot lose anything goes back on its own: a database that came
  # back new, and uploads the machine no longer has. A database that is behind
  # stops the gate, because replacing it would lose whatever was written after
  # the copy.
  if [ ${#restore[@]} -gt 0 ] && { { [ -n "$lost_db" ] && [ "$db_new" = 1 ]; } || [ -n "$lost_files" ]; }; then
    step "8c/8 put back what the backup in 6d still has"
    restored=0
    if [ -n "$lost_db" ] && [ "$db_new" = 1 ] && [ -n "$empty_tables" ]; then
      printf '  the database came back new (%s at zero), restoring it\n' "$empty_tables"
      gate_ssh "sudo systemctl stop ${GATE_APP_UNITS:-}" || {
        printf 'could not stop %s; nothing was restored\n' "${GATE_APP_UNITS:-}" >&2
        exit 1
      }
      db_rc=0
      "${restore[@]}" --database --empty "$empty_tables" "$GATE_BACKUP_CONFIG" || db_rc=$?
      gate_ssh "sudo systemctl start ${GATE_APP_UNITS:-}" || printf '  could not start %s again\n' "${GATE_APP_UNITS:-}" >&2
      [ "$db_rc" -eq 0 ] && restored=1
    fi
    if [ -n "$lost_files" ]; then
      printf '  uploads went missing, putting back the ones the machine lacks\n'
      "${restore[@]}" --uploads "$GATE_BACKUP_CONFIG" && restored=1
    fi
    if [ "$restored" = 1 ]; then
      sleep 10
      "$GATE_CENSUS" > "$census_after" || true
      account
    fi
  fi
  rm -f "$census_before" "$census_after"

  if [ -n "$unaccounted" ]; then
    printf '\nthe deploy removed things nobody said it would:%s\n' "$unaccounted" >&2
    if [ ${#restore[@]} -gt 0 ]; then
      printf 'the backup taken in step 6d still has them.\n' >&2
      if [ -n "$lost_db" ] && [ "$db_new" = 1 ]; then
        printf 'the database came back new, but putting it back did not complete. With the\n' >&2
        printf 'applications stopped (%s), this tries again:\n' "${GATE_APP_UNITS:-}" >&2
        printf '  %s --database --empty %s %s\n' "${restore[*]}" "$empty_tables" "$GATE_BACKUP_CONFIG" >&2
      elif [ -n "$lost_db" ]; then
        printf 'the database is behind rather than new, so it was not replaced: that loses\n' >&2
        printf 'what was written after the copy, and only whoever deploys can decide it. With\n' >&2
        printf 'the applications stopped (%s), this replaces it with the copy:\n' "${GATE_APP_UNITS:-}" >&2
        printf '  %s --database --replace %s\n' "${restore[*]}" "$GATE_BACKUP_CONFIG" >&2
      fi
      if [ -n "$lost_files" ]; then
        printf 'uploads still missing; this puts back the ones the machine lacks:\n' >&2
        printf '  %s --uploads %s\n' "${restore[*]}" "$GATE_BACKUP_CONFIG" >&2
      fi
    fi
    printf 'if this was meant -- two tables merged into one, say -- name them in\n' >&2
    printf 'GATE_SHRINK_OK and run again; the names are what tells a merge from a loss.\n' >&2
    exit 1
  fi
  printf '  nothing disappeared that was not accounted for\n'
fi

if [ "$deploy_rc" -ne 0 ]; then
  printf '\ndeploy exited %s, but the host runs the closure we built and verifies\n' "$deploy_rc" >&2
  printf 'clean. Read the activation log before believing the exit code: a single\n' >&2
  printf 'per-user warning is enough to make deploy-rs report a finished\n' >&2
  printf 'activation as failed.\n' >&2
fi

printf '\ndeploy gate passed for %s\n' "$GATE_NODE"
