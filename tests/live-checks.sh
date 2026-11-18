#!/usr/bin/env bash
# Runs the census of the live checks on this machine (LIVE_LOCAL=1) against a
# fake sudo, and checks what it prints for each directory of census.files.
#
#   bash tests/live-checks.sh scripts/live-checks.sh
set -euo pipefail

checks_sh="$(realpath "$1")"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
bin="$work/bin"
mkdir -p "$bin"
bash_path="$(command -v bash)"

# Logs each call. FAKE_SUDO_FAIL refuses every command, as sudo -n does with
# no rule for the account; FAKE_LS_FAIL fails only the listing, as for a
# directory that is there and cannot be read.
{ printf '#!%s\n' "$bash_path"; cat; } > "$bin/sudo" <<'EOF'
echo "sudo $*" >> "$CALLS"
if [ "${FAKE_SUDO_FAIL:-0}" = 1 ]; then
  echo 'sudo: a password is required' >&2
  exit 1
fi
[ "$1" = -n ] && shift
if [ "$1" = ls ] && [ "${FAKE_LS_FAIL:-0}" = 1 ]; then
  echo "ls: cannot open directory: Permission denied" >&2
  exit 2
fi
exec "$@"
EOF
chmod +x "$bin/sudo"

full="$work/full"
empty="$work/empty"
gone="$work/gone"
mkdir -p "$full" "$empty"
touch "$full/a" "$full/.b"

failures=0
out=""
case_name=""

# The way the deploy runs it: the script body under writeShellApplication's
# errexit, nounset and pipefail.
run() {
  case_name="$1"
  shift
  : > "$work/calls"
  out="$(env PATH="$bin:$PATH" CALLS="$work/calls" LIVE_NODE=node LIVE_MODE=census \
    LIVE_SSH_USER=admin LIVE_HOST=host LIVE_LOCAL=1 "$@" \
    bash -euo pipefail "$checks_sh" 2>/dev/null)" || {
    printf 'FAIL %s: the census exited %s\n' "$case_name" "$?"
    failures=$((failures + 1))
  }
}

prints() {
  if [ "$out" != "$(printf '%b' "$1")" ]; then
    printf 'FAIL %s: printed\n%s\nexpected\n%b\n' "$case_name" "$out" "$1"
    failures=$((failures + 1))
  fi
}

called() {
  if ! grep -qE -- "$1" "$work/calls"; then
    printf 'FAIL %s: no call matched %s\n' "$case_name" "$1"
    failures=$((failures + 1))
  fi
}

run "a directory with entries is counted through sudo -n" LIVE_CENSUS_FILES="$full"
prints "files $full 2"
called "^sudo -n ls -A $full\$"

run "an empty directory and a missing one both have no entries" LIVE_CENSUS_FILES="$empty $gone"
prints "files $empty 0\nfiles $gone 0"

run "sudo refusing is not an answer" LIVE_CENSUS_FILES="$full $gone" FAKE_SUDO_FAIL=1
prints "files $full unknown\nfiles $gone unknown"

run "a directory that is there and cannot be listed is not an answer" LIVE_CENSUS_FILES="$full" FAKE_LS_FAIL=1
prints "files $full unknown"

if [ "$failures" -gt 0 ]; then
  printf '%s failure(s)\n' "$failures"
  exit 1
fi
printf 'live-checks census: all cases passed\n'
