warn() { printf '%s\n' "$*" >&2; }

# Which inputs of the flake moved since the revision the machine runs, and
# whether whoever deploys said so. An application input that moved without
# being named in GATE_PIN_OK stops the deploy; any other input that moved is
# reported. Exit 2 means the question could not be asked, which is not the same
# as nothing having moved.

if [ -z "${PINS_APPS:-}" ]; then
  printf 'pins: this node names no application inputs, nothing to compare\n'
  exit 0
fi

ssh_cfg=()
if [ -n "${PINS_SSH_CONFIG:-}" ]; then
  ssh_cfg=(-F "$PINS_SSH_CONFIG")
fi

rev="$(ssh ${ssh_cfg[@]+"${ssh_cfg[@]}"} -o BatchMode=yes -o ConnectTimeout=10 \
  "${PINS_SSH_USER}@${PINS_HOST}" nixos-version --configuration-revision 2>/dev/null || true)"
if [ -z "$rev" ]; then
  warn "pins: ${PINS_HOST} did not say which revision it runs (unreachable, or deployed from a"
  warn "dirty tree, which records none), so what moved since then is unknown"
  exit 2
fi

git() { command git -C "$PINS_FLAKE" "$@"; }

prefix="$(git rev-parse --show-prefix 2>/dev/null || true)"
deployed="$(git show "${rev}:${prefix}flake.lock" 2>/dev/null || true)"
if [ -z "$deployed" ]; then
  warn "pins: ${PINS_HOST} runs ${rev}, which this checkout does not have (git fetch?)"
  exit 2
fi

# The locked revision an input of the root resolves to, or its narHash for an
# input without one. A follows (a list) is not an input of its own.
locked() {
  jq -r --arg n "$1" '
    .nodes.root.inputs[$n] as $k
    | if ($k | type) == "string" then (.nodes[$k].locked | .rev // .narHash) else empty end
  '
}

inputs="$(jq -r '.nodes.root.inputs | keys[]' "${PINS_FLAKE}/flake.lock")"
read -r -a apps <<< "$PINS_APPS"
read -r -a named <<< "${GATE_PIN_OK:-}"

for a in "${apps[@]}"; do
  if ! printf '%s\n' "$inputs" | grep -qx -- "$a"; then
    warn "pins: ${a} is declared an application input but the flake has no input by that name"
    exit 2
  fi
done

is_in() {
  local x="$1"; shift
  local y
  for y in "$@"; do [ "$x" = "$y" ] && return 0; done
  return 1
}

stop=0
while IFS= read -r input; do
  before="$(printf '%s' "$deployed" | locked "$input")"
  after="$(locked "$input" < "${PINS_FLAKE}/flake.lock")"
  [ "$before" = "$after" ] && continue

  if is_in "$input" "${apps[@]}"; then
    if is_in "$input" ${named[@]+"${named[@]}"}; then
      printf 'pins: %s moves %s -> %s, named in GATE_PIN_OK\n' "$input" "${before:-new}" "$after"
    else
      warn "pins: application input ${input} moves ${before:-new} -> ${after}, and GATE_PIN_OK does not name it"
      stop=1
    fi
  else
    printf 'pins: %s moves %s -> %s\n' "$input" "${before:-new}" "$after"
  fi
done <<< "$inputs"

if [ "$stop" -eq 1 ]; then
  warn ""
  warn "An application moves in its own deploy. If this one is that deploy, say so:"
  warn "  GATE_PIN_OK='<input> ...' deploy-${PINS_NODE}"
  warn "If it is not, put the pin back to what ${rev} has before deploying."
  exit 1
fi

printf 'pins: compared against %s, the revision %s runs\n' "$rev" "$PINS_HOST"
exit 0
