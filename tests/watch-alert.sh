#!/usr/bin/env bash
# Runs watch-alert against a fake alert command and a fake logger, over a
# temporary directory of marks, and checks what each failing name sends, what
# it logs and what it marks.
#
#   bash tests/watch-alert.sh scripts/watch-alert.sh
#
# Alerts within a story share the marks, as passes on one machine do; a new
# story starts with none.
set -euo pipefail

watch_alert_sh="$(realpath "$1")"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
bin="$work/bin"
mkdir -p "$bin"
bash_path="$(command -v bash)"

fake() {
  { printf '#!%s\n' "$bash_path"; cat; } > "$bin/$1"
  chmod +x "$bin/$1"
}

fake send <<'EOF'
{ echo "to: $CATTLE_APP"; cat; } >> "$SENT"
exit "${FAKE_SEND_RC:-0}"
EOF
fake logger <<'EOF'
echo "$*" >> "$LOGGED"
EOF

cases=0 failures=0 name="" problems="" out="" rc=0 sent="" logged=""
marks="$work/marks" table="$work/table"
printf 'watch-a-example-org 203.0.113.10\nwatch-b-example-org 203.0.113.10\nwatch-c-example-net 203.0.113.20\n' > "$table"

finish() {
  [ -n "$name" ] || return 0
  cases=$((cases + 1))
  if [ -z "$problems" ]; then
    echo "ok    $name"
  else
    failures=$((failures + 1))
    printf 'FAIL  %s%s\n' "$name" "$problems"
    printf '%s\n' "$out" "$sent" "$logged" | tail -n 12 | sed 's/^/      | /'
  fi
  name=""
}

story() {
  finish
  rm -rf "$marks"
}

# alert NAME APP MINUTE [VAR=value ...]: APP fails at that minute of the story,
# judged by the assertions after it.
alert() {
  finish
  name="$1" problems="" rc=0
  local app="$2" minute="$3"
  shift 3
  : > "$work/sent" && : > "$work/logged"
  out="$(printf 'the body\n-- cattleServer\n' | env -i PATH="$bin:$PATH" SENT="$work/sent" LOGGED="$work/logged" \
    CATTLE_APP="$app" WATCH_ALERT_NOW="$((1800000000 + minute * 60))" "$@" \
    bash "$watch_alert_sh" "$table" "$marks" 1800 send 2>&1)" || rc=$?
  sent="$(cat "$work/sent")"
  logged="$(cat "$work/logged")"
}

bad() { problems="$problems"$'\n'"      - $*"; }
ok() { [ "$rc" -eq 0 ] || bad "exited $rc"; }
sends() { grep -qF -- "$1" <<< "$sent" || bad "never sent: $1"; }
sends_nothing() { [ -z "$sent" ] || bad "sent: $(head -n 3 <<< "$sent")"; }
logs() { grep -qF -- "$1" <<< "$logged" || bad "never logged: $1"; }
logs_nothing() { [ -z "$logged" ] || bad "logged: $logged"; }
marked() { [ -f "$marks/$1" ] || bad "never marked: $1"; }
not_marked() { [ ! -e "$marks/$1" ] || bad "marked: $1"; }

story
alert "the first name of a machine alerts, with the whole body and a line about the others" watch-a-example-org 0
ok; sends 'to: watch-a-example-org'; sends 'the body'; sends '-- cattleServer'
sends 'Other names on 203.0.113.10 that fail before 08:30 UTC send no alert of their own.'
logs_nothing; marked 203.0.113.10
alert "a second name of that machine in the same pass sends nothing, and logs why" watch-b-example-org 0
ok; sends_nothing
logs 'watch-b-example-org: no alert sent, 203.0.113.10 alerted at 08:00 UTC and stays quiet until 08:30 UTC'
alert "a name of another machine alerts" watch-c-example-net 0
ok; sends 'to: watch-c-example-net'; sends 'Other names on 203.0.113.20'; logs_nothing; marked 203.0.113.20
alert "a name of the first machine stays quiet a minute before the window ends" watch-b-example-org 29
ok; sends_nothing; logs 'watch-b-example-org: no alert sent'
alert "once the window has ended it alerts, and the window starts again" watch-b-example-org 30
ok; sends 'to: watch-b-example-org'; sends 'fail before 09:00 UTC'; logs_nothing
alert "which keeps the next name quiet" watch-a-example-org 31
ok; sends_nothing; logs 'alerted at 08:30 UTC and stays quiet until 09:00 UTC'

story
alert "an alert command that fails fails the alert, and marks nothing" watch-a-example-org 0 FAKE_SEND_RC=3
[ "$rc" -eq 3 ] || bad "exited $rc, not the command's 3"
not_marked 203.0.113.10
alert "so the next name of that machine alerts" watch-b-example-org 0
ok; sends 'to: watch-b-example-org'; marked 203.0.113.10

story
alert "a name the table does not list alerts with the body as it came, and marks nothing" watch-z-example-com 0
ok; sends 'to: watch-z-example-com'; sends 'the body'
! grep -qF 'Other names' <<< "$sent" || bad "added the line about other names"
[ ! -e "$marks" ] || bad "wrote marks"
alert "and alerts again" watch-z-example-com 1
ok; sends 'to: watch-z-example-com'

story
mkdir -p "$marks" && echo garbage > "$marks/203.0.113.10"
alert "a mark that holds no time does not keep a machine quiet" watch-a-example-org 0
ok; sends 'to: watch-a-example-org'

finish
echo "$((cases - failures)) of $cases cases pass"
[ "$failures" -eq 0 ]
