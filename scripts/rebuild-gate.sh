step() { printf '\n=== %s\n' "$1"; }

mode="${1:-switch}"
case "$mode" in
  switch | boot | test | dry-activate) shift || true ;;
  -*) mode="switch" ;;
  *)
    printf 'usage: rebuild-<host> [switch|boot|test|dry-activate] [nixos-rebuild args...]\n' >&2
    exit 2
    ;;
esac

printf 'rebuild gate for %s (%s, flake %s)\n' "$GATE_HOST" "$mode" "$GATE_FLAKE"

# The whole reason this is a second gate rather than a flag on the first: the
# guards are the same, the interaction is not. `test` activates without touching
# the boot entry, which is the mode a rescue wants and one a deploy cannot
# express -- and it means step 7 has to ask what actually happened rather than
# assume a switch.
export LIVE_LOCAL=1 ACCESS_LOCAL=1

# Run this with sudo, like nixos-rebuild itself. The dump then goes to the
# invoking person's home rather than root's, which is where they will look for
# it, and postgres is reached with runuser because there is no user to escalate
# from any more.
rebuild_user="${SUDO_USER:-$USER}"
rebuild_home="$(getent passwd "$rebuild_user" | cut -d: -f6)"
if [ -z "$rebuild_home" ] || [ ! -d "$rebuild_home" ]; then
  printf 'no valid home for %s, so there is nowhere safe to put a dump\n' "$rebuild_user" >&2
  exit 1
fi
REBUILD_DUMP_LOCAL="${REBUILD_DUMP_LOCAL:-${rebuild_home}/postgres_backup_${GATE_HOST}.sql}"

local_major() {
  local num
  num="$(runuser -u postgres -- psql -tAc 'SHOW server_version_num' 2>/dev/null | tr -d '[:space:]')"
  case "$num" in
    '' | *[!0-9]*) return 0 ;;
    *) printf '%s' "$((num / 10000))" ;;
  esac
}

step "1/8 is this checkout current"
fresh_rc=0
"$GATE_FRESH" || fresh_rc=$?
if [ "$fresh_rc" -eq 2 ]; then
  printf '\nnothing was rebuilt\n' >&2
  exit 1
fi

step "2/8 binary caches on this machine"
# Already local in the deploy gate too: it reads `nix config show` and never
# opens a connection. Here it is also the machine being rebuilt, which is why
# its offer to write ~/.config/nix/nix.conf deserves a thought before accepting.
"$GATE_CACHES" || {
  printf '\nnothing was rebuilt\n' >&2
  exit 1
}

step "3/8 pure checks"
nix flake check "$GATE_FLAKE" || {
  printf 'pure checks failed; nothing was rebuilt\n' >&2
  exit 1
}

step "4/8 live preconditions"
if [ "${GATE_SKIP_PREFLIGHT:-0}" = "1" ]; then
  printf 'SKIPPED because GATE_SKIP_PREFLIGHT=1\n' >&2
  printf 'you are rebuilding without checking the machine first\n' >&2
else
  "$GATE_PRE_DEPLOY" || {
    printf '\nlive preconditions failed; nothing was rebuilt\n' >&2
    printf 'if this is deliberate, re-run with GATE_SKIP_PREFLIGHT=1\n' >&2
    exit 1
  }
fi

step "5/8 build the toplevel"
built="$(nix build --no-link --print-out-paths \
  "${GATE_FLAKE}#nixosConfigurations.${GATE_HOST}.config.system.build.toplevel")" || {
  printf 'build failed; nothing was rebuilt\n' >&2
  exit 1
}

step "6/8 ssh access this rebuild would remove"
# Activation rewrites /etc here exactly as it does over a deploy, so an account
# that stops being declared loses its keys the same way -- and locking yourself
# out of the machine you are sitting at is only better because you are sitting
# at it.
access_rc=0
"$GATE_ACCESS" "$built" || access_rc=$?
if [ "$access_rc" -eq 2 ]; then
  printf '\nnothing was rebuilt\n' >&2
  exit 1
fi

migrate_before=""
if [ "${REBUILD_MIGRATE:-0}" = "1" ]; then
  step "6b/8 dump before migrating"
  migrate_before="$(local_major)"
  if [ -z "$migrate_before" ]; then
    printf 'could not read the postgres version; nothing was rebuilt\n' >&2
    exit 1
  fi
  printf '  server_version_num before: %s\n' "$migrate_before"

  runuser -u postgres -- pg_dumpall > "$REBUILD_DUMP_LOCAL" || {
    printf 'dump failed; nothing was rebuilt\n' >&2
    exit 1
  }
  if ! grep -q 'PostgreSQL database dump' "$REBUILD_DUMP_LOCAL"; then
    printf '%s does not look like pg_dumpall output; nothing was rebuilt\n' "$REBUILD_DUMP_LOCAL" >&2
    exit 1
  fi
  printf '  dumped to %s (%s bytes)\n' "$REBUILD_DUMP_LOCAL" "$(wc -c < "$REBUILD_DUMP_LOCAL")"
fi

step "7/8 nixos-rebuild ${mode}"
# Recorded, not obeyed -- the same lesson the deploy gate learned. Measured on
# 2026-08-29: switch-to-configuration exited 4 because one unit failed, the
# system had changed generation, and the wrapper announced "migration
# cancelled" having cancelled nothing, before it had even compared versions.
rebuild_rc=0
nixos-rebuild "$mode" --flake "${GATE_FLAKE}#${GATE_HOST}" "$@" || rebuild_rc=$?

if [ "${REBUILD_MIGRATE:-0}" = "1" ]; then
  step "7b/8 restore if the major moved"
  migrate_after="$(local_major)"
  if [ -z "$migrate_after" ]; then
    printf 'could not read the postgres version after the rebuild\n' >&2
    printf 'the dump is at %s; nothing was restored\n' "$REBUILD_DUMP_LOCAL" >&2
    exit 1
  fi
  if [ "$migrate_after" -le "$migrate_before" ]; then
    printf '  %s -> %s: unchanged or lower, nothing to restore\n' "$migrate_before" "$migrate_after"
  else
    printf '  %s -> %s: restoring into the fresh cluster\n' "$migrate_before" "$migrate_after"
    runuser -u postgres -- psql postgres < "$REBUILD_DUMP_LOCAL" || {
      printf 'restore failed. The dump is at %s\n' "$REBUILD_DUMP_LOCAL" >&2
      exit 1
    }
  fi
  printf '  dump kept at %s\n' "$REBUILD_DUMP_LOCAL"
fi

step "8/8 verify the result"
# dry-activate changed nothing by definition, and `boot` deliberately leaves the
# running system alone, so neither can be held to what a switch produces.
case "$mode" in
  dry-activate)
    printf 'dry-activate changed nothing, so there is nothing to verify\n'
    exit "$rebuild_rc"
    ;;
  boot)
    printf 'boot staged %s for the next start; the running system is unchanged\n' "$built"
    [ "$rebuild_rc" -eq 0 ] || printf 'nixos-rebuild exited %s\n' "$rebuild_rc" >&2
    exit "$rebuild_rc"
    ;;
esac

live="$(readlink -f /run/current-system 2>/dev/null || true)"
if [ "$live" != "$built" ]; then
  printf '\nthis machine is NOT running what we built\n' >&2
  printf '  built: %s\n' "$built" >&2
  printf '  live:  %s\n' "${live:-<unreadable>}" >&2
  [ "$rebuild_rc" -eq 0 ] || printf '  nixos-rebuild exited %s\n' "$rebuild_rc" >&2
  exit 1
fi

if ! "$GATE_VERIFY"; then
  printf '\nthis machine runs the new closure but does not verify clean\n' >&2
  exit 1
fi

if [ "$rebuild_rc" -ne 0 ]; then
  printf '\nnixos-rebuild exited %s, but this machine runs the closure we built\n' "$rebuild_rc" >&2
  printf 'and verifies clean. Read the activation log for a per-user warning\n' >&2
  printf 'before believing the exit code.\n' >&2
fi

printf '\nrebuild gate passed for %s\n' "$GATE_HOST"
