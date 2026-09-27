# Postgres backups (SERV-43)

Design of record for the nightly Postgres backup pipeline. Read this before
changing `scripts/backup-nightly.sh`, `config/backup/backup.conf`, or anything
that consumes `/var/lib/construct-backup/state.json`.

This file is filled in across several tickets (SERV-212 through SERV-218,
children of SERV-43) and grows as each one lands. What follows is current as
of SERV-213 (the producer itself); the restore drill's numbers, the desktop
destination's specifics, and the Switchyard alarm are later sections' to add.

## Topology

One local restic hub on `/data`, fanned out with `restic copy` to independent,
append-only destinations. Settled in SERV-43's 2026-09-04 decision comment and
not reopened since:

```
pg_dump -Fc -Z0 (per db) + pg_dumpall --globals-only
                 │
                 ▼
       ┌─ LOCAL restic repo (the hub) ──┐
       │ retention + weekly check +      │  ← the fast-restore path
       │ monthly read-data-subset        │
       └──────────┬───────────────────────┘
                  │ restic copy   (adds only — never deletes)
                  ▼
              destination(s)     ← independent repos, own retention,
                                    receiver runs --append-only
```

Each destination is a real repository, not a mirror: one being unreachable
delays that destination and fails nothing else. The hub is the fast path for
the common case (a mistake five minutes ago); a destination is the actual
backup.

## What gets backed up

Two Postgres clusters, each backed up from its own container so client/server
version skew is structurally impossible:

| Cluster | Container | Admin role | Notes |
|---|---|---|---|
| `shared` | `postgres` | `postgres` (default) | This stack's own cluster — 15 real service databases plus scratch/test copies. |
| `argosy` | `argosy-db-1` | `argosy` | A second, separately-busy PG17 cluster in the `argosy` compose project (`~/projects/argosy/deploy`). In scope per SERV-43's plan ruling ("a cluster is a config entry"). |

**The admin role is per-cluster config, not a constant** — found by the smoke
test (2026-09-26), not assumed: the official postgres image's initdb creates
whatever role `POSTGRES_USER` names, and `argosy-db-1` runs
`POSTGRES_USER=argosy`, so it has no role literally called `postgres` at all.
`-U postgres` against it fails with `role "postgres" does not exist` — the
connection itself is fine, only the role name is wrong. `BACKUP_ADMIN_USER_<LABEL>`
in `backup.conf` defaults to `postgres` and only needs an entry where a
cluster differs.

Per cluster: enumerate every non-template database, exclude by pattern
(`swy*`, `*_test` — confirmed against the live shared cluster on 2026-09-26 to
match no real service database), and enforce a **must-dump floor**: a fixed
list of known service databases that the run refuses to complete without. A
pattern that accidentally swallowed a real database would otherwise show up
only as a quiet log line nobody reads — the floor turns that into a hard
failure. A brand-new database with no config change is still picked up
automatically; the floor only ever adds a second way to fail loud, it never
narrows what gets backed up.

`postgres` (the maintenance database) is included in both floors deliberately
— dumping it costs nothing, and it keeps the floor's rule simple: every real,
non-scratch database, full stop.

## Dump shape

- `pg_dump -Fc -Z0` per database (custom format, restic does the compression —
  see Tradeoffs), plus `pg_dumpall --globals-only` for roles and cluster-level
  grants.
- **Restore with `pg_restore --create`, never a bare restore.** Confirmed on a
  throwaway PG16-alpine container: `pg_dumpall --globals-only` emits zero
  `ON DATABASE` lines, and a per-database dump restored without `--create`
  comes back with default ACLs — the PUBLIC-revoke and tier-1/tier-2 grant
  hygiene from SERV-169/182/183 would be silently lost. `--create` reproduces
  `datacl` exactly. The full-cluster restore drill (SERV-217) diffs this for
  every restored database, not a sample.
- Every `pg_dump` runs inside a `docker exec … timeout N pg_dump …` on the
  cluster's own container — the timeout lives *inside* the exec so a killed
  host-side client can't leave the server-side process holding a lock past the
  run.
- A failed or empty-file dump is recorded and the database named, but does not
  abort the cluster: the other databases still get dumped and still get
  snapshotted to the hub. The run as a whole still exits non-zero.

## The hub

`/data/backups/restic-hub`, asserted by the preflight to live on a different
block device from Docker's root — a hub on the same disk as the database
doesn't survive losing that disk.

- One snapshot per cluster per night, tagged by cluster.
- `forget --keep-daily 14 --keep-weekly 8 --prune --group-by host,tags`. The
  tag grouping matters: restic's default `--group-by host,paths` would share
  one retention window across every cluster backed up from this host, so
  `argosy` joining `shared` would have halved each cluster's effective
  retention instead of each keeping its own.
- A weekly `restic check`.
- A monthly `restic check --read-data-subset=<cursor>/12`, where the cursor
  lives in `state.json` and advances **only on success** — a month that fails
  or is skipped leaves that twelfth due again next month, rather than
  permanently unread. This is what actually guarantees full coverage over a
  year; a calendar-keyed scheme without the cursor would not.
- Any hub-level restic failure (`backup`, `forget`, `check`, the read-data
  pass) exits the run non-zero **immediately** — no further clusters, no
  fan-out to any destination. A broken hub is not a problem to work around
  quietly.

## Credentials

**One untracked, host-side file, one writer:** `/etc/construct-backup/backup.env`,
mode 0600. Holds:

- `RESTIC_PASSWORD_HUB` — the hub repository's password.
- Per destination `NAME` (upper-cased): `RESTIC_PASSWORD_NAME`,
  `REST_USER_NAME`, `REST_PASSWORD_NAME`.

These are **backup.env's own names**, not restic's. The script maps them onto
restic's real environment variables per invocation, and only for that
invocation:

| Operation | `RESTIC_REPOSITORY` / `RESTIC_PASSWORD` | `RESTIC_FROM_REPOSITORY` / `RESTIC_FROM_PASSWORD` | `RESTIC_REST_USERNAME` / `RESTIC_REST_PASSWORD` |
|---|---|---|---|
| hub-only (backup, forget, check) | the hub | — | — |
| `copy` to a destination | **the destination** | the hub | the destination's REST credentials |
| `snapshots` readback on a destination | the destination | — | the destination's REST credentials |

Getting this backwards (assuming `RESTIC_PASSWORD` always means "the hub")
authenticates `copy` to the destination with the hub's own password and fails
immediately — confirmed against restic's own `--help` output and a live run
before choosing the pin, not assumed.

Every value reaches `docker run` **by name only** (`-e VAR`, valueless — the
container reads the value from this script's already-exported environment).
No credential is ever a literal argument on a command line, so none can show
up in `ps` on this host.

**How `backup.env` itself gets onto the host** is Signet's, per SERV-43's plan
ruling — see SERV-214.

### Off-box custody (SERV-212)

Two independent passwords exist, generated together before either repository
was created:

- The hub's, stored off-box as `construct-server-backup-hub`.
- The desktop destination's, stored off-box as `construct-server-backup-desktop`.

Names only, here and in the password manager — never the values. If this box
is lost, both repositories are still readable from the off-box copies; if only
one of these entries existed, losing the box would lose every backup at the
exact moment they're needed, which is the whole reason this step gates
everything else in the plan.

## Miss semantics and the claim/observation split

**One destination gets one attempt and one miss/success per NIGHT, covering
every configured cluster — never one per (cluster × destination) pair.**
`hub_backup_cluster` captures the hub's own snapshot id for each cluster
right after backing it up (`HUB_SNAPSHOT_ID[label]`); `fanout_destination` is
called once per destination with every cluster's label, and copies each in
turn (`copy_one_cluster`) before deciding the whole night's outcome for that
destination. **Getting this wrong was PR #226's review finding #2**: an
earlier version called the per-destination update once per cluster, so a
destination serving two clusters gained two misses in one bad night (tripping
the 3-miss threshold on the second night, not the third) and — worse — a
cluster that permanently failed was invisibly reset to "succeeded" every night
by a second cluster that kept landing, since the second call always
overwrote the first's miss with its own success. `make backup-test`'s T18/T19
exercise both shapes with two clusters, which is the one thing a
single-cluster conf structurally cannot see.

**Freshness is checked against tonight's actual hub snapshot, not "any
snapshot carrying the tag."** After a `copy` exits 0, the destination's own
snapshot list is read back, and a match requires the destination to hold a
snapshot whose `.original` (restic stamps this on every copied snapshot with
the source snapshot's id — confirmed directly against the pinned binary,
not assumed) equals the hub's own id for that cluster tonight. **This was
review finding #3**: an earlier version accepted *any* snapshot at the
destination carrying the right tag, of any age, and stamped `last_success_at`
with the current time regardless — so a `copy` that silently failed to land
anything new still read as a fresh success as long as last week's copy was
still sitting there with the same tag. `make backup-test`'s T20 sets up
exactly that (a destination snapshot whose `.original` doesn't match) and
confirms it is recorded as a miss.

One bounded retry per (destination, cluster) pair per run; still failing for
that cluster, the run moves to the next cluster and then, having tried them
all, records the whole night as a miss for that destination if *any* cluster
failed — nothing about the destination's own credential or the other
destinations is touched. After 3 consecutive missed nights to one destination
the unit exits non-zero (in addition to that destination's own failure).
Delay is allowed and structural; a destination skipped because it was asleep
must never read the same as one that succeeded, which is why success is read
from the destination and not from the local attempt.

## Concurrency

The `flock` on `$BACKUP_STATE_DIR/backup.lock` is taken **before** anything
that touches `state.json` or the staging directory — including
`preflight_retry_loop`, which writes `preflight_failed_count` on exhaustion.
**Review finding #1** on PR #226: an earlier version took the lock only just
before the dump loop, *after* `staging_setup` had already `rm -rf`'d the
staging directory. A second invocation (a manual run colliding with the
timer, or two manual runs) would delete the first run's in-progress dumps,
fail its own lock check, and then delete the directory a *second* time via
its own `EXIT` trap — corrupting the first run rather than merely being
refused. `make backup-test`'s T17 hangs one database's dump deliberately (a
mock-only hook) to open a real window for a second invocation and confirms it
is refused immediately, before touching staging, while the first completes
undisturbed.

**`state_init_if_missing` runs before `preflight_retry_loop`, not after — and
`state_update` fails closed on any `jq` error, not just this one.** Round 2 of
the same PR's review: the first fix moved the lock ahead of
`preflight_retry_loop`, but not `state_init_if_missing` itself, so a fresh
state directory whose very first run exhausts preflight (a rebooted host
whose docker/tailscale/postgres aren't up yet — exactly what the retry loop
exists for) hit `state_update` against a `STATE_FILE` that did not exist.
`jq` against a missing file fails, but the unconditional `mv` that followed
moved its empty output into place anyway, installing a 0-byte `state.json`.
`state_init_if_missing`'s own existence check (`-f`) is satisfied by an empty
file exactly as well as a valid one, so nothing ever replaced it — the weekly
check, the monthly read-data-subset and the miss threshold would all have
gone permanently, silently inert, with every run still exiting 0. Reproduced
directly with the script's own `state_update` against a missing file before
fixing it: `jq` exits 2, and the move still lands a 0-byte file regardless.
Two fixes, not one: the ordering (so this exact path can't recur), and
`state_update` itself checking `jq`'s exit status before the `mv` (so no
future `jq` failure — a bad filter, a permissions problem, a full disk —
can ever corrupt a working `state.json` into an empty one silently). T21
exhausts preflight on a fresh state dir and confirms `state.json` comes out
valid, then confirms a second, healthy run proceeds normally.

## Container hygiene

Every `restic` invocation runs in a container this script starts under a
fixed name, and that name is force-removed **both before and after** every
invocation — never relying on `--rm` alone, since a `kill -9` or an expiring
`timeout` can leave a container (and the repository lock it may hold) behind
for `--rm` to never clean up. The script never touches a Postgres server
container beyond `docker exec`; it neither removes nor recreates one.

**Three things `make backup-test`'s mock could not catch, because it never
launches a real container** — found only by the real smoke test against the
real box (2026-09-26), and each cost a full re-run to fix:

- **`--network host` shares the network namespace only.** The container's
  filesystem is otherwise its own, with zero visibility into the host's
  `/data` — a `restic backup` of the staging tree failed with "does not
  exist, skipping" despite the files genuinely being there, on the host.
  Fixed with `-v "$BACKUP_DATA_DIR:$BACKUP_DATA_DIR"`, which covers both the
  hub repo and the staging tree at the same path inside and outside the
  container, needing no path translation anywhere else in the script.
- **The image runs as root by default, and a bind mount does no UID
  remapping.** `restic init` "succeeded" the first time and reported creating
  the repo at the right path — but that was root writing into the
  container's own throwaway filesystem, since the bind mount wasn't wired
  yet either; once it was, root wrote real, root-owned files onto the host
  disk that `magos` (or the systemd unit SERV-214 wires, also `magos`,
  matching `delivery_prober`'s convention) could not read back on the very
  next invocation. Fixed with `--user "$(id -u):$(id -g)"`. The root-owned
  leftover from the first attempt needed a throwaway root container
  (`docker run --rm --entrypoint rm -v ...`) to remove, since `magos` itself
  couldn't touch it — the same asymmetry that makes root worth avoiding here
  in the first place.
- **An arbitrary `--user` UID has no passwd entry, so `HOME` defaults to
  `/`.** Harmless but noisy (a `/.cache` permission warning on every
  invocation) and slower than it needs to be, since restic re-fetches what
  its local cache would otherwise have kept. Fixed with
  `-e HOME="$BACKUP_DATA_DIR"`, a directory already ours and already mounted.

## Wall-clock bounds

Every external call — one `pg_dump`, one `restic` invocation — is individually
bounded by its own `timeout`. `BACKUP_PG_DUMP_TIMEOUT_SEC` and
`BACKUP_RESTIC_TIMEOUT_SEC` in `config/backup/backup.conf` are the per-call
figures; the unit's own `TimeoutStartSec` (SERV-214) is the run-wide bound and
is sized against this budget:

```
TimeoutStartSec ≥ preflight max (BACKUP_PREFLIGHT_MAX_SEC)
                 + hub duration (backup + forget/prune + weekly check + monthly read-data)
                 + Σ over destinations of (retry count × BACKUP_RESTIC_TIMEOUT_SEC)
                 + margin
```

**`TimeoutStartSec=2700` (45 minutes)**, set on the systemd unit
(`ansible/roles/construct_backup`), broken down:

| Term | Seconds | Basis |
|---|---|---|
| preflight max | 1200 | `BACKUP_PREFLIGHT_MAX_SEC` |
| hub duration | 600 | measured ~16s for both clusters on 2026-09-26 at ~818 MiB combined, no destination configured — >20x headroom for data growth |
| destination margin | 600 | the desktop's real first seed (SERV-215, below) took 10s for both clusters combined, well inside this — but that's happy-path, no-retry timing over an already-fast tailnet link, not the worst case this margin has to cover, so the figure stays as-is rather than being tightened on one data point |
| margin | 300 | |
| **total** | **2700** | |

Provisional on the destination-margin term specifically, not on the rest —
`ansible/roles/construct_backup/defaults/main.yml` carries this same table and
is where the number actually lives; update both together if it changes.

The first seed against any new destination runs by hand, outside the unit —
initial throughput to a new destination isn't known in advance and shouldn't
gate the nightly budget.

## Boot-time preflight

Two different kinds of check, deliberately not merged:

- **Static** (wrong device, a `RESTIC_IMAGE` with no digest): fails
  immediately. Retrying a config file for 20 minutes helps nobody.
- **Transient readiness** (docker, tailscale, and `pg_isready` on every
  configured cluster): one bounded retry loop, stated maximum 20 minutes,
  counted *inside* `TimeoutStartSec` — relevant mainly right after boot, since
  the timer carries `Persistent=true` (`ansible/roles/construct_backup`).

Exhausting the retry loop exits non-zero and records `preflight_failed` in
`state.json` — explicitly **not** a destination miss, and it touches no
destination's `consecutive_misses`.

**The unit carries no systemd-level restart machinery at all** —
`Type=oneshot`, no `Restart=`, `RestartForceExitStatus=`, `RestartSec=` or
`StartLimitBurst=`. Checked directly on this box with transient units
(systemd 255) before choosing this, not assumed:

- `RestartForceExitStatus=` on a `Type=oneshot` unit is **refused at load**
  ("isn't allowed for Type=oneshot services. Refusing.") — such a unit never
  runs at all.
- Any restart mechanism that *does* work re-executes the whole script from
  the top, so a dump failure or the exit-at-threshold path would increment
  `consecutive_misses` again and could trip the N=3 threshold from one bad
  night rather than three genuinely separate ones.
- `Type=exec` with `Restart=no`/`RestartForceExitStatus=75` does restart only
  on exit 75, but needs an explicit `StartLimitIntervalSec` larger than
  burst × (`RestartSec` + longest run) — the 10s default never stopped it in
  testing — and moves the run's own bound to `RuntimeMaxSec`, a second timeout
  alongside `TimeoutStartSec`. Rejected for exactly that reason: one wall-clock
  budget, not two.

So the retry lives inside the script's own preflight loop, and the unit stays
a single, bounded, non-restarting execution per timer firing. `systemd-analyze
verify` runs on the rendered unit on every `ansible-playbook` apply, not just
once — the role's own `Validate the rendered unit with systemd-analyze verify`
task, which fails the play on a non-zero exit rather than trusting a template
that renders without error.

## Host wiring (SERV-214)

`ansible/roles/construct_backup` installs `construct-backup.service` and
`construct-backup.timer`, and creates two directories (mode 0700,
`magos:magos`) — nothing else:

- `/etc/construct-backup`, for `backup.env`. Does **not** template the file
  itself; see "Credential delivery" below for why that would be a second
  writer.
- `/var/lib/construct-backup`, for `state.json` and the lock file.
  `backup-nightly.sh` already does its own `mkdir -p` for this path, but that
  would fail on a cold host under the real unit: `/var/lib` is `root:root`
  `0755` (confirmed directly — `stat -c '%U %G %a' /var/lib`), and the unit
  runs as `magos`, not root. Manual runs during SERV-213 never hit this
  because they used an override path instead of the real default; this role
  is what makes the real default path actually usable.

**The state from SERV-213's manual smoke test lives at
`/data/backups/smoke-test-state`, not the real path.** It is not migrated —
the real `state.json` starts fresh once this role creates
`/var/lib/construct-backup` and the first real run populates it. The only
practical effect is that the weekly check and the first monthly
`--read-data-subset` slice both re-run on that first real night rather than
waiting out the interval the smoke test had already partly satisfied —
harmless, just slightly redundant. The scratch directory can be removed by
hand once you're satisfied nothing else references it.

**The timer is never enabled or started by this role, in either direction.**
Per the ticket: it stays off until the desktop destination exists (SERV-215).
A re-run of this role also never *disables* a timer someone has since turned
on by hand — the role takes no enable/disable action either way, only
`state: directory` / templated files. Turn it on with
`systemctl enable --now construct-backup.timer` once SERV-215 lands.

Applied by hand, like every role here: `ansible-playbook ansible/site.yml
--tags construct_backup -K`. `ansible-lint` passes at the `moderate` profile.

## Credential delivery (SERV-214)

**A new, separate Signet project — `construct-backup` — not `construct-server`.**
The plan's ruling says this explicitly, and it matters: `construct-server`'s
own project deliberately has *no* host file target (SERV-94 — "prod has no
host file target", one `PROD_ENV_FILE` render only, confirmed still true via
`signet status` on 2026-09-26). Adding a file target to it would be exactly
the second-writer hazard SERV-94 exists to prevent. A clean, separate project
keeps that discipline intact.

**Two things were proven against the real binary before relying on them, and
one didn't hold as first diagnosed — corrected after PR #228's review, which
measured the actual mechanism rather than accepting the first explanation:**

- **The mechanism works.** `signet import <file>` registers a file target AT
  THE EXACT PATH GIVEN and seeds the vault from that file's keys and values;
  `signet render -project P` then writes the vault's current values back to
  every path registered for that project. Tested end to end with a throwaway
  secret and a throwaway path — real content lands.
- **The permissions are not a umask issue.** A fresh `signet render` into a
  path that already held a file came out mode `664`, which the first version
  of this section blamed on the calling process's ambient umask. That was
  wrong: signet's own atomic-write sets `0600` on a file it creates **fresh**,
  and otherwise **preserves whatever mode the existing file already had** —
  confirmed directly by deleting the target and re-rendering (came back
  `600`) versus rendering onto a pre-existing `664` file (stayed `664`). The
  664 traced to a hand-created seed file, not to signet. The fixes stand
  regardless of the exact mechanism, and are now stable for the right reason:
  **never** call `signet render -project construct-backup` directly — always
  `scripts/render-backup-env.sh`, which renders then `chmod 0600`s — and
  `backup-nightly.sh` itself refuses to source `backup.env` at any mode other
  than `600`. Once the target file is created at `0600` (below), signet keeps
  it there on every later render; the wrapper's `chmod` is the backstop, not
  the thing doing the work every time.

**`import` registers the target at the path you give it — not at whatever
path you separately plan to deliver to.** The first version of this runbook
imported from a scratch seed file elsewhere and expected `target add-key` to
point delivery at `/etc/construct-backup/backup.env` afterward; `target
add-key` refuses a path that was never imported ("no file target ... — signet
import it first"), so that render would have silently landed on the SEED
path forever, never on the real one. **Import the real target file itself.**

**`import`'s direction is file → vault, not the reverse — a sequencing trap
worth stating plainly, because it isn't the direction the word suggests.**
Discovered by hitting it directly: `generate`-ing a secret first, then
`import`-ing a placeholder-seeded file, overwrote the freshly-generated
random value with the placeholder text — `import` reported "1 updated",
meaning the VAULT's value changed to match the FILE, not the other way
around. The runbook below avoids this by writing the REAL value into the
target file first and importing that — import then seeds the vault with the
value that's already correct, never a placeholder.

**Runbook**, once SERV-215 exists and the passwords are ready (from SERV-212's
and SERV-216's off-box copies). First-time bootstrap, on the box, as
`{{ construct_backup_user }}` (after the ansible role has created the
directory):

```bash
# Write the real values directly into the real target path, at 0600, before
# signet ever touches it — this is what makes the eventual import seed the
# vault correctly instead of with a placeholder.
install -m 600 /dev/null /etc/construct-backup/backup.env
echo "RESTIC_PASSWORD_HUB=<the real value>" >> /etc/construct-backup/backup.env

# Register the target AT THAT EXACT PATH and seed the vault from it in one
# step — no separate seed file, no target add-key needed for these first keys.
signet import -project construct-backup /etc/construct-backup/backup.env

# Confirms the mode is still 600 and the content still matches (render is a
# no-op here content-wise, since the vault already matches what's on disk):
./scripts/render-backup-env.sh
```

Adding a **new** key later (a second destination, say) — `target add-key`
now works, because the target already exists at this exact path:

```bash
printf '%s' '<the real value>' | signet set -project construct-backup -name RESTIC_PASSWORD_DESK
signet target add-key -project construct-backup \
  -path /etc/construct-backup/backup.env -name RESTIC_PASSWORD_DESK
./scripts/render-backup-env.sh
```

Rotating an **existing** key — no `import`, no `target add-key`, no
`-replace` (that flag is meaningful only with `-generate`; a plain `set` with
a real value overwrites the existing one unconditionally — confirmed
directly, "version 2" with no complaint):

```bash
printf '%s' '<the new value>' | signet set -project construct-backup -name RESTIC_PASSWORD_HUB
./scripts/render-backup-env.sh
```

## Provenance: the roles the globals dump has to carry

`db/init-db.sh` provisions `chronicle` and `asr` (since SERV-169/182) and
`centrifuge_user` — but three roles exist live in the shared cluster that
`init-db.sh` names nowhere, and the globals dump is these roles' *only*
record. Traced below rather than left as an open question, per this ticket's
own must-dump-floor argument: an unexplained role is exactly the kind of
silent gap this file exists to close.

| Role | Provenance | Source |
|---|---|---|
| `catenary` | `CREATE ROLE catenary WITH LOGIN PASSWORD :'password'` — run once by hand as superuser. Deliberately not a migration (CANT-13 Ruling 3): migrations run *as* `catenary`, and a role cannot create itself. | `~/projects/catenary/deploy/provision.sql` |
| `drydock_user` | Provisioned by hand directly against the running cluster; has no `ensure_db` line yet because adding one changes the shared `postgres` service's env and bounces every dependent service (17 of them) — deliberately deferred to its own change. | This repo's own `README.md` (database table + note), tracked and open as **SERV-72** |
| `centrifuge` (bare, distinct from `centrifuge_user`) | **Not fully traced.** The literal name's origin is understood — centrifuge's own standalone dev-stack compose file defaults `POSTGRES_USER=centrifuge` for its *own* Postgres container, a separate instance from the shared cluster. How, or whether, that name was carried into the *shared* cluster specifically is not documented in construct-server, centrifuge, signet, or the deployed host — no script, migration, or prior ticket describes that move. Filed as **SERV-219**. | `~/projects/centrifuge/docker-compose.yaml`, `.env.example:87` (for the name's origin only) |

All three restore correctly from the globals dump regardless — `pg_dumpall
--globals-only` captures a role's definition by what it *is*, not by how it
got there. This table is about whether the repo can **explain and recreate**
them, which the restore drill (SERV-217) does not itself test and should not
be read as testing.

## The producer's own smoke test (SERV-213, 2026-09-26)

Run by hand, for real, against the live `postgres` and `argosy-db-1`
clusters — this is what the three bugs in "Container hygiene" above were
found by. The real hub now exists at `/data/backups/restic-hub`.

- Both clusters dumped and snapshotted correctly: 15 databases from `shared`
  (808 MiB), 2 from `argosy` (10.3 MiB). 19 scratch/test databases correctly
  excluded and logged with size.
- A second run against the same hub showed real dedup working: 16 changed
  files added only 44 MiB (5 MiB stored after restic's own compression) on
  top of the first run's 808 MiB.
- `--group-by host,tags` retention confirmed to keep each cluster's snapshots
  independently — `argosy` and `shared` each show their own daily/weekly
  reasons in the same `forget` run, not a shared window.
- The weekly `restic check` and the first monthly `--read-data-subset=1/12`
  both ran and passed on this first-ever run (cursor is now `2`).
- One database (`chronicle`, extracted from the hub via `restic dump`, not
  from staging — staging is long gone by the time a human could look) was
  restored with `pg_restore --create` into a scratch `postgres:16.15-alpine`
  container on the default bridge network, not `construct_net`. Its restored
  `datacl` — `{chronicle=CTc/chronicle,chronicle_tier1=c/chronicle}` — is
  byte-identical to the live database's, confirming the PUBLIC-revoke and
  tier-1/tier-2 grant hygiene from SERV-169/182 survives the round trip. This
  is a smoke test, not the drill: one database, not the full cluster, and no
  timing was recorded — both are SERV-217's.

## The desktop destination's credentials (SERV-215)

`backup-receiver/install.sh` had two argv leaks, both the same shape as the
one `backup-nightly.sh` was already built to avoid (see Credentials, above):
a real password reaching a **new process's own argv**, visible to anyone who
runs `ps` on that host for as long as the process is running.

- **`ensure_credentials()`** wrote the htpasswd entry with
  `htpasswd -Bb … "$REST_USER" "$REST_PASSWORD"` — the password was a literal
  argument to the `docker run` this script itself invokes. Fixed by switching
  to `-Bi`/`-Bic` (create) and piping the password on stdin
  (`printf '%s\n' "$REST_PASSWORD" | docker run -i …`); only the username,
  which isn't secret, stays a literal argument. `printf` is a shell builtin,
  so it never becomes a process with argv of its own either.
- **`verify()`'s probes** authenticated with `curl -u "$user:$pass"`, which is
  the same shape — the credential sat in `curl`'s own argv for the life of the
  request. Fixed by switching to a curl config read from stdin
  (`printf 'user = "%s:%s"\n' … | curl -K - …`), the same `-K -` shape
  `backup-nightly.sh`'s eventual heartbeat token (SERV-218) will need to use
  for the same reason.
- **`next_steps()` and the README's "Then, on the construct server" and
  rotation paragraphs** showed `restic -r rest:http://user:PASSWORD@host/…` —
  no real value was ever printed (the password stayed the literal text
  `<password>`), but the *shape* is exactly what's being fixed everywhere
  else, and it's what an operator would go on to type. Replaced with the
  `RESTIC_REST_USERNAME`/`RESTIC_REST_PASSWORD` environment-variable form,
  matching the credential mapping table above.

Both fixes were verified live against the pinned image
(`restic/rest-server:0.14.0@sha256:d2aff06f…`), not assumed: `htpasswd -Bic`/
`-Bi` over stdin correctly creates, adds a second user, and rotates an
existing one (bcrypt hashes, `$2y$`), confirmed by round-tripping with
`htpasswd -vi` afterwards; and a real rest-server container, started with
`OPTIONS=--append-only` and a stdin-seeded `.htpasswd`, answered exactly as
`verify()` expects to the new `-K -` probes — 401 unauthenticated, 200 on an
authenticated create, 401 on a wrong password, 403 on `DELETE …/config`.

## The desktop repository, first seed, and append-only proof (2026-09-27)

Destination named `desk` (not `desktop`) — `backup-nightly.sh` derives each
destination's credential variables from its short name, upper-cased, and the
runbook example in "Credential delivery" above already used `DESK`.
`config/backup/backup.conf`'s `BACKUP_DESTINATIONS` now carries
`"desk:rest:http://imperial-prime-wsl:8000/construct/"`.

**Created with `restic/restic:0.18.1@…` (the pinned image), the same
container shape `run_restic()` uses** — `--network host`, `--user
$(id -u):$(id -g)`, `-e HOME`, the hub bind-mounted, every credential passed
by `-e NAME` (valueless):

```
RESTIC_REPOSITORY=rest:http://imperial-prime-wsl:8000/construct/
RESTIC_PASSWORD=$RESTIC_PASSWORD_DESK
RESTIC_FROM_REPOSITORY=/data/backups/restic-hub
RESTIC_FROM_PASSWORD=$RESTIC_PASSWORD_HUB
RESTIC_REST_USERNAME=$REST_USER_DESK
RESTIC_REST_PASSWORD=$REST_PASSWORD_DESK
restic init --copy-chunker-params --from-repo /data/backups/restic-hub
```

Ran in 4s, exit 0. **`--copy-chunker-params` confirmed, not assumed** —
`restic cat config` on both repositories:

| | hub | desktop |
|---|---|---|
| `chunker_polynomial` | `385cd265a9c695` | `385cd265a9c695` (match) |

**First seed** — `restic copy --tag <label>` for each of the hub's two
existing clusters, from the construct server, over the tailnet (DERP-relayed
tonight, not a direct connection — `tailscale ping imperial-prime-wsl`
showed `~11ms via DERP(ord)`, still well inside the per-call timeout):

| Cluster | Snapshots copied | Elapsed |
|---|---|---|
| `shared` | 2 | 8s |
| `argosy` | 1 | 2s |

Each copied snapshot's `.original` was confirmed to equal its hub source
snapshot's id (the exact check `copy_one_cluster` makes every night) —
`26ba3fc7`→`47cf0016`, `b361562b`→`cbecc74a`, `35572eea`→`387aed30`, all
matching. `restic stats --mode raw-data` on the desktop repo afterward: 3
snapshots, 863.125 MiB uncompressed, **92.068 MiB stored (9.37x compression,
89% space saved)** — restic's own repository-v2 compression, not the `-Z0`
pg_dump flag (that one exists so restic's compression sees the data once,
not gzip once and then restic again on top of it).

**Append-only, proven from the credential path the nightly job actually
uses** — `backup-nightly.sh verify-destination desk`, added for exactly this
(see "Container hygiene" and the function's own comment): inits a fixed,
reused `backup-nightly-verify-probe` repository on the same REST server
(never `/construct/` itself) if absent, backs up one tiny fixed fixture, then
confirms both `restic forget --keep-last 0` and a raw `DELETE
.../config` are refused. Run twice, live, back to back:

- **First run**: probe repo absent → initialized, fixture backed up,
  `forget` refused, `DELETE .../config` → 403. `append-only confirmed`, exit 0.
- **Second run**: probe repo already present → no re-init (idempotence
  confirmed), fixture backed up again (restic dedups the content; a tiny
  amount of new tree/metadata is stored per run, not zero, but bounded — the
  same accepted growth as a real destination's own append-only cost), same
  two refusals, same result.

This is the ongoing check (`make backup-status` doesn't run it; nothing does
automatically) — re-run it by hand occasionally, and always after any change
to the receiver's `docker-compose.yml` `OPTIONS`. `make backup-test`'s mock
suite covers only `verify-destination`'s argument validation (T23, T24) —
never the real network calls, deliberately (see that file's header).

## Not yet in this file

- **The restore drill's numbers** — full-cluster restore time, the worst-case
  data-loss window, the ACL/role diff: SERV-217. CHRN-68's standard applies
  verbatim: a backup nobody has restored is a hypothesis.
- **Growth and the first prune date**: after seven unattended nights
  (SERV-43's own closing criterion).
- **The Switchyard heartbeat and the live-alarm proof**: split into its own
  ticket, SERV-218, blocked by SWY-408 — see SERV-43's plan for why gating
  this ticket's close on it would have gated SERV-163 and CHRN-68 too.
- **Two things this pipeline does not cover, filed separately rather than
  silently gapped**: the `/` disk-usage trend (SERV-210) and the Signet vault
  plus `creds/` (SERV-211) — a box loss under this design restores Postgres
  data and roles but not the credentials to run any of it.
