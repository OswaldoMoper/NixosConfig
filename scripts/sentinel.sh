#!/usr/bin/env bash
# One sentinel pass: report what this machine has not shown before, mail it, and
# learn it only once the mail went out.
#
#   sentinel.sh <state dir> <file of versioned globs, one per line>
#
# SENTINEL_MAIL is run with the report on stdin when there is one. SENTINEL_ROOT
# prefixes /proc, /tmp, /var/tmp and /dev/shm, and SENTINEL_SYSTEM names the
# system whose closure is verified; both exist for the tests.
set -uo pipefail

state=$1
versioned=$2
root=${SENTINEL_ROOT:-}
system=${SENTINEL_SYSTEM:-/run/current-system}
known=$state/known
mkdir -p "$state"
touch "$known"
# The first pass reports everything, versioned or not.
first=1
[ -s "$known" ] && first=0

started=$(date -u '+%Y-%m-%d %H:%M:%S')
report=$(mktemp)
learn=$(mktemp)
trap 'rm -f "$report" "$learn"' EXIT

# known holds one "kind<TAB>key<TAB>sha256" per line; the hash is empty for
# what has no content of its own.
known_hash() { awk -F'\t' -v k="$1" -v x="$2" '$1 == k && $2 == x { print $3; f = 1 } END { exit !f }' "$known"; }

is_versioned() {
  local g
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    # shellcheck disable=SC2053
    [[ $1 == $g ]] && return 0
  done < "$versioned"
  return 1
}

seen() {
  local kind=$1 key=$2 hash=${3:-} what=$4 old
  awk -F'\t' -v k="$kind" -v x="$key" '$1 == k && $2 == x { f = 1 } END { exit !f }' "$learn" && return
  if old=$(known_hash "$kind" "$key"); then
    if [ "$old" != "$hash" ]; then
      echo "changed $what: $key (sha256 $old -> $hash)" >> "$report"
      printf '%s\t%s\t%s\n' "$kind" "$key" "$hash" >> "$learn"
    fi
  elif [ "$first" = 0 ] && [ "$kind" != ssh-key ] && [ "$kind" != ssh-net ] && is_versioned "$key"; then
    printf '%s\t%s\t%s\n' "$kind" "$key" "$hash" >> "$learn"
  else
    echo "new $what: $key${hash:+ (sha256 $hash)}" >> "$report"
    printf '%s\t%s\t%s\n' "$kind" "$key" "$hash" >> "$learn"
  fi
}

network() {
  case $1 in
    *:*) echo "$1" | awk -F: '{ print $1 ":" $2 "::/32" }' ;;
    *) echo "$1" | awk -F. '{ print $1 "." $2 ".0.0/16" }' ;;
  esac
}

since=()
[ -s "$state/since" ] && since=(--since "$(cat "$state/since")")

journalctl -q --no-pager -u sshd "${since[@]}" 2>/dev/null > "$state/.journal" || true
while read -r user addr fp; do
  seen ssh-key "$user $fp" "" "ssh key"
  seen ssh-net "$user $(network "$addr")" "" "ssh network"
done < <(sed -nE 's/.*Accepted publickey for ([^ ]+) from ([^ ]+) port [0-9]+ ssh2: [^ ]+ ([^ ]+).*/\1 \2 \3/p' "$state/.journal" | sort -u)
sed -nE 's/.*Accepted key [^ ]+ ([^ ]+) found at ([^ ]+).*/\2 \1/p' "$state/.journal" | sort -u |
  while read -r file fp; do
    case $file in
      /etc/ssh/authorized_keys.d/*) ;;
      *) echo "ssh key accepted from outside /etc/ssh/authorized_keys.d: $file $fp" >> "$report" ;;
    esac
  done
rm -f "$state/.journal"

for p in "$root"/proc/[0-9]*; do
  exe=$(readlink "$p/exe" 2>/dev/null) || continue
  case $exe in /nix/store/*) continue ;; esac
  seen proc "${exe#"$root"}" "$(sha256sum < "$p/exe" 2>/dev/null | cut -d' ' -f1)" "process outside the store"
done

mapfile -t units < <(systemctl list-units --all --no-legend --plain --no-pager 2>/dev/null | awk '{ print $1 }')
if [ "${#units[@]}" -gt 0 ]; then
  while read -r id fragment; do
    real=$(readlink -f "$root$fragment" 2>/dev/null || echo "$fragment")
    case $real in /nix/store/*) continue ;; esac
    seen unit "$id $fragment" "$(sha256sum < "$root$fragment" 2>/dev/null | cut -d' ' -f1)" "unit outside the store"
  done < <(systemctl show -p Id -p FragmentPath "${units[@]}" 2>/dev/null |
    awk -F= '$1 == "Id" { id = $2 } $1 == "FragmentPath" && $2 != "" { print id, $2 }')
fi

while IFS= read -r -d '' f; do
  seen file "${f#"$root"}" "$(sha256sum < "$f" | cut -d' ' -f1)" "executable in a temporary directory"
done < <(find "$root/tmp" "$root/var/tmp" "$root/dev/shm" -xdev -type f -perm /111 -print0 2>/dev/null)

nix-store -qR "$system" 2>/dev/null | xargs -r -n 200 nix-store --verify-path 2>&1 >/dev/null |
  grep -o "/nix/store/[^' ]*" | sort -u | while read -r bad; do seen store "$bad" "" "store path whose content fails its hash"; done

if [ -s "$report" ]; then
  { echo "$(uname -n) at $started UTC:"; echo; cat "$report"; } | eval "${SENTINEL_MAIL:?}" || exit 1
fi
awk -F'\t' 'FILENAME == ARGV[1] { n[$1 FS $2] = $0; next } !(($1 FS $2) in n) { print } END { for (k in n) print n[k] }' \
  "$learn" "$known" > "$known.new" && mv "$known.new" "$known"
echo "$started UTC" > "$state/since"
