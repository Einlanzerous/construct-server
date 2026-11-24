# CLAUDE.md — Construct Server

The Imperial Construct: a self-hosted home operations center. This repo is the
**stack definition**, not a service: `docker-compose.yml` plus the edge config,
database bootstrap and Ansible that stand it up. The services live in their own repos
and land here as images. Tracked in Switchyard under the **SERV** project.

Read `PRINCIPLES.md` (cross-repo estate defaults) before working here; where the two
disagree this file wins. Rationale and history for most rules below live in `docs/`;
the pointer is on the rule. Cross-service delivery design is `docs/delivery-pipeline.md`
(read it before changing how anything deploys or gets versioned).

## Layout

- `docker-compose.yml` — the whole stack, one file.
- `docker-compose.dev.yml` — the `construct-server-dev` project: an isolated copy of
  switchyard/argosy/lyceum/purser with its own Postgres, network and edge. See
  `docs/dev-environment.md`; drive it with `make dev-*`. `dev-versions.env` holds
  `latest` for every service on purpose.
- `docker-compose.comfyui.yml` + `services/comfyui/` — a third, separate compose project
  (`make comfy-*`), not deployed by CI. Rules in `services/comfyui/CLAUDE.md`.
- `config/` — Traefik, CrowdSec, Copyparty config. `config/traefik-dev/` is the dev
  edge's own Traefik, not a leg of prod's.
- `db/` — `init-db.sh` (shared Postgres bootstrap) and `init-private-db.sh`
  (`postgres-private`, first init only). Details in `docs/stack-service-notes.md`.
- `ansible/` — host-level ops, not container config. Includes the `delivery_prober`
  role. The runner is registered by hand; ansible has no role for it.
- `scripts/` — deploy gates and checks; each `make` target below names its script.
- `tools/` — standalone programs (Go, and `tools/base-images`, TypeScript). Not synced to the
  deploy root and not in `deploy.yml`'s `paths:`, so changing one deploys nothing.
- `services/` — first-party source that has not graduated to its own repo
  (`cf-access-guard`, `comfyui`).
- `pkg/cfaccess/` — the estate's Cloudflare Access JWT verifier (nested `CLAUDE.md`).
- `backup-receiver/` — self-contained backup-destination bundle (nested `CLAUDE.md`).
- `wiki/` — generated estate wiki (nested `CLAUDE.md`).
- `agent/rules/`, `bakeoff/` — local-model rules and the bakeoff harness.
- `creds/` — gitignored; real credentials live on the host, never in git.

Service-specific wiring (satlink, genzo + trestle-genzo, plimsoll-llm, postgres-private)
is in `docs/stack-service-notes.md`. Safety rules for them:

- **Plimsoll** (`postgres-private`, `plimsoll-llm`) must never get a router, tunnel,
  public hostname or Access app. `plimsoll-llm` is held to an allowlist by
  `scripts/check-plimsoll-sandbox.py`; run `make plimsoll-llm-seed` before a deploy that
  adds it or moves its pin.
- **satlink, genzo** are `internal`-only routers with `cf-access-jwt`; the app verifies the
  assertion itself. `trestle-genzo` is private (no router, no port) and genzo's originals
  are not backed up off-box.
- Host bind mounts for satlink and genzo use `create_host_path: false`; install the host
  side before a deploy that adds or recreates the service.

## Conventions

- Commits, branches and release-please follow `PRINCIPLES.md` §3; text files are LF via
  `.gitattributes` (SERV-52). Scope is the service or subsystem; the Switchyard key goes
  in the subject.
- Deploys are GitHub Actions on the self-hosted `imperial-construct` runner. `deploy.yml`
  fires on push to `main` touching stack paths; service repos fire `repository_dispatch`.
- **Change a service's version with `promote.yml`** (Actions > Promote / Rollback), not by
  hand-editing `versions.env`. It verifies the tag, then commits; `deploy.yml` does the
  deploying, so there is one deploy path. Its gate is the `production-promote`
  Environment. The push to `main` needs `PROMOTE_PUSH_TOKEN` (a PAT; `GITHUB_TOKEN`
  cannot bypass the `Protect Main` ruleset), so `promote.yml` must never also dispatch
  `deploy.yml`. `PROMOTE_DISPATCH_TOKEN` lets Switchyard *ask* for a promote and nothing
  more. Rationale and the mint runbook: `docs/delivery-pipeline.md`.
- Stack secrets reach the deploy as `PROD_ENV_FILE` (Environment secret on `home-server`;
  dev: `DEV_ENV_FILE` on `home-server-dev`). **Signet renders both; never `gh secret set`
  them** — the next `signet sync` reverts it. Change the vault and sync. Workflow-only
  credentials are repo-level and also Signet-managed (`signet set`, `signet target add`,
  `signet sync`). See `docs/secrets-and-env.md`.
- **Do not retire the `imperium-loop` Signet project**: it still holds
  `RELEASE_BOT_APP_ID` / `RELEASE_BOT_PRIVATE_KEY`, targeting live repos. Read the TARGETS
  column of `signet status --project` before retiring any project.

## Invariants — don't break these

### Always

- **An empty environment variable is not a value.** Never let an unset or empty env reach
  compose or SQL as if set: Postgres stores an empty password as NULL, so
  `ALTER ROLE … PASSWORD ''` blanks the role. Skip loudly rather than substitute a default.
  A key that may legitimately be blank does not belong in `required-env-keys.txt`.
- **Recreate containers, never restart them.** `docker restart` keeps the OLD spec, so
  compose edits never apply. Use `make recreate svc=<svc>`; `scripts/check-compose-drift.sh`
  catches drift after the fact and is no substitute.
  The same applies to an **unchanged spec holding an OLD FILE**: editing a **single-file**
  bind mount (rsync replaces the inode) changes nothing until the container is recreated,
  and no gate notices. The files that pass this test: `config/wiki/nginx.conf`,
  `config/traefik/traefik.yml`, `config/crowdsec/acquis.yaml`,
  `config/crowdsec/parsers/s02-enrich/argosy-hls-whitelist.yaml`, `config/copyparty.conf`,
  `aperture/config.yaml`. Only `wiki` is recreated automatically by `deploy.yml`; after
  editing any other, recreate its container yourself (SERV-164 tracks the gap).
  Rationale and the SERV-159 measurements: `docs/stack-service-notes.md`.
- **Scope a single-service recreate with `--no-deps`**, or compose follows `depends_on` and
  bounces `postgres` and everything on it. `make recreate` / `make force-recreate` bake
  the flag in; `deps=1` opts back in for a cold start.
- **`db/init-db.sh` must stay idempotent**: it runs on every deploy against live Postgres.
  Anything not safe to re-run belongs in the service's own migrator. Never route a role
  through `ensure_db` if it must not hold `ALL PRIVILEGES` (chronicle's tier-1 role does
  not); `deploy.yml` gates on `chronicle tier1-audit` (chronicle 1.11 is the
  `CHRONICLE_TAG` rollback floor). catenary is provisioned by hand from its own repo. Details:
  `docs/stack-service-notes.md`.
- **Render config files from templates, not copied content.** `copy: content=` loses the
  validation and ownership semantics `template:` gives (a sudoers rule once did). If a file
  has a validator, wire it up.
- **`creds/` and `.env` stay gitignored.** A secret that reaches a committed file, a build
  arg or an image layer is a rotation, not a revert.
- **A credential is never a literal argument to a process** (visible in `ps`). Feed it by
  stdin or a named env var (`docker run -e NAME`, `curl -K -`, `htpasswd -Bi`). Masking is
  not a fix. See `docs/secrets-and-env.md`.
- **Dev is a separate compose project and never points at prod.** A bare `docker compose`
  here resolves to the **prod** file; use the `make dev-*` targets, which pin project,
  file and env. Never copy the prod `.env` into dev, and nothing is attached to both
  networks; a change that needs a container on both is the rejected design. Dev's edge
  gates on `DEV_CLOUDFLARE_TUNNEL_TOKEN`, which is an on switch only; removing it does not
  stop a running edge. Rationale: `docs/dev-environment.md`.

### Images and versions

- **First-party image tags are pinned in tracked `versions.env`** (`${<SERVICE>_TAG:-latest}`,
  one variable per source repo, major.minor for released services). `versions.env` is the
  source of truth for the values; this file states no values. Change a pin by merging a
  `versions.env` edit or via `promote.yml`, never via a secret or the deployed `.env`
  (its pin block is regenerated every deploy). Keep the `:-latest` fallback; `deploy.yml`
  asserts no first-party image resolves to `:latest`.
- **Signet pins in `versions-host.env`** (full release tag with `v`; it is a host binary
  with no image), never in `versions.env`, which would make each signet promote pull the
  whole stack. `deploy-signet.yml` deploys it.
- **Third-party images are pinned by digest** (`repo:tag@sha256:…`). A tag is not a pin.
  The four watchtower opt-ins (dozzle, uptime-kuma, datadog, watchtower) stay floating.
  Watchtower is opt-in and rolls no first-party image; adding a service does not opt it in.
- **`postgres` is pinned by digest and recreating it breaks the Node services**
  (switchyard, interlock-worker keep the old IP). Recover with `make force-recreate
  svc=<svc>`; expect to after bumping the pin.
- **A promote or rollback pulls only what it repointed** (`scripts/deploy-scope.sh`; it
  refuses rather than guesses, and every refusal falls back to the full pull). Every other
  deploy pulls the whole stack. After a failed or cancelled deploy, a later scoped promote
  does not converge the rest: re-run `deploy.yml` from the Actions tab.
- **Compare the image `revision` label, never the digest**, to decide whether two tags are
  the same code (`make versions`). `check-compose-drift.sh` does not see env or digest
  changes.
- Every first-party Dockerfile `FROM` names a supported cycle to cycle precision
  (`alpine:3.23`, never `alpine:3` or `latest`). `base-images.yml` checks it weekly and is
  not a deploy gate; `cf-access-guard`'s `golang:` pin is this repo's to keep current.
  The check, its CI wrapper and its publisher are one TypeScript program,
  `tools/base-images/` (Node 24, no runtime dependency; was bash until SERV-357).
  `docs/base-images.md`. The sweep's result is also published as `base-images.json` on
  the `estate-results` branch for Satlink: public repos only, schema 1, shape and the
  stability promise in `docs/base-images.md` "Machine-readable output".
- Pins and every detail above: `docs/image-pins.md`.

### Secrets and the environment

- **Signet owns `PROD_ENV_FILE` and nothing else.** The prod project has no host file
  target. The vault must never deliver a key `versions.env` owns, and a target with
  another writer or no consumer is worse than none. A new stack credential is `signet set`
  then `signet target add-key --project construct-server --gh-secret PROD_ENV_FILE`, and
  after `signet sync` a line in `required-env-keys.txt`. Do not detach and re-add the render
  target. `signet render --check` exits non-zero in the correct state; confirm with
  `make env-ownership-check` before following its advice. `docs/secrets-and-env.md`.
- **A key the vault does not hold does not exist.** `deploy.yml` and `deploy-dev.yml` run
  `scripts/assert-env-keys.sh` and fail before pulling if a key in `required-env-keys.txt`
  is missing or empty. Vault first, then the manifest.

### Deploy path and runner

- **The stack deploys from `/opt/construct-server`, and no other path.** The checkouts
  (`~/construct-server`, the runner's `_work`) are not what runs. Editing a checkout's
  compose file changes nothing until merged and deployed; `make recreate` targets the
  deploy root from anywhere. `docker compose ls` showing more than one config file is
  expected during adoption; `check-compose-drift.sh` lists foreign roots and that list
  should only shrink. `docs/runner.md`.
- **The runner has a bare system PATH.** Anything under `$HOME` (ansible, bun, fnm shims)
  is invisible; add it via `$GITHUB_PATH` and check for it explicitly. `node` is pinned for
  every runner by `scripts/runner-node-path.sh`; never copy another runner's `.path`.
  Runners are registered by hand.
- **Every runner shares one `$HOME` (user `magos`), so a job must never write a fixed path
  under `$HOME` or `/tmp`.** Use `$RUNNER_TEMP`. The reviewer and verifier run the host's
  `~/.local/bin/claude` via `path_to_claude_code_executable`, so `claude update`
  on the host is a CI version change. Do not fix collisions by serialising reviews or by
  per-runner `HOME` (SERV-190). `docs/runner.md`.
- **Docker computes health and acts on none of it.** `restart: unless-stopped` ignores an
  unhealthy container; `deploy.yml` ends with `scripts/assert-healthy.sh`
  (`make health-check`). A new healthcheck must be proven able to **fail** (against a dead
  port), and must probe the serving process over HTTP, not a `version` subcommand.
  `docs/stack-service-notes.md`.
- **The lint gate (`scripts/lint-gate.sh`) fails OPEN and never writes**, on purpose.
  `make lint-gate-test` is what shows it still blocks. `docs/lint-gate.md`.

### Edge and auth

- **The origin validates the Access JWT; reaching the entrypoint is not enough.** Every
  router on Traefik's `internal` entrypoint carries the `cf-access-jwt` forwardAuth
  middleware (`services/cf-access-guard`), which checks the AUD registered for that exact
  host in `CF_ACCESS_AUD_MAP`. A host with no AUD entry is refused. Exemptions are an
  allowlist of exactly two shapes: `switchyard-github-webhook` (one host, one **exact**
  `Path()`, HMAC-gated) and `placard` (one bare `Host()`, public by design, no AUD). Do not
  add a third or broaden either. `scripts/check-edge-auth.sh` enforces this and runs the
  spoofed-`Host` exploit against the live edge (`make edge-auth-check`; `--dev` for dev;
  `make edge-auth-test` proves it can go red). It is a post-deploy gate. For edge or auth
  changes the only real check is a request through the public path. `docs/origin-auth.md`.
- `cf-access-guard` is the one first-party image built on the box; `deploy.yml` builds it
  explicitly and identifies it by its `org.opencontainers.image.revision` label.
- **The remote MCP AUD lives in THREE places, and the third fails silently.**
  `MCP_CF_ACCESS_AUD` on `switchyard-mcp`, the `mcp.zerogravity.industries` entry in
  `CF_ACCESS_AUD_MAP`, and `CF_ACCESS_MCP_AUD` on **switchyard**. Miss the third and every
  remote tool call 401s with all gates green. `switchyard-mcp` holds no Switchyard token,
  is not named `CF_ACCESS_AUD` on purpose, and must never go behind `crowdsec-bouncer`.
  `docs/origin-auth.md`, runbook in `docs/zerogravity-edge.md` §4.
- **heitan (the MCP gateway) names its own AUD `HEITAN_CF_ACCESS_AUD`, never `*CF_ACCESS_GATEWAY_AUD`**:
  that suffix is how `check-edge-auth.sh` finds the backends that read the tag (`switchyard-mcp` and
  `switchyard` carry it; both must, or every forwarded call 401s green). `__HEITAN_ACCESS_AUD__`
  placeholders are `PEND` under `--config-only` and a FAIL in a deploy. `docs/zerogravity-edge.md` §5.
- **One Cloudflare Access verifier: `pkg/cfaccess`.** Never write or copy a second one.
- **The generated wiki's generator never reads a resolved environment** (see `wiki/CLAUDE.md`).

### The delivery ledger

- **The delivery ledger gets ONE host-side cron**: `delivery-prober.timer` runs
  `scripts/probe-delivery.sh` for the **dev** tier. A second producer is another `ExecStart`
  on that unit, never a second timer. A host daemon the in-process reconciler can already
  reach (signet) is not a producer. The prober's token is `deployments:observe`, never
  `deployments:write`; mint it with `scripts/mint-prober-token.sh`. The prober script lives
  in switchyard and is not vendored here. Adding a target requires the service to exist in
  Switchyard's inventory first. `docs/delivery-pipeline.md`.

## Validating a change

There is no test suite; this repo is configuration, so validation is "does the thing it
configures still come up". Per-check notes (when, why, failure modes):
`docs/validation-runbooks.md`.

- `ansible-lint` on `ansible/**` (also runs in CI).
- `make workflow-size` after editing any workflow: a `run:` block over 21,000 characters
  (comments count) stops the whole workflow loading. Prose goes in a YAML comment above the
  step.
- `docker compose config` for syntax and interpolation.
- Go modules: `docker build --build-context cfaccess=./pkg/cfaccess --target test -f
  services/cf-access-guard/Dockerfile services/cf-access-guard` runs both through the
  pinned toolchain (what CI does); `cd pkg/cfaccess && go test ./...` is the fast loop.
- `./scripts/check-compose-drift.sh [service]` after any mount or env change.
- `make health-check` / `make dev-health-check` (`assert-healthy.sh`); also a deploy gate.
- `make assert-tokens` / `make dev-assert-tokens` after anything that changes the rendered
  environment; both deploys gate on it.
- `make assert-env-keys` / `make dev-assert-env-keys` (`vault=1` to ask the vault) after a
  key-set change.
- `make env-ownership-check` / `make dev-env-ownership-check` after changing what the vault
  delivers. Host-side, not a deploy gate.
- `make promote-dispatch-check` (`vault=1`, `dispatch=1`) after minting or rotating
  `PROMOTE_DISPATCH_TOKEN`; cancel the run `dispatch=1` creates. See
  `docs/delivery-pipeline.md`.
- `make chronicle-upstream-check` after minting or rotating `CHRONICLE_SWITCHYARD_TOKEN`.
- `make base-images-check [dir=~/projects]` after editing any Dockerfile in any estate repo
  (from a checkout: `tools/base-images/` is not synced to the deploy root);
  `make base-images-test` proves it can fail and `make base-images-typecheck` checks the types.
  Fix `UNMAPPED` by extending `PRODUCT_MAP` in `tools/base-images/src/ref.ts`, never by an
  exemption.
- `gh workflow run verify.yml -f ticket=<key>` after touching the verifier, against a ticket
  whose answer you know: it goes green on `not_met`, so read the verdict, not the colour.
- `make lint-gate` / `make lint-gate-test` / `make lint-gate-install` / `make
  lint-gate-status`; re-install after pulling a change to `scripts/lint-gate.sh`.
- `make probe-status` / `make probe-delivery` after touching the prober or its role.
- `make runner-node-path` (`fix=1`, `restart=1`) after a reboot, runner registration or an
  `fnm default` change.
- `make versions` / `make dev-versions` for what is actually running (read the revision
  column).
- `make dev-edge-auth-check` (`config_only=1` from a checkout) after touching the dev edge;
  `make dev-verify-isolation` and `make dev-parity` for isolation and drift.
