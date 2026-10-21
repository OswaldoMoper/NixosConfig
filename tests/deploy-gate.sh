#!/usr/bin/env bash
# Runs the deploy gate against fake ssh, scp, nix, nix-store and deploy, fake
# guards, census and backup, and checks where each case stops and what it ran.
#
#   bash tests/deploy-gate.sh scripts/deploy-gate.sh
#
# A case is judged on structure: the exit code, the last "=== step" the gate
# printed, and the commands it ran, in order. Wording is checked only where the
# message is the whole effect -- a verdict, or a warning on a path that
# otherwise passes -- so rewording anything else breaks nothing here.
set -euo pipefail

gate_sh="$(realpath "$1")"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
bin="$work/bin"
mkdir -p "$bin"
bash_path="$(command -v bash)"

fake() {
  { printf '#!%s\n' "$bash_path"; cat; } > "$bin/$1"
  chmod +x "$bin/$1"
}

# Each fake logs one line to $CALLS. $STATE/deployed marks that deploy ran, so
# the machine can answer differently before and after it.
fake ssh <<'EOF'
echo "ssh $*" >> "$CALLS"
case "$*" in
  *readlink*) echo "${FAKE_LIVE:-$BUILT}" ;;
  *server_version_num*)
    if [ -e "$STATE/deployed" ]; then echo "${FAKE_MAJOR_AFTER-150004}"; else echo "${FAKE_MAJOR_BEFORE-150004}"; fi ;;
  *'/bin/schema plan'*) exit "${FAKE_PLAN_RC:-0}" ;;
  *'/bin/schema apply'*) exit "${FAKE_APPLY_RC:-0}" ;;
esac
exit 0
EOF
fake scp <<'EOF'
echo "scp $*" >> "$CALLS"
for dest; do :; done
if [ "${FAKE_DUMP_OK:-1}" = 1 ]; then echo '-- PostgreSQL database dump' > "$dest"; else echo 'not a dump' > "$dest"; fi
EOF
fake nix <<'EOF'
echo "nix $*" >> "$CALLS"
case "$1" in
  flake) exit "${FAKE_CHECKS_RC:-0}" ;;
  build)
    case "$*" in *'#checks.'*) exit "${FAKE_CHECKS_RC:-0}" ;; esac
    [ "${FAKE_BUILD_RC:-0}" = 0 ] || exit "$FAKE_BUILD_RC"
    echo "$BUILT" ;;
  copy)
    echo "NIX_SSHOPTS=${NIX_SSHOPTS:-}" >> "$CALLS"
    exit "${FAKE_COPY_RC:-0}" ;;
esac
EOF
fake nix-store <<'EOF'
echo "nix-store $*" >> "$CALLS"
echo "$BUILT"
[ "${FAKE_IN_CLOSURE:-1}" = 0 ] || dirname "$(dirname "$GATE_SCHEMA_BIN")"
EOF
fake deploy <<'EOF'
echo "deploy $*" >> "$CALLS"
touch "$STATE/deployed"
exit "${FAKE_DEPLOY_RC:-0}"
EOF
fake sleep <<'EOF'
echo "sleep $*" >> "$CALLS"
EOF
# Before the deploy: FAKE_CENSUS_BEFORE. The first look after it:
# FAKE_CENSUS_AFTER; any later look: FAKE_CENSUS_AGAIN; after a restore:
# FAKE_CENSUS_RESTORED. Each defaults to the one before it.
fake census <<'EOF'
echo census >> "$CALLS"
if [ -e "$STATE/restored" ]; then
  printf '%b' "${FAKE_CENSUS_RESTORED-$FAKE_CENSUS_BEFORE}"
elif [ -e "$STATE/looked" ]; then
  printf '%b' "${FAKE_CENSUS_AGAIN-${FAKE_CENSUS_AFTER-$FAKE_CENSUS_BEFORE}}"
elif [ -e "$STATE/deployed" ]; then
  touch "$STATE/looked"
  printf '%b' "${FAKE_CENSUS_AFTER-$FAKE_CENSUS_BEFORE}"
else
  printf '%b' "$FAKE_CENSUS_BEFORE"
fi
exit "${FAKE_CENSUS_RC:-0}"
EOF
fake backup <<'EOF'
echo "backup $*" >> "$CALLS"
case "$1" in
  --once) exit "${FAKE_BACKUP_RC:-0}" ;;
  --restore)
    [ "${FAKE_RESTORE_RC:-0}" != 0 ] || touch "$STATE/restored"
    exit "${FAKE_RESTORE_RC:-0}" ;;
esac
EOF
for g in fresh pins caches pre access verify; do
  fake "guard-$g" <<EOF
echo "guard $g \$*" >> "\$CALLS"
exit "\${FAKE_${g^^}_RC:-0}"
EOF
done

built=/nix/store/00000000000000000000000000000000-nixos-system-web
census='table app users\ntable app posts\nrows users 5\nfiles uploads 3\n'

# The fullest node: a census, a backup and a schema. A case drops what it does
# not use by setting the variable empty, as the gate reads empty as absent.
base=(
  GATE_NODE=web GATE_FLAKE=. GATE_HOST=web GATE_HOST_ADDR=web.example GATE_HOST_USER=admin
  GATE_FRESH="$bin/guard-fresh" GATE_PINS="$bin/guard-pins" GATE_CACHES="$bin/guard-caches"
  GATE_PRE_DEPLOY="$bin/guard-pre" GATE_ACCESS="$bin/guard-access" GATE_VERIFY="$bin/guard-verify"
  GATE_CHECKS=hosts
  GATE_CENSUS="$bin/census" GATE_CENSUS_ROWS=users GATE_APP_UNITS=app
  GATE_BACKUP_BIN="$bin/backup" GATE_BACKUP_APP=app GATE_BACKUP_CONFIG=/etc/backup.json
  GATE_SCHEMA_BIN=/nix/store/11111111111111111111111111111111-schema/bin/schema GATE_SCHEMA_USER=app
  GATE_FAST_CONNECTION=0
  FAKE_CENSUS_BEFORE="$census"
)
no_extras=(GATE_CENSUS= GATE_BACKUP_BIN= GATE_SCHEMA_BIN=)

cases=0 failures=0 name="" problems="" out="" rc=0 last=""
calls="$work/calls"

finish() {
  [ -n "$name" ] || return 0
  cases=$((cases + 1))
  if [ -z "$problems" ]; then
    echo "ok    $name"
  else
    failures=$((failures + 1))
    printf 'FAIL  %s%s\n' "$name" "$problems"
    printf '%s\n' "$out" | tail -n 12 | sed 's/^/      | /'
  fi
  name=""
}

# run NAME [VAR=value ...]: one gate run, judged by the assertions after it.
run() {
  finish
  name="$1" problems="" rc=0
  shift
  rm -rf "$work/state" && mkdir "$work/state"
  : > "$calls"
  out="$(cd "$work" && env -i PATH="$bin:$PATH" HOME="$work" TMPDIR="$work" \
    CALLS="$calls" STATE="$work/state" BUILT="$built" "${base[@]}" "$@" \
    bash -euo pipefail "$gate_sh" 2>&1)" || rc=$?
  last="$(grep '^=== ' <<< "$out" | tail -n 1 | cut -d' ' -f2)" || true
}

bad() { problems="$problems"$'\n'"      - $*"; }
stops_at() {
  [ "$rc" -ne 0 ] || bad "exited 0, expected a stop at $1"
  [ "$last" = "$1" ] || bad "last step ${last:-none}, expected $1"
}
stops_before_1() {
  [ "$rc" -ne 0 ] || bad "exited 0, expected a stop before 1/8"
  [ -z "$last" ] || bad "reached $last"
}
passes() {
  [ "$rc" -eq 0 ] || bad "exited $rc"
  reached 8/8
}
reached() { grep -q "^=== $1 " <<< "$out" || bad "never reached $1"; }
not_reached() { ! grep -q "^=== $1 " <<< "$out" || bad "reached $1"; }
called() { grep -qE -- "$1" "$calls" || bad "never ran: $1"; }
not_called() { ! grep -qE -- "$1" "$calls" || bad "ran: $1"; }
says() { grep -qF -- "$1" <<< "$out" || bad "never said: $1"; }
not_says() { ! grep -qF -- "$1" <<< "$out" || bad "said: $1"; }
# Each pattern matches a later line of the log than the one before it.
in_order() {
  local seen=0 pat at
  for pat; do
    at="$(tail -n +"$((seen + 1))" "$calls" | grep -nE -m 1 -- "$pat" | cut -d: -f1)" || true
    if [ -z "$at" ]; then
      bad "not in order: $pat"
      return 0
    fi
    seen=$((seen + at))
  done
}

# Refusals before anything runs.
run "GATE_MIGRATE on a node with a backup stops before 1/8" GATE_MIGRATE=1
stops_before_1; not_called '^deploy'
run "GATE_SCHEMA_OK on a node without a schema stops before 1/8" GATE_SCHEMA_BIN= GATE_SCHEMA_OK=0003-a
stops_before_1; not_called '^deploy'
run "GATE_SCHEMA_OK with GATE_SKIP_SCHEMA=1 stops before 1/8" GATE_SCHEMA_OK=0003-a GATE_SKIP_SCHEMA=1
stops_before_1; not_called '^deploy'
run "a schema without a backup stops before 1/8" GATE_BACKUP_BIN=
stops_before_1; not_called '^deploy'

# The eight steps of a node that declares nothing else.
run "a plain node runs the eight steps in order" "${no_extras[@]}"
passes
in_order '^guard fresh' '^guard pins' '^guard caches' '^nix build --no-link \.#checks\.x86_64-linux\.hosts$' \
  '^guard pre' '^nix build .*\.#nixosConfigurations\.web\.config\.system\.build\.toplevel$' "^guard access $built$" \
  '^deploy --skip-checks \.#web$' 'readlink -f /run/current-system$' '^guard verify'
for s in 6a 6b 6c 6d 6e 7b 8b 8c; do not_reached "$s/8"; done
run "a freshness finding warns and goes on" "${no_extras[@]}" FAKE_FRESH_RC=1
passes
run "freshness that could not ask stops at 1/8" FAKE_FRESH_RC=2
stops_at 1/8; not_called '^guard pins'
run "a pins finding stops at 1b" FAKE_PINS_RC=1
stops_at 1b/8; not_called '^guard caches'
run "caches answered abort stops at 2/8" FAKE_CACHES_RC=1
stops_at 2/8; not_called '^nix'
run "no named checks means nix flake check" "${no_extras[@]}" GATE_CHECKS=
passes; called '^nix flake check \.$'; not_called '#checks\.'
run "failing checks stop at 3/8" FAKE_CHECKS_RC=1
stops_at 3/8; not_called '^guard pre'
run "failing live preconditions stop at 4/8" FAKE_PRE_RC=1
stops_at 4/8; not_called 'toplevel'
run "GATE_SKIP_PREFLIGHT=1 skips them, and says so" "${no_extras[@]}" GATE_SKIP_PREFLIGHT=1
passes; not_called '^guard pre'; says "SKIPPED because GATE_SKIP_PREFLIGHT=1"
run "a failed build stops at 5/8" FAKE_BUILD_RC=1
stops_at 5/8; not_called '^guard access'
run "an access finding warns and goes on" "${no_extras[@]}" FAKE_ACCESS_RC=1
passes
run "access that could not look stops at 6/8" FAKE_ACCESS_RC=2
stops_at 6/8; not_called '^nix copy|^census'
run "a failed deploy that landed and verifies passes, and says so" "${no_extras[@]}" FAKE_DEPLOY_RC=1
passes; says "deploy exited 1, but the host runs the closure we built"
run "another system live stops at 8/8" FAKE_LIVE=/nix/store/22222222222222222222222222222222-nixos-system-web
stops_at 8/8; not_called '^guard verify'
run "a failed verify stops at 8/8" FAKE_VERIFY_RC=1
stops_at 8/8

# 6a and 6e: the schema.
run "the full node runs its steps in order" GATE_SCHEMA_OK="0003-a 0004-b"
passes
in_order '^guard access' '^nix copy' '/bin/schema plan' '^census$' '^backup --once app /etc/backup\.json$' \
  '/bin/schema apply' '^deploy ' '^census$'
run "plan and apply get the names as arguments" GATE_SCHEMA_OK="0003-a 0004-b"
passes
called '^ssh .* sudo -u app /nix/store/1+-schema/bin/schema plan 0003-a 0004-b ?$'
called '^ssh .* sudo -u app /nix/store/1+-schema/bin/schema apply 0003-a 0004-b ?$'
run "without names, plan gets no arguments"
passes; called '/bin/schema plan ?$'
run "a user with a space reaches the machine quoted" GATE_SCHEMA_USER="app user"
passes; called 'sudo -u app\\ user '
run "GATE_SKIP_SCHEMA=1 skips 6a and 6e, and says so" GATE_SKIP_SCHEMA=1
passes; reached 6a/8; not_reached 6e/8; not_called '^nix copy|/bin/schema'
says "SKIPPED because GATE_SKIP_SCHEMA=1"
run "a schema outside the built system stops at 6a, before copying" FAKE_IN_CLOSURE=0
stops_at 6a/8; not_called '^nix copy'
run "a failed copy stops at 6a, before plan" FAKE_COPY_RC=1
stops_at 6a/8; called '^nix copy'; not_called '/bin/schema'
run "the copy substitutes on the machine by default"
passes
called "^nix copy --no-check-sigs --substitute-on-destination --to ssh://admin@web\\.example $built$"
run "a fast connection copies everything from here" GATE_FAST_CONNECTION=1
passes; called '^nix copy --no-check-sigs --to ssh://admin@web\.example '; not_called 'substitute-on-destination'
run "GATE_SSH_CONFIG reaches the copy, ssh and deploy" GATE_SSH_CONFIG=/etc/ssh-deploy
passes
called '^NIX_SSHOPTS=-o BatchMode=yes -o ConnectTimeout=10 -F /etc/ssh-deploy$'
called '^ssh -F /etc/ssh-deploy '; called '^deploy .*--ssh-opts -F /etc/ssh-deploy'
run "GATE_SSH_USER reaches the copy and deploy" GATE_SSH_USER=deployer GATE_HOST_USER=deployer
passes; called '^nix copy .*--to ssh://deployer@web\.example '; called '^deploy .*--ssh-user deployer'

# What the gate says for each code of the schema program.
plan_verdict=(
  [2]="could not look at the schema"
  [3]="name it in GATE_SCHEMA_OK and run again"
  [4]="the schema needs what only a release can give"
  [5]="the schema program exited 5"
)
apply_verdict=(
  [2]="could not change the schema"
  [3]="name it in GATE_SCHEMA_OK and run again"
  [4]="the schema needs what only a release can give"
  [5]="the schema program exited 5"
)
for code in 2 3 4 5; do
  run "plan exiting $code stops at 6a, before the census" FAKE_PLAN_RC=$code
  stops_at 6a/8; not_called '^census$|^backup|^deploy'
  says "${plan_verdict[$code]}"; says "nothing was deployed"; not_says "old system"
  run "apply exiting $code stops at 6e, after the copy and before the deploy" FAKE_APPLY_RC=$code
  stops_at 6e/8; called '^backup --once '; not_called '^deploy'
  says "${apply_verdict[$code]}"; says "nothing was deployed"
  says "the machine still serves the old system, and the copy from 6d is there"
done

# 6c and 6d.
run "a census that fails stops at 6c, before the backup" FAKE_CENSUS_RC=1
stops_at 6c/8; not_called '^backup'
run "a backup that fails stops at 6d, before apply" FAKE_BACKUP_RC=1
stops_at 6d/8; not_called '/bin/schema apply|^deploy'

# 6b and 7b: a node without a backup, through a major upgrade.
migrate=("${no_extras[@]}" GATE_MIGRATE=1)
run "a major that moves gets the dump back" "${migrate[@]}" FAKE_MAJOR_AFTER=160002
passes; reached 6b/8; reached 7b/8
in_order 'pg_dumpall > /var/tmp/web\.sql' '^scp .*admin@web\.example:/var/tmp/web\.sql ' '^deploy ' \
  'cat /var/tmp/web\.sql \| sudo -u postgres psql postgres' 'rm -f /var/tmp/web\.sql'
run "a major that stays restores nothing" "${migrate[@]}"
passes; not_called 'psql postgres'; called 'rm -f /var/tmp/web\.sql'
run "a version it cannot read stops at 6b, before the dump" "${migrate[@]}" FAKE_MAJOR_BEFORE=
stops_at 6b/8; not_called 'pg_dumpall'
run "a dump that is not one stops at 6b, before the deploy" "${migrate[@]}" FAKE_DUMP_OK=0
stops_at 6b/8; not_called '^deploy'
run "a version it cannot read after the deploy stops at 7b" "${migrate[@]}" FAKE_MAJOR_AFTER=
stops_at 7b/8; called '^deploy'; not_called 'psql postgres'

# 8b and 8c: what the deploy removed.
run "nothing removed passes without a second look"
passes; reached 8b/8; not_reached 8c/8; not_called '^sleep'
run "a table gone stops at 8b, after a second look" FAKE_CENSUS_AFTER='table app users\nrows users 5\nfiles uploads 3\n'
stops_at 8b/8; called '^sleep 10$'; not_called '--restore'
run "a table gone and named in GATE_SHRINK_OK passes" \
  FAKE_CENSUS_AFTER='table app users\nrows users 5\nfiles uploads 3\n' GATE_SHRINK_OK=posts
passes; not_called '^sleep'
run "a table back on the second look passes" \
  FAKE_CENSUS_AFTER='table app users\nrows users 5\nfiles uploads 3\n' FAKE_CENSUS_AGAIN="$census"
passes; called '^sleep 10$'; not_called '--restore'
run "a database that came back new is put back, with the apps stopped" \
  FAKE_CENSUS_AFTER='table app users\ntable app posts\nrows users 0\nfiles uploads 3\n'
passes; reached 8c/8
in_order 'sudo systemctl stop app$' '^backup --restore app --database --empty users /etc/backup\.json$' \
  'sudo systemctl start app$'
run "a database that is behind is not replaced, and stops at 8b" \
  FAKE_CENSUS_AFTER='table app users\ntable app posts\nrows users 3\nfiles uploads 3\n'
stops_at 8b/8; not_called '--restore'
run "missing uploads are put back" FAKE_CENSUS_AFTER='table app users\ntable app posts\nrows users 5\nfiles uploads 1\n'
passes; reached 8c/8; called '^backup --restore app --uploads /etc/backup\.json$'; not_called '--database'
run "a restore that fails stops at 8c, with the apps started again" FAKE_RESTORE_RC=1 \
  FAKE_CENSUS_AFTER='table app users\ntable app posts\nrows users 0\nfiles uploads 3\n'
stops_at 8c/8; in_order 'systemctl stop app$' '--database --empty users' 'systemctl start app$'
run "without a backup a table gone stops at 8b" GATE_BACKUP_BIN= GATE_SCHEMA_BIN= \
  FAKE_CENSUS_AFTER='table app users\nrows users 5\nfiles uploads 3\n'
stops_at 8b/8; not_reached 8c/8; not_called '--restore'

finish
echo "$((cases - failures)) of $cases cases pass"
[ "$failures" -eq 0 ]
