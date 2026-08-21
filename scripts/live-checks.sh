node="${LIVE_NODE}"
mode="${LIVE_MODE}"
remote="${LIVE_SSH_USER}@${LIVE_HOST}"
fail=0

ok() { printf '  ok    %s\n' "$1"; }
bad() {
  printf '  FAIL  %s\n' "$1" >&2
  fail=1
}

# Client-side expansion of the remote command is the point here, so SC2029 is
# excluded where this script is packaged.
sshq() { ssh -o BatchMode=yes -o ConnectTimeout=10 "$remote" "$@"; }

psql_value() {
  sshq "sudo -u postgres psql -tAc $1 ${2:-}" 2>/dev/null | tr -d '[:space:]' || true
}

printf '%s checks: %s (%s)\n' "$mode" "$node" "$remote"

# BatchMode keeps a missing key from turning this into a password prompt that
# hangs a pipeline. fail2ban answers a ban with reject, so a ban and a dead host
# look identical from here.
if ! sshq true 2>/dev/null; then
  printf 'cannot reach %s over ssh (BatchMode, 10s timeout)\n' "$remote" >&2
  printf 'a ban and a dead host look the same here: check from another address\n' >&2
  exit 1
fi
ok "ssh reachable"

# Preconditions: true of the machine as it stands, before anything is deployed.
if [ "$mode" = "pre-deploy" ] && [ -n "${LIVE_PG_MAJOR:-}" ]; then
  num="$(psql_value "'SHOW server_version_num'")"
  if ! printf '%s' "$num" | grep -qE '^[0-9]+$'; then
    bad "could not read server_version_num (got '${num}')"
  else
    # server_version_num is major*10000 + minor, so this is the server's major.
    # psql --version would report the client's, which is a different number.
    live=$((num / 10000))
    if [ "$live" = "$LIVE_PG_MAJOR" ]; then
      ok "postgres major ${live} matches the pin"
    else
      # Which way a mismatch hurts depends on what is already in the pinned data
      # dir, so say which case this is instead of guessing the scary one.
      target="$(sshq "sudo -u postgres cat ${LIVE_DATA_DIR}/PG_VERSION 2>/dev/null" | tr -d '[:space:]' || true)"
      if [ "$target" = "$LIVE_PG_MAJOR" ]; then
        bad "postgres major is ${live} but the config pins ${LIVE_PG_MAJOR}, and ${LIVE_DATA_DIR} already holds a version ${target} cluster: deploying switches to that one and orphans whatever the live ${live} cluster holds"
      else
        bad "postgres major is ${live} but the config pins ${LIVE_PG_MAJOR}, and ${LIVE_DATA_DIR} holds no cluster: deploying would start an empty one. Use deploy-migration, which dumps first"
      fi
    fi
  fi

  # Through postgres, not the login user: the data dir is 0700 and its owner is
  # the one account guaranteed to be able to stat it.
  if sshq "sudo -u postgres test -d ${LIVE_DATA_DIR}"; then
    ok "data dir ${LIVE_DATA_DIR} exists"
  else
    bad "data dir ${LIVE_DATA_DIR} is missing"
  fi
fi

# Postconditions: only true once a deploy has succeeded, so asserting them
# before one would block the very deploy meant to create them.
if [ "$mode" = "verify" ]; then
  units=()
  if [ -n "${LIVE_UNITS:-}" ]; then read -ra units <<<"$LIVE_UNITS"; fi
  for u in ${units[@]+"${units[@]}"}; do
    if sshq "systemctl is-active --quiet ${u}"; then
      ok "unit ${u} is active"
    else
      bad "unit ${u} is not active"
    fi
  done

  dbs=()
  if [ -n "${LIVE_DATABASES:-}" ]; then read -ra dbs <<<"$LIVE_DATABASES"; fi
  for db in ${dbs[@]+"${dbs[@]}"}; do
    if [ "$(psql_value "\"SELECT 1 FROM pg_database WHERE datname='${db}'\"")" != "1" ]; then
      bad "database ${db} does not exist"
      continue
    fi
    tables="$(psql_value "\"SELECT count(*) FROM information_schema.tables WHERE table_schema='public'\"" "${db}")"
    if [ "${tables:-0}" -gt 0 ]; then
      ok "database ${db} has ${tables} tables in public"
    else
      bad "database ${db} exists but public is empty"
    fi
  done
fi

if [ "$fail" -ne 0 ]; then
  printf '\n%s checks FAILED for %s\n' "$mode" "$node" >&2
  exit 1
fi
printf '\n%s checks passed for %s\n' "$mode" "$node"
