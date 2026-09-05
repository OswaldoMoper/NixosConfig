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
nix flake check "$GATE_FLAKE" || {
  printf 'pure checks failed; nothing was deployed\n' >&2
  exit 1
}

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

step "7/8 deploy"
# The exit code is recorded, not obeyed. Measured on 2026-08-25: a per-user
# activation warning for an account this deploy had just removed made deploy-rs
# report failure and attempt a revoke, while the machine finished activating and
# came up clean. Aborting here left the operator believing a successful deploy
# had failed, with step 8 never run.
deploy_rc=0
deploy "${GATE_FLAKE}#${GATE_NODE}" "$@" || deploy_rc=$?

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

if [ "$deploy_rc" -ne 0 ]; then
  printf '\ndeploy exited %s, but the host runs the closure we built and verifies\n' "$deploy_rc" >&2
  printf 'clean. Read the activation log for a per-user warning before believing\n' >&2
  printf 'the exit code -- see HALLAZGOS on the 2026-07-07 rollback.\n' >&2
fi

printf '\ndeploy gate passed for %s\n' "$GATE_NODE"
