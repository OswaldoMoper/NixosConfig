# The deploy gate and its four guards

`deploy-gate.sh` orchestrates; `freshness-guard.sh`, `cache-guard.sh`, `access-guard.sh` and `live-checks.sh` each answer one question. They are generated per node by `lib.mkPreDeployApps`, so a consuming flake gets `deploy-<node>` and the guards individually.

## The gate — `deploy-gate.sh`

```bash
nix run .#deploy-myNode
```

| # | Step | Blocks? |
| --- | --- | --- |
| 1 | is this checkout behind its upstream, and is the tree dirty | findings warn; **exit 2 blocks** |
| 2 | binary caches on the machine that will **build** | only if a human answers "abort" |
| 3 | `nix flake check` | yes |
| 4 | live preconditions | yes |
| 5 | build the toplevel locally | yes |
| 6 | ssh access this deploy would remove | a finding warns; **exit 2 blocks** |
| 7 | deploy | exit code **recorded, not obeyed** |
| 8 | verify the result | yes |

### Three decisions that are easy to misread

**Step 1 asks the remote, and only a failed fetch stops it.** Not a git checkout, or a branch with no upstream, are facts the operator chose and can see: they warn. A fetch that fails is different — it is "I could not ask whether this tree is stale", which is the state that lets a stale tree through believing it was checked. Same shape as the access guard's exit 2.

It compares with `git merge-base --is-ancestor "$upstream" HEAD`, so **local commits you have not pushed pass**. Only commits the remote has and you lack are a finding. The dirty check ignores untracked files on purpose: a dirty git flake deploys the working tree, but untracked files never reach a closure.

**Step 5 builds before touching the machine.** An evaluation or build error should never reach the target, and the built path is what step 8 compares against.

**Step 7 does not trust deploy-rs.** It reports failure on activations that finished — a benign non-zero from a per-user unit reload is enough. So the exit code is recorded and the gate asks the machine directly instead: does `/run/current-system` equal what we built, and does it verify clean? The first question is what distinguishes a false positive from a real rollback. `verify` alone cannot, because the previous generation has its units up too.

### `GATE_SSH_USER`

```bash
GATE_SSH_USER=someone nix run .#deploy-myNode
```

Makes every step **and** the deploy connect as that person rather than the node's declared `sshUser`. One name has to reach the guards and deploy alike, or the live preconditions fail as themselves before the deploy is attempted.

### `GATE_SSH_CONFIG`

```bash
GATE_SSH_CONFIG=$HOME/.ssh/config nix run .#deploy-myNode
```

Same fan-out for an ssh config file: the guards run their own `ssh`, so a path only deploy-rs knows about leaves them failing as if the host were unreachable. It becomes `-F <path>` for the guards and `--ssh-opts` for deploy-rs, added first so an explicit `--ssh-opts` from the caller still wins.

It exists for CI. OpenSSH resolves `~/.ssh` from the account's home **in passwd** — `/var/empty` for a runner's system user — not from the job's `HOME`, so without it a runner's key is invisible to every guard.

### `GATE_SKIP_PREFLIGHT=1`

An explicit escape, because a gate without one gets bypassed by hand and stops being a gate. It exists for a known-intentional precondition mismatch. Whoever uses it next owes a reason.

---

## `cache-guard.sh` — caches on the machine that builds

deploy-rs builds **where you run it**, not on the target. So the caches that matter are the ones on this machine, not the ones the server declares — without them the first deploy compiles GHC from source, which on a normal machine does not finish.

It reads `nix config show`, so it is entirely local: no ssh, and it works unchanged when run on the box itself.

When something is missing it asks **one question with three outcomes**: configure them now, continue without, or abort. Only "abort" stops the deploy.

Configuring writes `~/.config/nix/nix.conf` and keeps a `.cache-guard-backup` beside it. This is why it is the one guard that should not run unattended on a server.

## `access-guard.sh` — logins this deploy would take away

Diffs the closure's `authorized_keys.d` against the running host's, and reports what would disappear.

**A finding warns and never blocks.** A deliberate revocation should not need a flag, and this must never be the reason an urgent deploy cannot go out. It is a **no-regression** check, not a completeness one: adding access always passes, so recovering from a botched deploy sails through.

Two things do stop it, and both mean *the check did not run*:

| Exit | Meaning |
| --- | --- |
| 0 | either nothing would be removed, or the host is unreachable — the first deploy of a machine that is not up yet |
| 1 | the closure has no authorized keys at all, which cannot be right |
| **2** | **it never looked**: reachable but could not authenticate, or the live side listed nothing |

Exit 2 exists because skipping was also exit 0, so a passphrase-locked key with no agent quietly retired the one check that stops a lockout — while reporting "cannot reach", which is what guarantees nobody investigates.

**Blind spot worth knowing:** it only reads `authorized_keys.d`, so a key someone put in their own
`~/.ssh/authorized_keys` is invisible here — and is, usefully, an escape hatch no deploy can revoke.

## `live-checks.sh` — the machine as it is, and as it became

Two modes over one script.

**`pre-deploy`** — true of the machine as it stands, so it blocks:

- reachable over ssh
- **on a host that declares a database**, the PostgreSQL major matches the pin — and *which way* a mismatch hurts (a data dir already holding another major is a different problem from an empty one) — and the data dir exists

The database half is conditional on purpose. A host whose whole job is to run a CI runner has no
Postgres at all, so asserting a major there would make it undeployable.

**`verify`** — only true *after* a deploy, so asserting it before would block the very deploy meant
to create it:

- every declared unit is active — home-manager units included, and the CI runner on a host whose whole job is to run one, which otherwise verifies clean while the only thing it exists for is dead
- every declared database exists and has tables
- every declared role exists and owns its database
- **collation drift**: a database built under an older glibc than the one now installed. This
  **warns without failing** — the fix is a `REINDEX` in a quiet window, and blocking every future
  deploy until someone schedules one helps nobody

### `BatchMode`, and its second failure mode

Every ssh call uses `-o BatchMode=yes`, so a missing key cannot turn a pipeline into a hanging password prompt.

The cost is that a **passphrase-locked key with no agent loaded** fails here while working perfectly interactively. The script distinguishes that from unreachability and says so, because the two look identical otherwise:

```text
reached user@host, but could not authenticate without a prompt
BatchMode is on here, so a passphrase-locked key needs an agent:
  eval "$(ssh-agent -s)" && ssh-add
```

fail2ban answers a ban with a reject, so **a ban and a dead host really are indistinguishable** from here. An authentication failure is not, and now says which it was.
