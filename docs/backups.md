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

For each destination: `restic copy` from the hub (bounded by its own
per-invocation `timeout`), then read that destination's **own** snapshot list
back and record *that* as the last success — never the script's memory of
having run `copy`. This is PRINCIPLES §4's report-versus-observation rule
applied to backups: a `copy` that exits 0 without actually landing a new
snapshot at the destination must read as stale, not fresh, and is recorded as
a miss.

One bounded retry per destination per run; still failing, the destination is
marked attempted-and-failed and the run moves to the next destination —
nothing else is touched. After 3 consecutive misses to one destination the
unit exits non-zero (in addition to that destination's own failure). Delay is
allowed and structural; a destination skipped because it was asleep must never
read the same as one that succeeded, which is why success is read from the
destination and not from the local attempt.

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

The exact number is SERV-214's to size against real timings once the desktop
destination exists (SERV-215) and a few real nights have run; this file will
carry that number once it's chosen rather than a placeholder guess.

The first seed against any new destination runs by hand, outside the unit —
initial throughput to a new destination isn't known in advance and shouldn't
gate the nightly budget.

## Boot-time preflight

Two different kinds of check, deliberately not merged:

- **Static** (wrong device, a `RESTIC_IMAGE` with no digest): fails
  immediately. Retrying a config file for 20 minutes helps nobody.
- **Transient readiness** (docker, tailscale, and `pg_isready` on every
  configured cluster): one bounded retry loop, stated maximum 20 minutes,
  counted *inside* `TimeoutStartSec` — relevant mainly right after boot, once
  `Persistent=true` is wired (SERV-214).

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
verify` on the rendered unit is SERV-214's guard against a regression here.

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

## Not yet in this file

- **The desktop destination's specifics** — `restic init --copy-chunker-params`,
  the append-only proof against a throwaway probe repository, and the
  `install.sh` credential-handling fixes: SERV-215.
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
