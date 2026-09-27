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

| Cluster | Container | Notes |
|---|---|---|
| `shared` | `postgres` | This stack's own cluster — 15 real service databases plus scratch/test copies. |
| `argosy` | `argosy-db-1` | A second, separately-busy PG17 cluster in the `argosy` compose project (`~/projects/argosy/deploy`). In scope per SERV-43's plan ruling ("a cluster is a config entry"). |

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

<!-- PROVENANCE: filled in once traced — see SERV-213 -->

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
