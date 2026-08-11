# CLAUDE.md — Construct Server

The Imperial Construct: a self-hosted home operations center. This repo is the
**stack definition**, not a service — `docker-compose.yml` plus the edge config,
database bootstrap, and Ansible that stand it up. The services themselves
(Argosy, Switchyard, Lyceum, Purser, Signet, Centrifuge, Interlock, Aperture,
Cook Book) live in their own repos and land here as images.

Tracked in Switchyard under the **SERV** project. Cross-service delivery design
lives in `docs/delivery-pipeline.md` (IDEA-19) — read it before changing how
anything deploys or gets versioned.

## Layout

- `docker-compose.yml` — the whole stack, ~30 services, single file.
- `docker-compose.dev.yml` — the `construct-server-dev` project (SERV-77): a second,
  isolated copy of switchyard/argosy/lyceum/purser with its own Postgres and
  network. See `docs/dev-environment.md`; drive it with the `make dev-*` targets.
- `config/` — Traefik, CrowdSec, and Copyparty config mounted into containers.
- `caddy/`, edge routing — public 443 paths and Cloudflare Access.
- `db/init-db.sh` — idempotent role/database bootstrap, runs on **every** deploy.
- `ansible/` — host-level ops (`ops/` playbooks, roles). Not container config.
- `scripts/check-compose-drift.sh` — the SERV-8 guardrail (see Invariants).
- `services/` — first-party service source that hasn't graduated to its own repo.
- `agent/rules/`, `bakeoff/` — local-model rules and the model bakeoff harness.
- `PRINCIPLES.md` — **cross-repo** estate defaults (languages, stack, release
  types, code quality). Unlike this file, it is not about this repo; it holds the
  standards every project inherits. **Read it before starting work here**, and
  prefer this file where the two disagree — repo invariants outrank estate
  defaults. Salvaged from imperium-loop (SERV-83).
- `creds/` — gitignored. Real credentials live here on the host and never in git.

## Conventions

- Conventional commits, with the Switchyard key in the subject:
  `fix(signet): render the sudoers rule via template, not copy content (SERV-62)`.
  Scope is the service or subsystem. Branches are `type/short-slug-serv-NN`.
- Release-please owns `CHANGELOG.md` and version bumps. Don't hand-edit either.
- Deploys are GitHub Actions on the self-hosted `imperial-construct` runner.
  `deploy.yml` fires on push to `main` touching stack paths; service repos fire
  `repository_dispatch`.
- Secrets the **stack** consumes reach it as `PROD_ENV_FILE`, a GitHub
  Environment secret on `home-server` — not a repo-level secret. Update it with
  `gh secret set PROD_ENV_FILE --env home-server`.
- Credentials only a **workflow** uses (the reviewer's tokens) are repo-level
  and managed by Signet: `signet set --project construct-server --name X`, then
  `signet target add --secret construct-server/X --gh-repo owner/name`, then
  `signet sync`. Rotation happens in the vault, not per repo. Moving these onto
  a GitHub Environment is intended but not done.
- Text files are LF via `.gitattributes` (SERV-52). A diff that looks like a
  whole-file rewrite is usually a line-ending regression.

## Invariants — don't break these

- **An empty environment variable is not a value.** Never let an unset or empty
  env propagate into compose or SQL as if it were set. `db/init-db.sh` learned
  this the hard way: Postgres stores an empty password as NULL, so
  `ALTER ROLE … PASSWORD ''` silently *blanks* the role and every SCRAM login
  fails with 28P01 — it bit Purser three times (SERV-33/40, #64). The same class
  of bug crash-looped Switchyard through an empty `SIGNET_API_TOKEN` (#74). The
  fix in both cases is to **skip loudly**, not to substitute a default: an
  existing role keeps working, and a missing one surfaces as a clear "can't
  connect" rather than silently broken auth.
- **Recreate containers, never restart them.** `docker restart <svc>` keeps the
  container's OLD spec, so mount, env, and image edits in `docker-compose.yml`
  never take effect — the SERV-8 `/media-ssd` drift incident (2026-06-29). Use
  `make recreate svc=<svc>`. `scripts/check-compose-drift.sh` exists to catch
  the drift after the fact; it is not a substitute for getting it right.
- **Scope a single-service recreate with `--no-deps`.** Compose follows
  `depends_on`, and every service with a database depends on `postgres` — so an
  action aimed at one container reaches the shared database and bounces every
  service on the box. `docker compose up -d --force-recreate purser` recreated postgres too
  (SERV-63, 2026-08-01); it recovered only because postgres came back in about a
  second. `make recreate svc=<svc>` and `make force-recreate svc=<svc>` bake the
  flag in — prefer them to a bare `docker compose` invocation. `deps=1` opts back
  in for a genuine cold start, where the dependencies *should* come up.
- **`db/init-db.sh` must stay idempotent.** It runs on every single deploy
  against the live Postgres. Anything that isn't safe to re-run belongs in a
  service's own migrator, not here.
- **The runner is a systemd service with a bare system PATH.** It never sources
  a login shell, so anything installed under `$HOME` — ansible, bun, node, fnm
  shims — is invisible to it. Add it via `$GITHUB_PATH` in a step and check for
  it explicitly so failures read as "not on PATH" rather than `command not
  found` from three layers down. SERV-62 hit this twice (#85).
- **The stack deploys from `/opt/construct-server`, and no other path** (SERV-76).
  Neither checkout on this box is what runs: `~/construct-server` is a plain git
  working copy, and the runner's `_work/…` directory is CI scratch that
  `actions/checkout` resets on every run — `pr-review.yml` fires on
  `pull_request`, so it regularly holds an *unmerged* PR merge ref. Both used to
  be bound compose projects at once, which is why "what is live" was a question
  you had to answer by inspection. `deploy.yml` now rsyncs the stack files to the
  deploy root and runs compose there; ansible bootstraps the same path. Editing
  `docker-compose.yml` in a checkout changes nothing until it is merged and
  deployed — `make recreate svc=<svc>` deliberately targets the deploy root from
  wherever you invoke it. **Adoption is gradual, so `docker compose ls` reporting
  more than one config file is expected for now, not a failed deploy**: a
  container keeps the root it was created from until it is next recreated, and
  nothing force-recreates the stack to hurry that along. Use
  `./scripts/check-compose-drift.sh`, which flags every container created from a
  foreign root, to see what is left; the list should only ever shrink. A *new*
  root appearing in that list is the real regression.
- **First-party image tags are pinned, and `PROD_ENV_FILE` holds the values**
  (SERV-74, SERV-88). Every first-party image reads `${<SERVICE>_TAG:-latest}`,
  one variable per source repo — backend and frontend ship from one release and
  pin together, so 10 variables cover 14 images. Services with release-please
  versions are pinned to **major.minor** (`LYCEUM_TAG=1.10`), so patch releases
  still flow in on a `docker compose pull` and nothing else does; argosy and
  drydock publish no semver and are pinned to a sha. Change a version by editing
  the secret (`gh secret set PROD_ENV_FILE --env home-server`), never by editing a
  checkout's `.env` — that is not what the stack reads.
  Only argosy and drydock are sha-pinned; every other first-party service tracks
  major.minor (amber and purser were the last two exceptions, reconciled by
  SERV-89).
  **A `sha-<short>` tag and a release tag can be different images from the same
  commit.** The publish workflow runs once on the push to `main` and again on the
  release tag, so it builds the same source twice, seconds apart, and the two
  digests differ. SERV-88 read that digest difference as purser running *ahead* of
  its release; it was not — `sha-2156151` and `0.13.0` both carried
  `org.opencontainers.image.revision=2156151434…`. **Compare the `revision` label,
  not the digest, before concluding anything about what code is deployed.** A
  digest comparison alone will invent version drift that does not exist, which
  matters for the delivery ledger and for rollback, where "is this the same code"
  is the whole question.
  The `:-latest` fallback is a bootstrap convenience and a hazard in prod, and
  both halves matter. It cannot simply be deleted: an unset **or empty** var
  interpolates to `image: …/argosy:`, which is neither an error nor `latest`, and
  a fresh host with no pins would stop starting. But left unguarded, a var dropped
  from the secret does not fail either — it silently floats that service back to
  `latest`. So the fallback stays *and* `deploy.yml` asserts on `docker compose
  config --images`, failing loudly if any first-party image resolves to `:latest`
  or a bare `:`. The two guard different things; neither supersedes the other, and
  a failing deploy is not fixed by deleting the check.
- **Watchtower is opt-in and no longer rolls first-party images** (SERV-75).
  `WATCHTOWER_LABEL_ENABLE=true` means it monitors only containers carrying
  `com.centurylinklabs.watchtower.enable=true` — currently four third-party
  leaves (dozzle, uptime-kuma, datadog, and itself). It previously monitored
  everything with per-service opt-outs as the only brake, which made a merge able
  to go live unattended Mondays at 04:00. Adding a service does **not** opt it in;
  `deploy.yml` is the deploy path. Watchtower will never call a reporting step, so
  anything it rolls is invisible to the delivery ledger in
  `docs/delivery-pipeline.md` — that is the argument against widening the list.
- **Dev is a separate compose project, and never points at prod** (SERV-77). It
  runs from `/opt/construct-server-dev` with its own Postgres, its own network
  (`construct_dev_net`) and its own secrets (`DEV_ENV_FILE` on the
  `home-server-dev` environment). A bare `docker compose` in this repo resolves to
  the **prod** file, so use the `make dev-*` targets, which pin the project name,
  compose file and env file together. Never copy the prod `.env` into dev: purser
  provisions real accounts across four services, so a dev purser with prod
  credentials does not fail safely — it succeeds, against production. **Nothing
  is on both networks**, which is what makes "dev cannot reach prod" true rather
  than merely intended. Do not attach Traefik to `construct_dev_net` to route
  dev hostnames: its `internal` entrypoint has no source restriction and the prod
  routers on it have no auth middleware (SERV-25 is unimplemented), so any
  container that can reach `traefik:9080` gets prod Switchyard and Lyceum by
  setting a Host header — Cloudflare Access is enforced at Cloudflare's edge, not
  here. Giving dev an edge is SERV-93. Isolation is asserted by
  `make dev-verify-isolation`; dev-vs-prod config drift by `make dev-parity`.
- **`creds/` and `.env` stay gitignored** (SERV-31, #55). Credentials belong on
  the host or in a GitHub secret. A secret that reaches a committed file, a
  build arg, or an image layer is a rotation, not a revert.
- **Render config files from templates, not copied content.** A sudoers rule
  written with `copy: content=` silently loses validation and ownership
  semantics that `template:` gives you (#84). This generalizes: if a file has a
  validator, wire it up.

## Validating a change

There is no test suite — this repo is configuration, so validation is mostly
"does the thing it configures still come up".

- `ansible-lint` runs in CI on `ansible/**`; run it locally before pushing.
- `docker compose config` catches compose syntax and interpolation errors.
- `./scripts/check-compose-drift.sh [service]` after any mount or env change.
- For edge or auth changes, the only real check is a request through the public
  path — internal container-to-container success proves nothing about Access.
