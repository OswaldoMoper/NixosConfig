# The two gates and their guards

`freshness-guard.sh`, `pins-guard.sh`, `cache-guard.sh`, `access-guard.sh` and `live-checks.sh` each answer one question. Two scripts orchestrate them:

| | Generated | For |
| --- | --- | --- |
| `deploy-gate.sh` | `deploy-<node>`, per deploy node | changing a machine from somewhere else |
| `rebuild-gate.sh` | `rebuild-<host>`, per **host** | changing the machine you are on |

`lib.mkPreDeployApps` generates both, plus each guard individually. The rebuild one is keyed by host rather than node on purpose: a machine you rebuild on is one you are standing at, which is exactly the case that has no deploy node.

## The gate — `deploy-gate.sh`

```bash
nix run .#deploy-myNode
```

| # | Step | Blocks? |
| --- | --- | --- |
| 1 | is this checkout behind its upstream, and is the tree dirty | findings warn; **exit 2 blocks** |
| 1b | which inputs moved since the revision the machine runs | an application input nobody named, and **exit 2**, block |
| 2 | binary caches on the machine that will **build** | only if a human answers "abort" |
| 3 | the checks the node names, or `nix flake check` when it names none | yes |
| 4 | live preconditions | yes |
| 5 | build the toplevel locally | yes |
| 6 | ssh access this deploy would remove | a finding warns; **exit 2 blocks** |
| 7 | deploy | exit code **recorded, not obeyed** |
| 8 | verify the result | yes |

A node that declares a `backup` and a `census` gets four more actions inside those eight, as `6c`, `6d`, `8b` and `8c`; a node without a backup gets `6b` and `7b` with `GATE_MIGRATE=1`. See below.

### Three decisions that are easy to misread

**Step 1 asks the remote, and only a failed fetch stops it.** Not a git checkout, or a branch with no upstream, are facts the operator chose and can see: they warn. A fetch that fails is different — it is "I could not ask whether this tree is stale", which is the state that lets a stale tree through believing it was checked. Same shape as the access guard's exit 2.

It compares with `git merge-base --is-ancestor "$upstream" HEAD`, so **local commits you have not pushed pass**. Only commits the remote has and you lack are a finding. The dirty check ignores untracked files on purpose: a dirty git flake deploys the working tree, but untracked files never reach a closure.

**Step 5 builds before touching the machine.** An evaluation or build error should never reach the target, and the built path is what step 8 compares against.

**Step 7 does not trust deploy-rs.** It reports failure on activations that finished — a benign non-zero from a per-user unit reload is enough. So the exit code is recorded and the gate asks the machine directly instead: does `/run/current-system` equal what we built, and does it verify clean? The first question is what distinguishes a false positive from a real rollback. `verify` alone cannot, because the previous generation has its units up too.

**Step 7 also passes `--skip-checks`, and that is not the gate skipping anything.** Step 3 is the checks step. Left to itself deploy-rs runs `nix flake check` on the whole flake a second time, which costs twice over and introduces a failure mode the gate cannot see: a full-flake check evaluates every *other* host in the flake, so a host this deploy has nothing to do with — one pinning an input the caller cannot fetch, say — blocks it. A node that names its checks is stating which ones concern it; without this the statement buys nothing, because the next step runs them all anyway.

What this gives up is the flake-wide evaluation `nix flake check` performs. That is a coverage question, and it belongs to a **named check**, not to the deploy tool: a check that reads every declared host's `config` gives exactly that, and a node that wants it names it. When a node names nothing, step 3 runs `nix flake check` itself and nothing is lost either way.

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

### A copy before, and an account after

A node that declares `deployment.<node>.backup` and `.census` gets four more actions:

| | |
| --- | --- |
| `6c/8` | count what the machine holds: the tables of each database by name, the rows of `census.rowsIn`, the entries of `census.files` |
| `6d/8` | run `cattleServer --once` for the node's application, and **stop if it did not record a copy**. Last before the deploy, so nothing can abort once the copy exists |
| `8b/8` | count again and compare **by name**, not by total: a count cannot tell two tables merged from one table lost |
| `8c/8` | put back from that copy what cannot cost anything, count again, and only then decide |

`8c` puts back two things on its own and one thing never:

| What the deploy left | What `8c` does |
| --- | --- |
| every `census.rowsIn` table at zero — the database came back **new**, after a major upgrade, say | stops the node's application units, `cattleServer --restore --database --empty <those tables>`, starts them again |
| entries missing from `census.files` | `cattleServer --restore --uploads`, which puts back only what the machine lacks and replaces nothing |
| fewer rows, but not none — the database is **behind** | nothing: replacing it loses what was written after the copy. The gate stops and prints the `--restore --database --replace` command that would, for whoever deploys to decide |

A loss that is meant — two tables merged into one — is named in `GATE_SHRINK_OK`, which excuses it this once and keeps `8c` from undoing it:

```bash
GATE_SHRINK_OK="old_table" nix run .#deploy-myNode
```

The census counts the top level of each `census.files` directory, so an entry lost further down is not seen, and not put back.

### `GATE_MIGRATE=1`

For a deploy that **means** to change the PostgreSQL major, on a node **without** a `backup`. It inserts two actions into the same eight steps:

| | |
| --- | --- |
| `6b/8` | read the live major, `pg_dumpall` on the remote, **download it**, and refuse to go on unless the file really looks like `pg_dumpall` output |
| `7b/8` | read the major again; restore only if it **went up**, then remove the remote copy. The local one is kept either way |

Three things about where those sit:

**The dump goes after the last check and before the deploy.** Late enough that nothing else can abort once it exists, early enough that the machine is still serving the old cluster.

**It comes off the box before the deploy.** A dump that only exists on the machine being changed is not a backup.

**It is part of the gate, not a script beside it.** The separate path this replaces ran none of the six steps above — no cache guard, no access guard, no verify — and drifted from them, which is the argument against having two.

Do **not** use it to recover a machine whose data already sits in the data directory the new config pins: the restore would write over a cluster that is already correct, and the dump would come from whichever cluster happens to be running.

```bash
GATE_SKIP_PREFLIGHT=1 GATE_MIGRATE=1 nix run .#deploy-myNode
```

`GATE_SKIP_PREFLIGHT=1` goes with it because step 4 refuses a deploy that changes the major; the precondition says so and names this command.

**A node with a backup refuses it**, before step 1. It already has a way through a major upgrade — `6d` copies the database and `8c` loads it into the new cluster — so all it needs is `GATE_SKIP_PREFLIGHT=1`, and two paths would restore the same database twice. What `GATE_MIGRATE` still covers that the backup does not is the whole cluster: `pg_dumpall` carries every database and every role, where a backup carries the application's database, and roles come back only if the configuration declares them.

`GATE_DUMP_DIR` (default `/var/tmp`) and `GATE_DUMP_LOCAL` (default `~/postgres_backup_<node>.sql`) move the two ends.

### `GATE_SKIP_PREFLIGHT=1`

An explicit escape, because a gate without one gets bypassed by hand and stops being a gate. It exists for a known-intentional precondition mismatch. Whoever uses it next owes a reason.

### `GATE_PIN_OK` — an application moves in its own deploy

```nix
deployment.myNode.appInputs = [ "myApp" ];
```

```bash
GATE_PIN_OK='myApp' nix run .#deploy-myNode
```

A deploy that changes the machine and a deploy that changes an application are two deploys: together, whatever breaks has two suspects on a machine people are using. Keeping them apart used to depend on whoever deployed reading every `rev` of the lock, and a lock update made for one input can move another without anyone asking for it.

Step 1b asks the machine which revision of the flake it runs (`nixos-version --configuration-revision`), reads that revision's `flake.lock` from the checkout, and compares every input of the root with the lock about to be deployed:

| What moved | Step 1b |
| --- | --- |
| an input in `appInputs`, not named in `GATE_PIN_OK` | **stops**, naming the input and both revisions |
| an input in `appInputs`, named | reports it and goes on |
| any other input — nixpkgs, this library | reports it and goes on: moving with the machine is what they do |
| nothing | goes on |

It **also stops when it could not ask**: the machine did not answer, or says no revision — a deploy from a dirty tree records none —, or the checkout lacks the revision it names, or `appInputs` names an input the flake does not have. Empty `appInputs` skips the step, which is where every node starts. Run it on its own with `nix run .#pre-deploy-<node>-pins`; it only reads.

---

## The rebuild gate — `rebuild-gate.sh`

```bash
sudo nix run .#rebuild-myHost                 # switch, the default
sudo nix run .#rebuild-myHost -- test         # activate without touching the boot entry
sudo nix run .#rebuild-myHost -- boot dry-run # any nixos-rebuild args follow the mode
```

The same eight steps and the same guards but one: the pins guard asks what a remote machine runs, and here the machine is the one you are on. Seven of the steps apply unchanged; `REBUILD_MIGRATE=1` inserts the same `6b`/`7b` pair, reading and restoring locally.

### Why it is a second gate and not a flag

Measured against a local rebuild, the checks are not what differs. Three interactions are:

**`nixos-rebuild` has modes a deploy cannot express.** `test` activates without writing the boot entry, which is what a rescue wants; `boot` stages without activating; `dry-activate` changes nothing. Step 8 has to mean something different for each, so it does: `dry-activate` verifies nothing, `boot` reports what it staged and stops, and only `switch` and `test` are held to running the closure that was built.

**The cache guard can offer to write `~/.config/nix/nix.conf`.** On a laptop that is a convenience. On the machine being rebuilt it is a second change, made by a check.

**Without `magicRollback` there is no revoke to misread** — but there is still an exit code to misread, and it is the same lesson. Measured 2026-08-29: `switch-to-configuration` exited 4 because **one** unit failed, the system **had** changed generation, and the old wrapper announced "migration cancelled" having cancelled nothing — before it had even compared PostgreSQL versions. Here the code is recorded, the machine is asked, and a mismatch between the two is reported as what it is.

### It runs as root, and the dump does not

`nixos-rebuild` needs root, so the gate is invoked with `sudo` and reaches postgres with `runuser`. The dump lands in **`$SUDO_USER`'s home**, not root's, because that is where whoever ran it will look — `~/postgres_backup_<host>.sql`, movable with `REBUILD_DUMP_LOCAL`.

### The guards, locally

`LIVE_LOCAL` and `ACCESS_LOCAL` are what the gate exports to get there, and they cost very little:

| Guard | What changes |
| --- | --- |
| `cache-guard.sh` | **nothing**. It already reads `nix config show` and opens no connection |
| `freshness-guard.sh` | **nothing**. It only ever asked git |
| `live-checks.sh` | one function. Every remote question already went through `sshq`, and ssh joins its arguments into one shell command, so running that same command locally is the same command |
| `access-guard.sh` | two places: the reachability probe, which has nothing to reach, and the lister, which runs against the same `/etc` either way |

The access guard matters more here than it looks: activation rewrites `/etc` on the machine you are sitting at exactly as it does over a deploy, so an account that stops being declared loses its keys the same way.

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
- **on a host that declares [`postgresql.renames`](../modules/postgresql.md)**, that no pair has *both* names on disk. That is the one state the rename refuses to resolve, and it refuses it halfway through an activation; two queries here move the discovery to before anything has been touched. A pair with neither name **warns without failing**: nothing will be renamed and the new name will be created empty, which is right on a fresh machine and wrong everywhere else

The database half is conditional on purpose. A host whose whole job is to run a CI runner has no
Postgres at all, so asserting a major there would make it undeployable.

**`verify`** — only true *after* a deploy, so asserting it before would block the very deploy meant
to create it:

- every declared unit is active — home-manager units included, and the CI runner on a host whose whole job is to run one, which otherwise verifies clean while the only thing it exists for is dead. An app that ships its own module is covered too, but only once its host names the unit in `webStack ... unit`, because nothing can derive it
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
