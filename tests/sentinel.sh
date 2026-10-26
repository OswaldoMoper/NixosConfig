#!/usr/bin/env bash
# Runs sentinel against a fake journal, systemctl, nix-store and mail, over a
# fake /proc and temporary directories, and checks what each pass mails and
# what it learns.
#
#   bash tests/sentinel.sh scripts/sentinel.sh
#
# Passes within a story share the state directory, as days on one machine do;
# a new story starts from an empty one.
set -euo pipefail

sentinel_sh="$(realpath "$1")"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
bin="$work/bin"
mkdir -p "$bin"
bash_path="$(command -v bash)"

fake() {
  { printf '#!%s\n' "$bash_path"; cat; } > "$bin/$1"
  chmod +x "$bin/$1"
}

fake journalctl <<'EOF'
echo "journalctl $*" >> "$CALLS"
cat "$WORK/journal"
EOF
fake systemctl <<'EOF'
case "$1" in
  list-units) sed -n 's/^Id=//p' "$WORK/units" | sed 's/$/ loaded active running x/' ;;
  show) cat "$WORK/units" ;;
esac
EOF
fake nix-store <<'EOF'
case "$1" in
  -qR) printf '/nix/store/aaa-system\n/nix/store/bbb-glibc\n' ;;
  --verify-path)
    shift
    for p; do
      grep -qxF "$p" "$WORK/bad" 2>/dev/null && echo "path '$p' was modified! expected hash 'x', got 'y'" >&2
    done
    exit 0 ;;
esac
EOF
fake mail <<'EOF'
cat >> "$MAILS"
exit "${FAKE_MAIL_RC:-0}"
EOF

cases=0 failures=0 name="" problems="" out="" rc=0 mail=""
root="$work/root" state="$work/state" calls="$work/calls" mails="$work/mails"

finish() {
  [ -n "$name" ] || return 0
  cases=$((cases + 1))
  if [ -z "$problems" ]; then
    echo "ok    $name"
  else
    failures=$((failures + 1))
    printf 'FAIL  %s%s\n' "$name" "$problems"
    printf '%s\n' "$out" "$mail" | tail -n 12 | sed 's/^/      | /'
  fi
  name=""
}

# A new machine: a login, a process of an editor that updates itself, one in the
# store, a unit written by hand, an executable in /tmp and a modified store path.
story() {
  finish
  rm -rf "$root" "$state" && mkdir -p "$root/proc" "$root/tmp" "$root/var/tmp" "$root/dev/shm" \
    "$root/home/dev/.vscode-server" "$root/etc/systemd/system"
  printf 'Oct 26 02:18:44 box sshd-session[7]: Accepted key ED25519 SHA256:aaa found at /etc/ssh/authorized_keys.d/admin:6\n' > "$work/journal"
  printf 'Oct 26 02:18:44 box sshd-session[7]: Accepted publickey for admin from 187.243.1.2 port 5000 ssh2: ED25519 SHA256:aaa\n' >> "$work/journal"
  proc 101 "$root/home/dev/.vscode-server/code-111" editor-1
  mkdir -p "$root/proc/104" && ln -s "$root/home/dev/.vscode-server/code-111" "$root/proc/104/exe"
  mkdir -p "$root/proc/102" && ln -s /nix/store/ccc-sshd/bin/sshd "$root/proc/102/exe"
  echo 'echo hi' > "$root/tmp/x" && chmod +x "$root/tmp/x"
  echo '[Service]' > "$root/etc/systemd/system/miner.service"
  printf 'Id=miner.service\nFragmentPath=/etc/systemd/system/miner.service\nId=sshd.service\nFragmentPath=/nix/store/ddd-unit/sshd.service\n' > "$work/units"
  echo /nix/store/bbb-glibc > "$work/bad"
  printf '/home/*/.vscode-server/code-*\n' > "$work/versioned"
}

proc() {
  mkdir -p "$root/proc/$1" "$(dirname "$2")"
  echo "$3" > "$2"
  rm -f "$root/proc/$1/exe" && ln -s "$2" "$root/proc/$1/exe"
}

# pass NAME [VAR=value ...]: one sentinel pass, judged by the assertions after it.
pass() {
  finish
  name="$1" problems="" rc=0
  shift
  : > "$calls" && : > "$mails"
  out="$(env -i PATH="$bin:$PATH" WORK="$work" CALLS="$calls" MAILS="$mails" TMPDIR="$work" \
    SENTINEL_ROOT="$root" SENTINEL_MAIL=mail "$@" \
    bash "$sentinel_sh" "$state" "$work/versioned" 2>&1)" || rc=$?
  mail="$(cat "$mails")"
}

bad() { problems="$problems"$'\n'"      - $*"; }
ok() { [ "$rc" -eq 0 ] || bad "exited $rc"; }
mails() { grep -qF -- "$1" <<< "$mail" || bad "never mailed: $1"; }
not_mails() { ! grep -qF -- "$1" <<< "$mail" || bad "mailed: $1"; }
silent() { [ -z "$mail" ] || bad "mailed: $(head -n 3 <<< "$mail")"; }
learned() { grep -qF -- "$1" "$state/known" || bad "never learned: $1"; }
called() { grep -qE -- "$1" "$calls" || bad "never ran: $1"; }
not_called() { ! grep -qE -- "$1" "$calls" || bad "ran: $1"; }

story
pass "the first pass mails everything it sees, versioned or not, and learns it"
ok; not_called '--since'
mails 'new ssh key: admin SHA256:aaa'; mails 'new ssh network: admin 187.243.0.0/16'
mails 'new process outside the store: /home/dev/.vscode-server/code-111'
mails 'new unit outside the store: miner.service /etc/systemd/system/miner.service'
mails 'new executable in a temporary directory: /tmp/x'
mails 'store path whose content fails its hash: /nix/store/bbb-glibc'
not_mails 'ccc-sshd'; not_mails 'sshd.service'; not_mails "$root"
[ "$(grep -c 'code-111' <<< "$mail")" = 1 ] || bad "two processes of one binary mailed it more than once"
learned 'ssh-net	admin 187.243.0.0/16'; learned 'proc	/home/dev/.vscode-server/code-111	'
pass "a second pass over the same machine mails nothing, and reads the journal since the first"
ok; silent; called '^journalctl .*--since [0-9-]+ [0-9:]+ UTC'

printf 'Oct 27 01:00:00 box sshd-session[9]: Failed password for root from 45.1.2.3 port 1 ssh2\n' > "$work/journal"
pass "a failed login mails nothing"; ok; silent

printf 'Oct 27 01:00:00 box sshd-session[9]: Accepted publickey for admin from 189.128.5.6 port 1 ssh2: ED25519 SHA256:aaa\n' > "$work/journal"
pass "a known key from a new /16 mails the network, not the key"
ok; mails 'new ssh network: admin 189.128.0.0/16'; not_mails 'new ssh key'

printf 'Oct 27 01:00:00 box sshd-session[9]: Accepted publickey for admin from 189.128.5.6 port 1 ssh2: ED25519 SHA256:zzz\nOct 27 01:00:00 box sshd-session[9]: Accepted key ED25519 SHA256:zzz found at /home/admin/.ssh/authorized_keys:1\n' > "$work/journal"
pass "a new key for a known user mails it, and so does a key found outside authorized_keys.d"
ok; mails 'new ssh key: admin SHA256:zzz'; not_mails 'new ssh network'
mails 'ssh key accepted from outside /etc/ssh/authorized_keys.d: /home/admin/.ssh/authorized_keys:1 SHA256:zzz'
pass "a key found outside authorized_keys.d mails every time it is used"
ok; mails 'outside /etc/ssh/authorized_keys.d'
: > "$work/journal"

proc 101 "$root/home/dev/.vscode-server/code-222" editor-2
pass "a new version under a versioned glob passes quietly, and is learned"
ok; silent; learned 'proc	/home/dev/.vscode-server/code-222	'
echo tampered > "$root/home/dev/.vscode-server/code-222"
pass "a known versioned executable whose content changes mails it"
ok; mails 'changed process outside the store: /home/dev/.vscode-server/code-222'

echo 'echo bye' > "$root/tmp/x"
pass "a known executable whose content changes mails it"
ok; mails 'changed executable in a temporary directory: /tmp/x'
mkdir -p "$root/dev/shm/d" && echo x > "$root/dev/shm/d/y" && chmod +x "$root/dev/shm/d/y"
proc 103 "$root/opt/miner" miner
pass "an unversioned process and an executable in /dev/shm mail when new" FAKE_MAIL_RC=1
[ "$rc" -ne 0 ] || bad "exited 0 when the mail failed"
mails 'new process outside the store: /opt/miner'; mails 'new executable in a temporary directory: /dev/shm/d/y'
pass "what a failed mail reported is reported again"
ok; mails 'new process outside the store: /opt/miner'; learned 'proc	/opt/miner	'

finish
echo "$((cases - failures)) of $cases cases pass"
[ "$failures" -eq 0 ]
