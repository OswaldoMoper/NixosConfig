step() { printf '\n=== %s\n' "$1"; }

printf 'deploy gate for %s (flake %s)\n' "$GATE_NODE" "$GATE_FLAKE"

step "1/6 pure checks"
nix flake check "$GATE_FLAKE" || {
  printf 'pure checks failed; nothing was deployed\n' >&2
  exit 1
}

step "2/6 live preconditions"
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

step "3/6 build the toplevel"
# Building here rather than letting deploy do it keeps an evaluation error from
# reaching the machine at all. --print-out-paths because the next step needs the
# closure to compare against the live host.
built="$(nix build --no-link --print-out-paths \
  "${GATE_FLAKE}#nixosConfigurations.${GATE_HOST}.config.system.build.toplevel")" || {
  printf 'build failed; nothing was deployed\n' >&2
  exit 1
}

step "4/6 ssh access this deploy would remove"
# Warns, never blocks: a deliberate revocation should not need a flag, and this
# must never be the reason an urgent deploy cannot go out.
"$GATE_ACCESS" "$built" || true

step "5/6 deploy"
deploy "${GATE_FLAKE}#${GATE_NODE}" || {
  printf 'deploy failed; run the verify app to see what state the host is in\n' >&2
  exit 1
}

step "6/6 verify the result"
"$GATE_VERIFY" || {
  printf '\ndeploy activated but the host does not look right yet\n' >&2
  exit 1
}

printf '\ndeploy gate passed for %s\n' "$GATE_NODE"
