node="${LIVE_NODE}"
mode="${LIVE_MODE}"
remote="${LIVE_SSH_USER}@${LIVE_HOST}"
fail=0

ok() { printf '  ok    %s\n' "$1"; }
bad() {
  printf '  FAIL  %s\n' "$1" >&2
  fail=1
}
# Says something is wrong without stopping the deploy. For things that are real
# but that a deploy cannot fix and a human has to schedule -- blocking every
# future deploy on one of those helps nobody.
warn() { printf '  WARN  %s\n' "$1" >&2; }

# A census writes data to stdout for something else to parse, so its prose
# goes to stderr instead. Otherwise the reader counts the prose as findings.
if [ "$mode" = "census" ]; then
  ok() { printf '  ok    %s\n' "$1" >&2; }
fi

# Client-side expansion of the remote command is the point here, so SC2029 is
# excluded where this script is packaged.
#
# An explicit config path, because OpenSSH reads its default ~/.ssh from the
# account's home in passwd, and a CI runner's is /var/empty however the job's
# HOME is set. Empty everywhere else, which is the interactive case.
ssh_cfg=()
if [ -n "${LIVE_SSH_CONFIG:-}" ]; then
  ssh_cfg=(-F "$LIVE_SSH_CONFIG")
fi

# Every remote question goes through here, which is what lets the same checks
# answer for the machine you are standing on. ssh joins its arguments into one
# shell command, so `sh -c "$*"` is the same command, run by the same shell.
sshq() {
  if [ "${LIVE_LOCAL:-0}" = "1" ]; then
    sh -c "$*"
  else
    ssh ${ssh_cfg[@]+"${ssh_cfg[@]}"} \
      -o BatchMode=yes -o ConnectTimeout=10 "$remote" "$@"
  fi
}

psql_value() {
  sshq "sudo -u postgres psql -tAc $1 ${2:-}" 2>/dev/null | tr -d '[:space:]' || true
}

if [ "$mode" = "census" ]; then
  printf '%s checks: %s (%s)\n' "$mode" "$node" "$remote" >&2
else
  printf '%s checks: %s (%s)\n' "$mode" "$node" "$remote"
fi

# BatchMode keeps a missing key from turning this into a password prompt that
# hangs a pipeline. It also means a passphrase-locked key with no agent loaded
# fails here while working perfectly interactively -- which looks nothing like
# the problem it is, so name that case rather than blaming the network.
#
# fail2ban answers a ban with reject, so a ban and a dead host do look identical
# from here. An authentication failure does not.
if [ "${LIVE_LOCAL:-0}" = "1" ]; then
  ok "running on the machine itself"
elif ! ssh_err="$(sshq true 2>&1 >/dev/null)"; then
  case "$ssh_err" in
    *"Permission denied"* | *"No supported authentication"*)
      printf 'reached %s, but could not authenticate without a prompt\n' "$remote" >&2
      printf 'BatchMode is on here, so a passphrase-locked key needs an agent:\n' >&2
      # shellcheck disable=SC2016  # the $( ) is text being shown, not run
      printf '  eval "$(ssh-agent -s)" && ssh-add\n' >&2
      ;;
    *)
      printf 'cannot reach %s over ssh (BatchMode, 10s timeout)\n' "$remote" >&2
      printf 'a ban and a dead host look the same here: check from another address\n' >&2
      ;;
  esac
  exit 1
else
  ok "ssh reachable"
fi

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
        bad "postgres major is ${live} but the config pins ${LIVE_PG_MAJOR}, and ${LIVE_DATA_DIR} holds no cluster: deploying would start an empty one. Re-run with GATE_MIGRATE=1, which dumps first"
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

# Both names existing is the one state postgresql.renames refuses to resolve,
# and it refuses it halfway through an activation. Asking here costs two
# queries and moves that discovery to before anything has been touched.
if [ "$mode" = "pre-deploy" ] && [ -n "${LIVE_RENAMES:-}" ]; then
  read -ra renames <<<"$LIVE_RENAMES"
  # A server that is not answering says "no such database" to everything, which
  # here would read as "nothing to rename" -- the one answer that needs no
  # attention. Establish it is answering before believing any of them.
  if [ "$(psql_value "'SELECT 1'")" != "1" ]; then
    bad "postgres is not answering, so nothing here can say which databases the rename would find"
  else
    for pair in "${renames[@]}"; do
      from="${pair%%=*}"
      to="${pair#*=}"
      has_from="$(psql_value "\"SELECT 1 FROM pg_database WHERE datname='${from}'\"")"
      has_to="$(psql_value "\"SELECT 1 FROM pg_database WHERE datname='${to}'\"")"
      if [ "$has_from" = "1" ] && [ "$has_to" = "1" ]; then
        bad "both ${from} and ${to} exist, so the rename cannot tell which holds the data: settle it by hand before deploying"
      elif [ "$has_from" = "1" ]; then
        ok "${from} is there and will be renamed to ${to}"
      elif [ "$has_to" = "1" ]; then
        ok "${to} is already renamed"
      else
        warn "neither ${from} nor ${to} exists, so the rename will do nothing and ${to} will be created empty"
      fi
    done
  fi
fi

# A census is neither a precondition nor a postcondition: it is what the
# machine looked like, printed for something else to compare. It asserts
# nothing, so it never fails.
if [ "$mode" = "census" ]; then
  dbs=()
  if [ -n "${LIVE_DATABASES:-}" ]; then read -ra dbs <<<"$LIVE_DATABASES"; fi
  first_db="${dbs[0]:-}"
  for db in ${dbs[@]+"${dbs[@]}"}; do
    names="$(sshq "sudo -u postgres psql -tAc \"SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename\" ${db}" 2>/dev/null || true)"
    for t in $names; do printf 'table %s %s\n' "$db" "$t"; done
  done

  rows=()
  if [ -n "${LIVE_CENSUS_ROWS:-}" ]; then read -ra rows <<<"$LIVE_CENSUS_ROWS"; fi
  for t in ${rows[@]+"${rows[@]}"}; do
    n="$(psql_value "'SELECT count(*) FROM ${t}'" "${first_db}")"
    printf 'rows %s %s\n' "$t" "${n:-unknown}"
  done

  dirs=()
  if [ -n "${LIVE_CENSUS_FILES:-}" ]; then read -ra dirs <<<"$LIVE_CENSUS_FILES"; fi
  for d in ${dirs[@]+"${dirs[@]}"}; do
    n="$(sshq "ls -A ${d} 2>/dev/null | wc -l" 2>/dev/null | tr -d '[:space:]' || true)"
    printf 'files %s %s\n' "$d" "${n:-unknown}"
  done
  exit 0
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

    # A nixpkgs bump moves glibc, and with it the collation rules. Text indexes
    # built under the old rules can then miss rows that are really there --
    # wrong answers, quietly, with every unit still green. Found on server
    # after the 25.11 -> 26.05 jump, and only on data that predates it, which is
    # why a VM rehearsal cannot catch it.
    built="$(psql_value "\"SELECT datcollversion FROM pg_database WHERE datname='${db}'\"")"
    now="$(psql_value "\"SELECT pg_database_collation_actual_version(oid) FROM pg_database WHERE datname='${db}'\"")"
    if [ -n "$built" ] && [ -n "$now" ] && [ "$built" != "$now" ]; then
      warn "database ${db} was built with collation ${built} and the OS now provides ${now}: text indexes may miss rows"
      warn "  fix, in a quiet window: REINDEX DATABASE CONCURRENTLY ${db}; then ALTER DATABASE ${db} REFRESH COLLATION VERSION"
    fi
  done

  pairs=()
  if [ -n "${LIVE_DB_OWNERS:-}" ]; then read -ra pairs <<<"$LIVE_DB_OWNERS"; fi
  for pair in ${pairs[@]+"${pairs[@]}"}; do
    db="${pair%%=*}"
    role="${pair#*=}"
    if [ "$(psql_value "\"SELECT 1 FROM pg_roles WHERE rolname='${role}'\"")" != "1" ]; then
      bad "role ${role} does not exist, so ${db} has nobody to connect as"
      continue
    fi
    owner="$(psql_value "\"SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname='${db}'\"")"
    if [ "$owner" = "$role" ]; then
      ok "role ${role} exists and owns ${db}"
    else
      bad "database ${db} is owned by ${owner:-nobody}, expected ${role}"
    fi
  done
fi

# A pending reboot, and only the part of it a reboot actually applies.
#
# Comparing /run/booted-system against /run/current-system is the obvious
# check and it is the wrong one: those two differ after EVERY activation, so
# it would warn every time and be learned away. What a reboot applies and an
# activation cannot is the kernel, its initrd and its modules, so those are
# what get compared.
#
# This is a warn: the deploy is not what fixes it, and a human has to pick the
# moment.
pending=""
compared=0
for part in kernel initrd kernel-modules; do
  booted="$(sshq "readlink -f /run/booted-system/${part} 2>/dev/null" || true)"
  current="$(sshq "readlink -f /run/current-system/${part} 2>/dev/null" || true)"
  [ -n "$booted" ] && [ -n "$current" ] || continue
  compared=$((compared + 1))
  if [ "$booted" != "$current" ]; then
    pending="${pending}${pending:+, }${part}"
  fi
done
# Counting what was compared, because otherwise a host that exposes none of
# these paths reports the same "ok" as one that matches, and a check that says
# ok when it could not look is worse than no check.
if [ -n "$pending" ]; then
  warn "this host is running an older ${pending} than it is configured with, so it needs a reboot for that to take effect. A service the activation never restarts stays on the version the machine booted with, and nothing else reports that drift"
elif [ "$compared" -eq 0 ]; then
  warn "could not read either of /run/booted-system and /run/current-system, so whether this host needs a reboot is unknown"
else
  ok "booted kernel, initrd and modules match the configuration (${compared} of 3 comparable)"
fi

if [ "$fail" -ne 0 ]; then
  printf '\n%s checks FAILED for %s\n' "$mode" "$node" >&2
  exit 1
fi
printf '\n%s checks passed for %s\n' "$mode" "$node"
