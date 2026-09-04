spec="${LOCAL_SPEC}"
host="$(jq -r .host "$spec")"

run="$(mktemp -d -t "run-${host}-local.XXXXXX")"
pids=()
pg_started=0

# Everything this script makes lives under one directory, so cleanup is one
# rm. The apps are children of this shell, so a plain kill reaches them.
cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  if [ "${#pids[@]}" -gt 0 ]; then
    kill "${pids[@]}" 2>/dev/null || true
    wait "${pids[@]}" 2>/dev/null || true
  fi
  if [ "$pg_started" = 1 ]; then
    pg_ctl -D "$run/pg" -m immediate stop >/dev/null 2>&1 || true
  fi
  rm -rf "$run"
  exit "$rc"
}
trap cleanup EXIT INT TERM

say() { printf '  %s\n' "$1"; }

printf '\nrunning %s locally in %s\n\n' "$host" "$run"

# ── secrets ───────────────────────────────────────────────────────────────
# The real ones are encrypted to the host's key, so what lands here is
# whatever vm.secretValues declared -- empty unless a consumer rejects that.
mkdir -p "$run/secrets"
while IFS=$'\t' read -r name path; do
  [ -n "$name" ] || continue
  jq -r --arg n "$name" '.secrets[$n].value' "$spec" > "$run/secrets/$name"
  printf '%s\t%s\n' "$path" "$run/secrets/$name" >> "$run/secret-map"
done < <(jq -r '.secrets | to_entries[] | [.key, .value.path] | @tsv' "$spec")
touch "$run/secret-map"

# ── postgres ──────────────────────────────────────────────────────────────
# Its own cluster in $run, never the machine's: a local run must not be able
# to touch real data, and the declared port is taken on a dev box more often
# than not.
if jq -e '.postgres != null' "$spec" >/dev/null; then
  pg_port="${LOCAL_PG_PORT:-$(jq -r '.postgres.port' "$spec")}"

  # Unix socket only, in a directory unique to this run: no TCP means the
  # declared port cannot collide with anything, so there is nothing to probe
  # and no reason to move it. libpq reads a PGHOST that starts with / as a
  # socket directory, which is what every app here ends up with.
  say "postgres on ${run} (unix socket, port ${pg_port}, no TCP)"
  initdb -D "$run/pg" -U postgres --auth=trust --encoding=UTF8 >/dev/null
  pg_ctl -D "$run/pg" -l "$run/pg.log" \
    -o "-p $pg_port -k $run -c listen_addresses=" -w start >/dev/null
  pg_started=1

  while IFS=$'\t' read -r db role; do
    [ -n "$db" ] || continue
    if [ -n "$role" ] && [ "$role" != "null" ]; then
      psql -h "$run" -p "$pg_port" -U postgres -d postgres -tAc \
        "select 1 from pg_roles where rolname = '$role'" | grep -q 1 \
        || psql -h "$run" -p "$pg_port" -U postgres -d postgres -q \
             -c "create role \"$role\" login" >/dev/null
      createdb -h "$run" -p "$pg_port" -U postgres -O "$role" "$db"
      say "database ${db} owned by ${role}"
    else
      createdb -h "$run" -p "$pg_port" -U postgres "$db"
      say "database ${db}"
    fi
  done < <(jq -r '.postgres.databases[] as $d
                  | [$d, (first(.postgres.roles[] | select(.database == $d) | .role) // "null")]
                  | @tsv' "$spec")
else
  pg_port=""
fi

# ── the apps ──────────────────────────────────────────────────────────────
echo
while read -r s; do
  [ -n "$s" ] || continue
  say "skipping ${s}: no unit. A profile app needs webStack ... unit = \"<systemd unit>\""
done < <(jq -r '.skipped[]?' "$spec")

count="$(jq -r '.units | length' "$spec")"
if [ "$count" = 0 ]; then
  echo "nothing to run for ${host}" >&2
  exit 1
fi

for i in $(seq 0 $((count - 1))); do
  u() { jq -r --argjson i "$i" ".units[\$i].$1" "$spec"; }

  name="$(u name)"
  exec_line="$(u exec)"
  workdir="$(u workingDirectory)"
  envfile="$(u environmentFile)"

  # Only paths the unit itself declared get rewritten. StateDirectory is
  # systemd's own statement of "these are mine under /var/lib", so redirecting
  # exactly those is not guesswork -- and an app whose ExecStart embeds one,
  # as a hardened profile app does, follows along.
  state_root="$run/state"
  sed_args=()
  while read -r d; do
    [ -n "$d" ] || continue
    top="${d%%/*}"
    mkdir -p "$state_root/$d"
    sed_args+=(-e "s#/var/lib/${top}#${state_root}/${top}#g")
  done < <(jq -r --argjson i "$i" '.units[$i].stateDirectory[]?' "$spec" | sort -u)

  rewrite() {
    if [ "${#sed_args[@]}" -gt 0 ]; then sed "${sed_args[@]}"; else cat; fi
  }

  exec_line="$(printf '%s' "$exec_line" | rewrite)"

  # The environment, with the same rewrite, plus libpq's own variables so an
  # app that never declared a host still finds this cluster.
  env_args=()
  while IFS=$'\t' read -r k v; do
    [ -n "$k" ] || continue
    v="$(printf '%s' "$v" | rewrite)"
    case "$k" in
      *PGHOST) v="$run" ;;
      *PGPORT) v="$pg_port" ;;
    esac
    env_args+=("$k=$v")
  done < <(jq -r --argjson i "$i" '.units[$i].environment | to_entries[] | [.key, .value] | @tsv' "$spec")

  if [ -n "$pg_port" ]; then
    env_args+=("PGHOST=$run" "PGPORT=$pg_port")
  fi
  if [ -n "$state_root" ]; then
    env_args+=("STATE_DIRECTORY=$state_root")
  fi

  # EnvironmentFile points into /run/agenix, which does not exist here.
  if [ "$envfile" != "null" ] && [ -n "$envfile" ]; then
    local_file="$(awk -F'\t' -v p="$envfile" '$1 == p { print $2 }' "$run/secret-map" | head -1)"
    if [ -n "$local_file" ]; then
      while IFS= read -r line; do
        case "$line" in ''|'#'*) continue ;; esac
        env_args+=("$line")
      done < "$local_file"
    else
      say "warning: ${name} wants ${envfile}, which nothing declared"
    fi
  fi

  cd_to="$run"
  if [ "$workdir" != "null" ] && [ -n "$workdir" ]; then
    cd_to="$(printf '%s' "$workdir" | rewrite)"
    mkdir -p "$cd_to" 2>/dev/null || true
  fi

  # env -i, because systemd gives a unit a clean environment too. That means
  # the shell has to be an absolute path: the unit's own PATH is what we are
  # about to set, and a unit that declares none would have nothing to find.
  say "starting ${name}"
  ( cd "$cd_to" && env -i "${env_args[@]}" "$LOCAL_SHELL" -c "exec $exec_line" ) &
  pids+=($!)
done

echo
echo "running. Ctrl-C stops everything and removes ${run}"
wait
