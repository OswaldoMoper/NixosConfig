psql_() { runuser -u postgres -- psql -v ON_ERROR_STOP=1 -d postgres -tAc "$1"; }

exists() { [ "$(psql_ "SELECT 1 FROM pg_database WHERE datname = '$1'")" = 1 ]; }

# datallowconn survives the rename and there is no superuser bypass, so a script
# that dies between closing the door and reopening it leaves the database
# unreachable. Whichever name is on disk when we leave, reopen it.
reopen() {
  local rc=$?
  trap - EXIT INT TERM
  if [ -n "${closed:-}" ]; then
    for n in "$closed" "${opening:-}"; do
      [ -n "$n" ] || continue
      if exists "$n"; then
        psql_ "ALTER DATABASE \"$n\" WITH ALLOW_CONNECTIONS true" >/dev/null || true
      fi
    done
  fi
  exit "$rc"
}

for pair in ${RENAME_PAIRS:-}; do
  from="${pair%%=*}"
  to="${pair#*=}"

  # Four states, and only one of them is work. "Both exist" is a decision a
  # person has to make -- which one holds the data -- so it stops here rather
  # than picking.
  if exists "$to"; then
    if exists "$from"; then
      echo "postgresql.renames: both ${from} and ${to} exist; nothing here can tell which one holds the data" >&2
      exit 1
    fi
    echo "  ${from} -> ${to}: already renamed"
    continue
  fi
  if ! exists "$from"; then
    echo "  ${from} -> ${to}: neither exists, nothing to do"
    continue
  fi

  closed="$from"
  opening="$to"
  trap reopen EXIT INT TERM

  psql_ "ALTER DATABASE \"$from\" WITH ALLOW_CONNECTIONS false" >/dev/null
  psql_ "SELECT pg_terminate_backend(pid) FROM pg_stat_activity
         WHERE datname = '$from' AND pid <> pg_backend_pid()" >/dev/null

  # pg_terminate_backend only asks; the backends go away on their own time, and
  # a rename with one still attached fails.
  renamed=0
  for _ in 1 2 3 4 5; do
    if psql_ "ALTER DATABASE \"$from\" RENAME TO \"$to\"" >/dev/null 2>&1; then
      renamed=1
      break
    fi
    sleep 1
  done
  if [ "$renamed" != 1 ]; then
    echo "postgresql.renames: ${from} still has connections after 5s, so it was not renamed" >&2
    exit 1
  fi

  closed="$to"
  psql_ "ALTER DATABASE \"$to\" WITH ALLOW_CONNECTIONS true" >/dev/null
  trap - EXIT INT TERM
  closed=""
  echo "  ${from} -> ${to}: renamed"
done
