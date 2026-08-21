node="${PRE_DEPLOY_NODE}"
remote="${PRE_DEPLOY_SSH_USER}@${PRE_DEPLOY_HOST}"
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

printf 'pre-deploy live checks: %s (%s)\n' "$node" "$remote"

# BatchMode keeps a missing key from turning this into a password prompt that
# hangs a pipeline; fail2ban answers a ban with reject, so this also reads as
# "Connection refused" when the client is banned rather than the host being down.
if ! sshq true 2>/dev/null; then
  printf 'cannot reach %s over ssh (BatchMode, 10s timeout)\n' "$remote" >&2
  printf 'a ban and a dead host look the same here: check from another address\n' >&2
  exit 1
fi
ok "ssh reachable"

if [ -n "${PRE_DEPLOY_PG_MAJOR:-}" ]; then
  num="$(psql_value "'SHOW server_version_num'")"
  if ! printf '%s' "$num" | grep -qE '^[0-9]+$'; then
    bad "could not read server_version_num (got '${num}')"
  else
    # server_version_num is major*10000 + minor, so this is the server's major,
    # not the client's -- psql --version would report the wrong one.
    live=$((num / 10000))
    if [ "$live" = "$PRE_DEPLOY_PG_MAJOR" ]; then
      ok "postgres major ${live} matches the pin"
    else
      bad "postgres major is ${live} but the config pins ${PRE_DEPLOY_PG_MAJOR}: deploying would start an empty cluster and leave the data in ${PRE_DEPLOY_DATA_DIR}"
    fi
  fi

  # Through postgres, not the login user: the data dir is 0700 and its owner is
  # the one account guaranteed to be able to stat it.
  if sshq "sudo -u postgres test -d ${PRE_DEPLOY_DATA_DIR}"; then
    ok "data dir ${PRE_DEPLOY_DATA_DIR} exists"
  else
    bad "data dir ${PRE_DEPLOY_DATA_DIR} is missing"
  fi
fi

units=()
if [ -n "${PRE_DEPLOY_UNITS:-}" ]; then read -ra units <<<"$PRE_DEPLOY_UNITS"; fi
for u in ${units[@]+"${units[@]}"}; do
  if sshq "systemctl is-active --quiet ${u}"; then
    ok "unit ${u} is active"
  else
    bad "unit ${u} is not active"
  fi
done

dbs=()
if [ -n "${PRE_DEPLOY_DATABASES:-}" ]; then read -ra dbs <<<"$PRE_DEPLOY_DATABASES"; fi
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

if [ "$fail" -ne 0 ]; then
  printf '\npre-deploy live checks FAILED for %s\n' "$node" >&2
  exit 1
fi
printf '\npre-deploy live checks passed for %s\n' "$node"
