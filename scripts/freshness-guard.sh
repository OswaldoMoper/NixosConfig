warn() { printf '%s\n' "$*" >&2; }

# Two questions, and only one of them can stop a deploy: is this checkout
# missing commits the remote has, and does it have uncommitted changes.
#
# Deploying a tree that is behind its remote reverts whatever those commits
# changed -- accounts, keys, services -- and nothing inside the flake can
# notice, because a stale tree's own checks are stale too.

if ! git -C "$FRESH_FLAKE" rev-parse --git-dir >/dev/null 2>&1; then
  warn "fresh: ${FRESH_FLAKE} is not a git checkout, so freshness cannot be checked"
  exit 0
fi

git() { command git -C "$FRESH_FLAKE" "$@"; }

upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"

if [ -z "$upstream" ]; then
  warn "fresh: this branch tracks no upstream, so freshness cannot be checked"
else
  # A failed fetch is the one case that blocks. It is not "there is nothing to
  # report", it is "I could not ask" -- which is exactly the state that lets a
  # stale tree through believing it was checked.
  if ! git fetch --quiet "${upstream%%/*}" 2>/dev/null; then
    warn "fresh: could not fetch ${upstream%%/*}, so it is unknown whether this checkout is behind"
    exit 2
  fi

  # --is-ancestor is "HEAD is $upstream or a descendant of it", so local commits
  # that are not pushed yet pass, and only genuinely missing ones warn.
  if ! git merge-base --is-ancestor "$upstream" HEAD; then
    warn ""
    warn "fresh: HEAD is MISSING commits that $upstream has."
    warn "Deploying reverts whatever they changed -- accounts, keys, services --"
    warn "on the live host. Missing:"
    git --no-pager log --oneline "HEAD..$upstream" >&2
    warn ""
    warn "  fix with:  git -C ${FRESH_FLAKE} pull --ff-only"
    warn ""
  fi
fi

# A dirty tree IS what gets deployed: nix copies the working tree for a dirty
# git flake. Untracked files are ignored on purpose -- result, VM images and the
# untracked docs live here and none of them reach a closure.
dirty="$(git status --porcelain --untracked-files=no)"
if [ -n "$dirty" ]; then
  warn "fresh: deploying uncommitted changes:"
  printf '%s\n' "$dirty" >&2
fi

exit 0
