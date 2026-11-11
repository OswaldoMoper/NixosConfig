#!/usr/bin/env bash
# Runs an alert command for a watched name, unless another name on the same
# machine alerted within the window: then it logs a line and sends nothing.
#
#   watch-alert.sh TABLE MARKS WINDOW COMMAND
#
# TABLE holds one "name machine" line per watched name, MARKS is a directory
# this can write, WINDOW is in seconds and COMMAND is an executable. The name
# comes in CATTLE_APP and the alert's body on standard input. A name the table
# does not list always alerts. The machine is marked only when COMMAND exits 0,
# and COMMAND's failure is this script's.
set -euo pipefail

table="$1" marks="$2" window="$3" command="$4"
logger="${WATCH_ALERT_LOGGER:-logger}"
now="${WATCH_ALERT_NOW:-$(date +%s)}"

machine=""
while read -r name address; do
  if [ "$name" = "${CATTLE_APP:-}" ]; then
    machine="$address"
    break
  fi
done < "$table"

[ -n "$machine" ] || exec "$command"

mark="$marks/${machine//\//_}"
since=0
if [ -f "$mark" ]; then
  read -r since < "$mark" || true
  [[ "$since" =~ ^[0-9]+$ ]] || since=0
fi

if [ $((now - since)) -lt "$window" ]; then
  "$logger" -t watch-alert -- \
    "$CATTLE_APP: no alert sent, $machine alerted at $(date -u -d "@$since" '+%H:%M UTC') and stays quiet until $(date -u -d "@$((since + window))" '+%H:%M UTC')"
  exit 0
fi

{
  cat
  printf '\nOther names on %s that fail before %s send no alert of their own.\n' \
    "$machine" "$(date -u -d "@$((now + window))" '+%H:%M UTC')"
} | "$command"

mkdir -p "$marks"
printf '%s\n' "$now" > "$mark"
