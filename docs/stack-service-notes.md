# Stack service notes

Detail moved out of the root `CLAUDE.md` (SERV-317). The root file keeps the rule;
this file keeps the rationale and per-service specifics.

## `postgres-private` and Plimsoll

(PLIM-8). First init only, unlike the script below. That cluster has its own admin
role (`private_admin`, not `postgres`), no published port, and sits on the internal
`private_db_net`, not `construct_net`; it is backed up as label `private`. Plimsoll
(port 4016, PLIM-7) is its only client, and must never get a router, tunnel, public
hostname or Access app.

## `plimsoll-llm`

`plimsoll-llm` — Plimsoll's own Ollama (PLIM-14), on the internal, isolated-gateway
`plimsoll_ai` network with exactly one other member, `plimsoll`. It sees health facts
in its prompts, so its config is an allowlist that `scripts/check-plimsoll-sandbox.py`
enforces in CI (`plimsoll-sandbox.yml`): no port, no second network, no env key outside
the list (never `OLLAMA_DEBUG`), the discrete GPU only, capped `json-file` logs, a
`mem_limit`, and the same image pin as `ollama`, which carries its own `mem_limit` for
the same reason (PLIM-14 ruling 6). Weights arrive only through `make plimsoll-llm-seed`
(digest-verified copy from the shared volume, `--network none`), which must run
**before** the deploy that adds the service or moves the pin: an empty read-only
models volume crashes Ollama at start and keeps `assert-healthy` red. `deploy.yml` runs
`scripts/check-plimsoll-llm-isolation.sh` after every deploy, and
`make plimsoll-llm-canary` checks the logs after a live eval.

## `db/init-db.sh`

`db/init-db.sh` — idempotent role/database bootstrap, runs on **every** deploy.
Since SERV-169 it provisions chronicle and `asr` too (`asr` keeps its own database
and role on the shared Postgres, not a schema inside Chronicle's — CHRN-25), with
PUBLIC revoked on all four so the hand-built hygiene survives a rebuild. Since
SERV-182 it also provisions chronicle's second role, `chronicle_tier1`, in a
**dedicated block that never goes through `ensure_db`**: that helper ends in an
unconditional `GRANT ALL PRIVILEGES ON DATABASE`, which would give the tier-1 role
CREATE on the tier-2 database on every deploy — and Chronicle's boot audit (CHRN-52)
would then refuse to serve. The block mirrors `chronicle/deploy/tier1-role.sql`;
change them together. One cost, by construction: on a cold rebuild Chronicle
crash-cycles once, because this script runs after `up -d` and migration 0001
needs the role. And because this script runs AFTER `up -d`, a deploy that widened
the role would do so after chronicle had booted and audited the old grants — so
since SERV-183 **`deploy.yml` gates every deploy on `chronicle tier1-audit`**, last
of its three assertions (after `assert-healthy` and `check-edge-auth`, so a
chronicle problem can never take the edge gate offline) — **and, since SERV-220,
independently of `check-edge-auth`'s own result**: that step carries its own `if:`
keyed on `assert-healthy` succeeding, not on the default "every earlier step
passed," so an edge-auth failure no longer silently skips this audit too. It still
won't run on a cancelled deploy or if `assert-healthy` itself failed.
That subcommand exists from chronicle 1.11, which makes **1.11 a rollback floor
for `CHRONICLE_TAG`**:
`versions.env` declares it once as `CHRONICLE_TIER1_AUDIT_FLOOR`, `promote.yml`
refuses a lower pin before committing it, and the gate step re-checks the running
version so a hand-edited pin fails with a sentence rather than a usage error.
**One thing still opts out:**
- **catenary** — `deploy/provision.sql` in its own repo, and deliberately never a
  migration: CANT-13 Ruling 3, because migrations run **as** the `catenary` role and
  a role cannot create itself. Permanent, not pending a ticket.

It is run once by hand as superuser, so a cold host rebuild does **not** self-heal
it: catenary crash-loops on an unreachable database until `provision.sql` is run.
(Chronicle used to be in this sentence; since SERV-182 its one crash cycle on a
rebuild is the script's ordering, not a missing hand-run step, and it recovers.)

## `satlink`

`satlink` — the estate health dashboard (SERV-295 / SATL-15, repo `Einlanzerous/satlink`):
port 4018 (not its image default 4015, which is sextant's), no host port, own database
`satlink` on the shared Postgres via `db/init-db.sh`, the `traefik_access_logs` volume
mounted read-only. Gated by Cloudflare Access (SATL-16): an `internal`-only router with
`cf-access-jwt`, its host in `CF_ACCESS_AUD_MAP`, and the app verifies the assertion
itself (`CF_ACCESS_TEAM_DOMAIN`, `CF_ACCESS_AUD`, `ACCESS_ALLOWED_EMAILS` from the Signet key
`SATLINK_ACCESS_ALLOWED_EMAILS`, kept out of this public repo). Pinned to a FULL version in
`versions.env`, not major.minor. No Docker socket: a host systemd user timer writes
`docker-state.json` and compose bind-mounts its directory read-only with
`create_host_path: false`, so the exporter install precedes any deploy that adds or
recreates the service. Host inputs (SATL-61), also read-only with `create_host_path: false`:
`lost+found` of `/mnt/ssd_storage` and `/data` (statfs only; nothing readable) and
`/var/lib/construct-backup` (0700 magos; works because the image's `bun` is uid 1000).
The retired `SATLINK_API_TOKEN` key stays in the vault, unreferenced.

## `genzo` and `trestle-genzo`

`genzo` + `trestle-genzo` — the photo library (GENZO-8, repo `Einlanzerous/genzo`): port
4019, no host port, own database `genzo` (role `genzo_user`, PUBLIC revoked) on the
shared Postgres, an `internal`-only router with `cf-access-jwt`, and the app verifies the
Access assertion itself (GENZO-17). Its bytes live in `trestle-genzo`, a second, PRIVATE
Trestle (`TRESTLE_PUBLIC_SERVE=false`, its own token list `TRESTLE_GENZO_TOKENS`) with no
port, no router and one network, `genzo_blob_net` — internal, isolated gateway,
plimsoll_ai's shape — whose only other member is `genzo`. All library data sits under
ONE host path, `${GENZO_DATA_DIR_HOST:-/srv/genzo}` (`trestle/` the originals, `inbox/`
the read-only drop folder, `derive-tmp/` the derivative worker's scratch), bind-mounted with `create_host_path: false` so the library
can move to a bigger drive by changing one variable. **The originals are not backed up
off-box** (owner-deferred; `docs/backups.md`). genzo runs `mem_limit: 3g` (2 derive jobs x 1024 MiB). `TRESTLE_TAG` now covers both Trestles.

## Healthchecks

**Docker computes health and acts on none of it.** `restart: unless-stopped`
restarts **exited** containers, not unhealthy ones, so a failing healthcheck has no
consequence on its own — switchyard sat at a failing streak of 12 through the
incident above while the deploy that caused it stayed green. `deploy.yml` now ends
with `scripts/assert-healthy.sh`, which is what that signal reaches; run it locally
with `make health-check`. A service with **no** healthcheck is the worse case, since
it cannot even be seen to fail — that is how interlock-worker stayed invisibly dead
— so the script lists those too. When adding a healthcheck, verify it can actually
**fail**: a probe that cannot load its driver, or a `bun -e` one-liner whose
`require` throws, exits 0 and reports healthy forever.
**A version subcommand is this bug in its most plausible disguise** (SERV-156). The
`asr` fragment arrived with `test: ["CMD", "asrd", "version"]`, which reads like a
liveness probe and is not one: it spawns a NEW process, so it proves the binary is in
the image and nothing about the one that is meant to be serving. Run in a bare
container with no GPU, no database, no config and no server it prints a version and
exits 0. Probe the HTTP surface instead — and check what the image can probe *with*
before assuming `curl`, since `asr` ships none of curl, wget, nc, python or busybox,
and `sh` is dash. `bash`'s `/dev/tcp` is the fallback, named explicitly because
`CMD-SHELL` is `sh`. Prove the new probe reports **unhealthy** against a dead port
before trusting it; a healthcheck is the one thing you cannot test by it passing.

## Recreate, never restart; `--no-deps`

**Recreate containers, never restart them.** `docker restart <svc>` keeps the
container's OLD spec, so mount, env, and image edits in `docker-compose.yml`
never take effect — the SERV-8 `/media-ssd` drift incident (2026-06-29). Use
`make recreate svc=<svc>`. `scripts/check-compose-drift.sh` exists to catch
the drift after the fact; it is not a substitute for getting it right.
**The same invariant has a second direction: an UNCHANGED spec holding an OLD
FILE** (SERV-159). Editing a bind-mounted config changes nothing on its own —
`up -d` recreates only what drifted, and a spec whose mount paths and pinned
image are unchanged does not drift, on the full path as much as the scoped one.
Worse, a **single-file** bind mount cannot be fixed by reloading either: `rsync
-a` renames a temp file over the target, so the inode the container is bound to
is replaced and the container keeps reading the old one — measured, not
reasoned. Every gate is green in that failure — `check-compose-drift.sh`
included, since it compares mount *sources* and the project root, neither of
which changed.
**The test is "a single-file bind mount whose consumer reads at startup", and
SIX files pass it** — `config/wiki/nginx.conf`, `config/traefik/traefik.yml`,
`config/crowdsec/acquis.yaml`,
`config/crowdsec/parsers/s02-enrich/argosy-hls-whitelist.yaml` (SERV-184),
`config/copyparty.conf` and `aperture/config.yaml`. Do not read Traefik as an exception: its file provider
watches the `dynamic/` **directory**, while `traefik.yml` is *static* config
with no reload path at all. Only `wiki` is handled — `deploy.yml` recreates it
when a commit touches `config/wiki/` — because it is the only leaf, with no
`depends_on` and no dependents. The rest are **SERV-164**, and traefik is the
one that matters: an unapplied edit there passes `assert-healthy`,
`check-compose-drift.sh` *and* `check-edge-auth.sh`, the last because it probes
the live edge and the live edge is still enforcing the old config. They are in
sync today only because none has been edited since its container was created;
`traefik.yml`'s last edit landed only because the same PR also changed
traefik's compose `environment`. Coincidence, not a mechanism.
**Scope a single-service recreate with `--no-deps`.** Compose follows
`depends_on`, and every service with a database depends on `postgres` — so an
action aimed at one container reaches the shared database and bounces every
service on the box. `docker compose up -d --force-recreate purser` recreated postgres too
(SERV-63, 2026-08-01); it recovered only because postgres came back in about a
second. `make recreate svc=<svc>` and `make force-recreate svc=<svc>` bake the
flag in — prefer them to a bare `docker compose` invocation. `deps=1` opts back
in for a genuine cold start, where the dependencies *should* come up.
