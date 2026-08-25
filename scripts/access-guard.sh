# Reports the ssh access a deploy would take away, by diffing the closure's
# authorized_keys.d against the running host's.
#
# It warns, it never blocks. A deliberate revocation should not need a flag, and
# this must never be the reason an urgent deploy cannot go out. It is a
# no-regression check, not a completeness one: adding access always passes, so
# recovering from a botched deploy sails through.
#
# Blind spot worth knowing: it only reads authorized_keys.d, so a key someone put
# in their own ~/.ssh/authorized_keys is invisible here -- and is, usefully, an
# escape hatch no deploy can revoke.
export LC_ALL=C

built="${1:-}"
if [ -z "$built" ]; then
  echo "usage: access-guard <system-toplevel>" >&2
  exit 2
fi

remote="${ACCESS_SSH_USER}@${ACCESS_HOST}"

# One lister, run against the closure locally and against /etc over ssh, so the
# two sides cannot drift apart. $1 is the etc root, and the .uid/.gid/.mode
# siblings are metadata rather than keys.
#
# Single-quoted on purpose: this is a program to ship to `sh`, not a string to
# expand here. LC_ALL=C is pinned INSIDE the snippet, not just in this script's
# environment: the remote half runs under the host's own locale, which collates
# mixed-case base64 differently from the C locale `comm` compares under. Without
# the pin, comm reports "input is not in sorted order" and invents a removal for
# every key whose ordering disagrees.
# shellcheck disable=SC2016
lister='
  for f in "$1"/ssh/authorized_keys.d/*; do
    case "$f" in *.uid|*.gid|*.mode) continue ;; esac
    [ -e "$f" ] || continue
    u=${f##*/}
    while read -r t k _; do
      case "$t" in "" | \#*) continue ;; esac
      printf "%s\t%s %s\n" "$u" "$t" "$k"
    done < "$f"
  done | LC_ALL=C sort -u
'

new_keys="$(printf '%s' "$lister" | sh -s -- "$built/etc")"
if [ -z "$new_keys" ]; then
  echo "access-guard: no authorized keys at all in $built -- refusing" >&2
  exit 1
fi

# On the very first deploy of a fresh machine the host is not up yet, so this
# leg fails; deploy that once directly and the guard applies from then on.
if ! live_keys="$(printf '%s' "$lister" | ssh -o BatchMode=yes -o ConnectTimeout=10 "$remote" "sh -s -- /etc" 2>/dev/null)"; then
  echo "access-guard: cannot reach $remote, skipping the comparison" >&2
  exit 0
fi

# Compared on (principal, keytype+base64) pairs, so the key COMMENT is dropped:
# relabelling a key is not a "removal", and removing a whole account shows up as
# every one of its pairs disappearing, which is exactly right.
removed="$(comm -23 <(printf '%s\n' "$live_keys") <(printf '%s\n' "$new_keys") || true)"

if [ -z "$removed" ]; then
  printf 'access-guard: %s keeps every ssh login it has today\n' "$ACCESS_NODE"
  exit 0
fi

printf '\naccess-guard: this deploy REMOVES ssh access on %s\n\n' "$ACCESS_NODE" >&2
printf '%s\n' "$removed" | while IFS="$(printf '\t')" read -r principal key; do
  printf '  %-14s %s...\n' "$principal" "$(printf '%s' "$key" | cut -c1-46)" >&2
done
printf '\n  Deliberate? Then carry on. Otherwise fix the config before deploying.\n\n' >&2
