# Checks that the machine about to BUILD has the binary caches the closure needs.
#
# deploy-rs builds where you run it, not on the target, so the caches that matter
# here are the ones on this laptop -- not the ones the server declares. Without
# them the first deploy compiles GHC from source, which on a normal machine does
# not finish.
#
# The required list comes from the host's own nix.settings, so there is one
# declaration driving both the server's config and this check.
#
# It never blocks on its own: with no terminal it warns and carries on, which is
# what a CI runner needs. Only a human choosing "abort" stops the deploy.
export LC_ALL=C

read -r -a required <<< "${CACHE_SUBSTITUTERS:-}"
read -r -a required_keys <<< "${CACHE_KEYS:-}"
[ "${#required[@]}" -gt 0 ] || exit 0

active="$(nix config show substituters 2>/dev/null || true)"

missing=()
for s in "${required[@]}"; do
  found=0
  for a in $active; do
    # Trailing slashes are cosmetic to Nix but not to a string compare.
    [ "${a%/}" = "${s%/}" ] && found=1 && break
  done
  [ "$found" = 1 ] || missing+=("$s")
done

if [ "${#missing[@]}" -eq 0 ]; then
  printf 'cache-guard: your Nix configuration has every cache this build needs\n'
  exit 0
fi

# `substituters` is one of the settings Nix refuses to take from an untrusted
# user, so offering to write a config file they cannot use would be a lie.
can_fix() {
  [ "$(id -u)" = 0 ] && return 0
  local me groups t
  me="$(id -un)"
  groups="$(id -nG)"
  for t in $(nix config show trusted-users 2>/dev/null || true); do
    case "$t" in
      "$me") return 0 ;;
      @*)
        for g in $groups; do
          [ "$g" = "${t#@}" ] && return 0
        done
        ;;
    esac
  done
  return 1
}

conf="${XDG_CONFIG_HOME:-$HOME/.config}/nix/nix.conf"

# A repeated key in nix.conf overrides rather than accumulates, so appending
# blindly would silently drop whatever the user already had.
merge_setting() {
  local key=$1 add=$2
  if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$conf"; then
    awk -v k="$key" -v add="$add" '
      $0 ~ "^[[:space:]]*" k "[[:space:]]*=" && !done {
        sub(/^[^=]*=[[:space:]]*/, "")
        printf "%s = %s %s\n", k, $0, add
        done = 1
        next
      }
      { print }
    ' "$conf" > "$conf.tmp"
    mv "$conf.tmp" "$conf"
  else
    printf '%s = %s\n' "$key" "$add" >> "$conf"
  fi
}

configure() {
  mkdir -p "$(dirname "$conf")"
  touch "$conf"
  cp "$conf" "$conf.redacted-backup"
  merge_setting extra-substituters "${missing[*]}"
  merge_setting extra-trusted-public-keys "${required_keys[*]}"
  printf '\n  wrote %s (previous contents kept as %s.redacted-backup)\n' "$conf" "$conf"
  if [ -n "$(nix config show substituters 2>/dev/null | grep -oF "${missing[0]}" || true)" ]; then
    printf '  caches are active now\n\n'
  else
    printf '  Nix still does not report them; check %s by hand\n\n' "$conf"
  fi
}

printf '\ncache-guard: your Nix configuration is missing %d cache(s) this build needs\n\n' "${#missing[@]}" >&2
for s in "${missing[@]}"; do printf '  %s\n' "$s" >&2; done
printf '\n  Building without them compiles the Haskell toolchain from source.\n' >&2
printf '  That is hours of CPU, and on a laptop it may not finish at all.\n\n' >&2
printf '  This flake declares them too, but Nix only takes a cache from a flake\n' >&2
printf '  once you accept it, and never for a user outside trusted-users. Your\n' >&2
printf '  own nix.conf is the one place that always works.\n\n' >&2

if [ ! -t 0 ] || [ ! -t 1 ]; then
  printf '  No terminal to ask, so carrying on without them.\n' >&2
  printf '  To fix it for next time, add to %s:\n\n' "$conf" >&2
  printf '    extra-substituters = %s\n' "${missing[*]}" >&2
  printf '    extra-trusted-public-keys = %s\n\n' "${required_keys[*]}" >&2
  exit 0
fi

if can_fix; then
  printf '  [c] configure them in %s and continue\n' "$conf" >&2
  printf '  [s] skip, build without them\n' >&2
  printf '  [a] abort\n\n' >&2
  read -r -p "  choice [c/s/a]: " answer
  case "$answer" in
    c | C) configure ;;
    a | A) printf '\n  aborted, nothing was deployed\n' >&2; exit 1 ;;
    *) printf '\n  carrying on without them\n' >&2 ;;
  esac
else
  # Not in trusted-users: nothing this script writes as this user would be read.
  printf '  You are not in trusted-users, so Nix would ignore any cache you add\n' >&2
  printf '  as this user. Someone with root has to put this in /etc/nix/nix.conf:\n\n' >&2
  printf '    extra-substituters = %s\n' "${missing[*]}" >&2
  printf '    extra-trusted-public-keys = %s\n\n' "${required_keys[*]}" >&2
  printf '  [s] skip, build without them\n' >&2
  printf '  [a] abort\n\n' >&2
  read -r -p "  choice [s/a]: " answer
  case "$answer" in
    a | A) printf '\n  aborted, nothing was deployed\n' >&2; exit 1 ;;
    *) printf '\n  carrying on without them\n' >&2 ;;
  esac
fi
