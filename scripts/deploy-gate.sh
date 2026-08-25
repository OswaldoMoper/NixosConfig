step() { printf '\n=== %s\n' "$1"; }

printf 'deploy gate for %s (flake %s)\n' "$GATE_NODE" "$GATE_FLAKE"

# The node's declared sshUser is root or admin, and neither belongs to whoever
# is deploying today. One name has to reach the guards and deploy alike, or the
# live preconditions fail as themselves before the deploy is even attempted.
if [ -n "${GATE_SSH_USER:-}" ]; then
  export LIVE_SSH_USER="$GATE_SSH_USER"
  export ACCESS_SSH_USER="$GATE_SSH_USER"
  set -- --ssh-user "$GATE_SSH_USER" "$@"
fi

step "1/7 binary caches on this machine"
# Only a human answering "abort" makes this stop.
"$GATE_CACHES" || {
  printf '\nnothing was deployed\n' >&2
  exit 1
}

step "2/7 pure checks"
nix flake check "$GATE_FLAKE" || {
  printf 'pure checks failed; nothing was deployed\n' >&2
  exit 1
}

step "3/7 live preconditions"
# The gate has to be overridable or it gets bypassed by hand, which is worse:
# the recovery deploy for a host whose Postgres major moved is exactly the case
# where a human has to look and decide.
if [ "${GATE_SKIP_PREFLIGHT:-0}" = "1" ]; then
  printf 'SKIPPED because GATE_SKIP_PREFLIGHT=1\n' >&2
  printf 'you are deploying without checking the machine first\n' >&2
else
  "$GATE_PRE_DEPLOY" || {
    printf '\nlive preconditions failed; nothing was deployed\n' >&2
    printf 'if this is deliberate, re-run with GATE_SKIP_PREFLIGHT=1\n' >&2
    exit 1
  }
fi

step "4/7 build the toplevel"
# Building here rather than letting deploy do it keeps an evaluation error from
# reaching the machine at all. --print-out-paths because the next step needs the
# closure to compare against the live host.
built="$(nix build --no-link --print-out-paths \
  "${GATE_FLAKE}#nixosConfigurations.${GATE_HOST}.config.system.build.toplevel")" || {
  printf 'build failed; nothing was deployed\n' >&2
  exit 1
}

step "5/7 ssh access this deploy would remove"
# Warns, never blocks: a deliberate revocation should not need a flag, and this
# must never be the reason an urgent deploy cannot go out.
"$GATE_ACCESS" "$built" || true

step "6/7 deploy"
# The exit code is recorded, not obeyed. Measured on 2026-08-25: a per-user
# activation warning for an account this deploy had just removed made deploy-rs
# report failure and attempt a revoke, while the machine finished activating and
# came up clean. Aborting here left the operator believing a successful deploy
# had failed, with step 7 never run.
deploy_rc=0
deploy "${GATE_FLAKE}#${GATE_NODE}" "$@" || deploy_rc=$?

step "7/7 verify the result"
# The machine is the authority. Two questions, in order: is it running the exact
# closure we built, and does it work? The first is what tells a false alarm apart
# from a real rollback -- verify alone cannot, because the previous generation
# also has its units up.
live="$(ssh -o BatchMode=yes -o ConnectTimeout=10 \
  "${GATE_HOST_USER}@${GATE_HOST_ADDR}" readlink -f /run/current-system 2>/dev/null || true)"

if [ "$live" != "$built" ]; then
  printf '\nthe host is NOT running what we built\n' >&2
  printf '  built: %s\n' "$built" >&2
  printf '  live:  %s\n' "${live:-<unreachable>}" >&2
  [ "$deploy_rc" -eq 0 ] || printf '  deploy exited %s\n' "$deploy_rc" >&2
  exit 1
fi

if ! "$GATE_VERIFY"; then
  printf '\nthe host runs the new closure but does not verify clean\n' >&2
  exit 1
fi

if [ "$deploy_rc" -ne 0 ]; then
  printf '\ndeploy exited %s, but the host runs the closure we built and verifies\n' "$deploy_rc" >&2
  printf 'clean. Read the activation log for a per-user warning before believing\n' >&2
  printf 'the exit code -- see HALLAZGOS on the 2026-07-07 rollback.\n' >&2
fi

printf '\ndeploy gate passed for %s\n' "$GATE_NODE"
