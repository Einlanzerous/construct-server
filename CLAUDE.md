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
  Deployed by `deploy-dev.yml` (SERV-97), which pins nothing — `dev-versions.env`
  holds `latest` for every service on purpose.
- `config/` — Traefik, CrowdSec, and Copyparty config mounted into containers.
  `config/traefik-dev/` is the **dev** edge's own Traefik config (SERV-93) — a
  second edge in the dev compose project, not a leg of prod's.
- `caddy/`, edge routing — public 443 paths and Cloudflare Access.
- `db/init-db.sh` — idempotent role/database bootstrap, runs on **every** deploy.
  **Two services opt out and provision from their own repo**: chronicle (two roles
  plus the tier-1/tier-2 grant) and `asr` (its own database and role on the shared
  Postgres, not a schema inside Chronicle's — CHRN-25). Both run once by hand as
  superuser, so a cold host rebuild does **not** self-heal them and both crash-loop
  until it is done.
- `ansible/` — host-level ops (`ops/` playbooks, roles). Not container config.
  Includes `roles/delivery_prober`, the systemd timer that feeds the dev column
  of Switchyard's delivery matrix (SERV-111 — see Invariants).
- `scripts/check-compose-drift.sh` — the SERV-8 guardrail (see Invariants).
- `scripts/lint-gate.sh` — the pre-push lint gate (SERV-58): a Claude Code hook
  that runs a repo's own format/lint checks before `git push` and blocks on
  failure. Installed once at the user level by `make lint-gate-install`, so it
  covers every repo on the box. Design of record in `docs/lint-gate.md`.
- `.github/workflows/verify.yml` — the post-deploy verifier (SERV-80): a Claude
  Code job that reads a ticket's acceptance criteria and checks them against what
  is **running in dev**, where the PR reviewer checks the diff. It **records and
  does not gate** — a `not_met` verdict leaves the check green on purpose — and
  its verdict lands as a ticket comment rather than a plan review, because
  `plan_criteria.verdict` is one column per criterion and writing it would
  overwrite the plan review's. Design of record in `docs/verifier.md`; read it
  before wiring the structured write, which needs a schema change (SWY-189).
- `wiki/` — the generated estate wiki (SERV-101). A TypeScript generator plus a
  VitePress renderer; `wiki/docs/` is **generated and wiped on every run**. Design
  of record in `docs/estate-wiki.md`; see also the invariant below.
- `services/` — first-party service source that hasn't graduated to its own repo.
- `pkg/cfaccess/` — the **estate's** Cloudflare Access JWT verifier (SERV-131), a
  nested Go module imported by cf-access-guard, Lyceum and Chronicle. Decision of
  record in `docs/cf-access-verifier.md`; see the invariant below before writing
  another one.
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
- **To change what version a service runs, use `promote.yml`** (Actions > Promote /
  Rollback a Version) rather than editing `versions.env` by hand — same workflow for
  both directions, since "run this exact version" is one operation. It verifies the
  tag exists across every image behind the pin, then commits; `deploy.yml` fires on
  that commit and does the deploying, so there is still exactly one deploy path
  (SERV-78, SERV-79). Its approval gate is the `production-promote` GitHub
  Environment — deliberately **not** `home-server`, which would put a human in front
  of every ordinary deploy. A hand-edit of `versions.env` still works and still
  deploys; it just skips the registry check and the gate.
  It needs **two** things, and asserts both rather than failing obscurely: that
  environment must have a required reviewer, and `PROMOTE_PUSH_TOKEN` must exist.
  **The push to `main` needs a PAT and cannot use `GITHUB_TOKEN`.** `main` is
  protected by the `Proect Main` *ruleset* — not classic branch protection, which is
  why `branches/main/protection` returns 404 and it looks unprotected — and that
  ruleset's only bypass actor is the **admin** repository role. `GITHUB_TOKEN` acts as
  the `github-actions[bot]` app installation, holds no repository role, and its push
  is rejected with GH013. **Adding GitHub Actions to the bypass list is not possible
  here**: `Integration` bypass actors must belong to an organization and this repo is
  owned by a user, so the picker omits it and the API returns
  `422 … must be part of the ruleset source or owner organization`. A PAT
  authenticates as the admin user and bypasses via the existing entry, so no ruleset
  change is involved. One consequence: a PAT-authored push **does** fire `deploy.yml`
  on its own, where a `GITHUB_TOKEN` one would not — so `promote.yml` must never also
  dispatch `deploy.yml`, or every promote runs two concurrent deploys of the same
  commit.
  **A third credential lets Switchyard *ask* for a promote, and asking is all it can do**
  (SERV-104). `PROMOTE_DISPATCH_TOKEN` is a fine-grained PAT with `Actions: Read and
  write` on this repo, held by the switchyard container, which POSTs a
  `workflow_dispatch` to `promote.yml`. It is **not** `PROMOTE_PUSH_TOKEN` — that one is
  `contents: write`, lives on the `production-promote` environment, and is held by the
  workflow. The `production-promote` reviewer still gates every dispatched run, which is
  the whole reason a container may hold this at all; re-check that property, not the
  token's scope, before widening anything. Two things follow that are easy to get wrong.
  `repository_dispatch` would have been the familiar pattern and is the **wrong** one
  here: it needs `contents: write` on a fine-grained PAT, which could edit `versions.env`
  directly and skip the gate entirely. And `actions: write` has no narrower form than
  repo-wide, so this token can also dispatch `deploy.yml`, `deploy-dev.yml`,
  `deploy-signet.yml`, `wiki.yml` and `verify.yml`, cancel runs, and delete run logs —
  bounded because each of those converges the box to `main` rather than changing it.
  **It cannot approve its own gate**, which is the entry that would otherwise make the
  sentence above false: `POST /actions/runs/{id}/pending_deployments` is in the same
  `actions` namespace, and this environment has one required reviewer with
  `prevent_self_review: false` who is also the PAT's owner. Probed, not assumed — the
  POST returns **403 "Resource not accessible by personal access token"**, so
  fine-grained PATs are refused it whatever their `actions` permission says. Note the
  trap: the matching **GET returns 200 with `current_user_can_approve: true`**, because
  that field describes the account the token belongs to and not the token, so reading it
  and inferring the write would confirm a vulnerability that does not exist. Same lesson
  as `Actions: Read` vs `Read and write` below — only the mutating call answers.
  Unset, the token simply is not passed (bare passthrough) and Switchyard's promote gate
  stays the link-out to the Actions tab it is today. Design of record and the mint
  runbook: `docs/delivery-pipeline.md`.
  **`promote.yml` takes `requested_by`, and only an API dispatch should fill it.**
  `Delivery-Actor` is the ledger's only record of who asked and is set from
  `github.actor`, which for a PAT-created run is the *token's* owner — so without this
  input every Switchyard-initiated promote would be attributed to the credential.
  Blank means "trust `github.actor`", which is correct from the Actions tab. It is an
  **attestation, not an authentication**: whoever holds the dispatch token can put any
  string there, and that is acceptable only because it authorises nothing.
- Secrets the **stack** consumes reach it as `PROD_ENV_FILE`, a GitHub
  Environment secret on `home-server` — not a repo-level secret. Dev's equivalent is
  `DEV_ENV_FILE` on `home-server-dev`. **Both are rendered by Signet and neither is set
  by hand**: `construct-server` renders `PROD_ENV_FILE`, `construct-server-dev` renders
  `DEV_ENV_FILE`, and a `gh secret set` on either appears to work and is reverted by the
  next `signet sync` — live now, gone when something unrelated runs. Change the value in
  the vault and sync. Seed a project's render target from the **credential source**
  (`creds/dev.env`), never from the deployed `.env`: the deploy root already has a writer
  in `render-env.sh`, and it carries the `versions.env` tag pins, which belong to git
  (SERV-96) and must not acquire a second source in the vault. See
  `docs/dev-environment.md` and the ownership invariant below (SERV-94).
- Credentials only a **workflow** uses (the reviewer's tokens) are repo-level
  and managed by Signet: `signet set --project construct-server --name X`, then
  `signet target add --secret construct-server/X --gh-repo owner/name`, then
  `signet sync`. Rotation happens in the vault, not per repo. Moving these onto
  a GitHub Environment is partly done — `PROMOTE_PUSH_TOKEN` already targets the
  `production-promote` environment; the rest are still repo-level.
- Text files are LF via `.gitattributes` (SERV-52). A diff that looks like a
  whole-file rewrite is usually a line-ending regression.
- **The `imperium-loop` Signet project outlived imperium-loop, and must not be
  retired with it** (SERV-82). The pipeline's own containers, checkout and runner
  are gone, but that Signet project is also where `RELEASE_BOT_APP_ID` and
  `RELEASE_BOT_PRIVATE_KEY` live, and those target **six live repos** — purser,
  switchyard, lyceum, interlock, signet, amber. They are the release-please bot's
  credentials, so deleting the project to finish the decommission would break
  version bumps and changelogs across the estate, silently and not at deploy time.
  SERV-82 asked for exactly that and it was **not** done; only the pipeline's own
  secrets were retired. The name is the whole trap: it records where the credential
  was first minted, not what still uses it. Check `signet status --project` before
  retiring any project, and read the TARGETS column rather than the project name.
  Its `RELEASE_BOT_PRIVATE_KEY_PATH` also pointed into the deleted checkout
  (`~/imperium-loop/.secrets/release-bot.pem`) and was repointed at
  `~/.config/zerogravity/release-bot.pem` on the way out.

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
- **First-party image tags are pinned, and tracked `versions.env` holds the values**
  (SERV-74, SERV-88, SERV-96). Every first-party image reads
  `${<SERVICE>_TAG:-latest}`, one variable per source repo — backend and frontend
  ship from one release and pin together, so there are fewer variables than
  images. Services with release-please versions are pinned to **major.minor**
  (`LYCEUM_TAG=1.10`), so patch releases still flow in on a `docker compose pull`
  and nothing else does.
  **`versions.env` is the source of truth for which form each service uses.** This
  file states the rule and not the values, because duplicating them here is exactly
  what went stale: it claimed argosy and drydock "publish no semver" long after both
  were cutting releases normally, and someone reading it concluded the upstream repos
  had no releases and stopped looking (SERV-125).
  **Change a version by
  editing `versions.env` and merging it** — not with `gh secret set`, which is where
  these lived until SERV-96, and not by editing a deployed or checkout `.env`.
  An image tag is not a credential, and keeping the pins in git is what gives
  promote/rollback (SERV-78, SERV-79) something they can write: a workflow can commit
  with `contents: write`, but no `permissions:` scope lets it edit a secret at all —
  `secrets` is not one of them. It also makes a version change a reviewable diff and
  gives rollback its index for free (`git log -p versions.env`).
  The deployed `.env` is still the one complete environment compose reads:
  `scripts/render-env.sh` merges the secret and `versions.env` into it, so the
  Makefile targets, `check-compose-drift.sh` and a bare `docker compose` on the box
  all resolve the same values. The pins land below a marker comment in that file and
  are **regenerated every deploy** — editing them on the host is lost without warning.
  **A service is sha-pinned only when its repo publishes no semver image**, and no
  service is any more — every pin tracks major.minor. argosy and drydock were
  the last two, and the reason was never that they had no releases — they cut them
  normally (`v0.25.1`, `v1.7.0`). Their publish workflows asked for semver tags on
  `on: push: tags`, and that trigger had **never fired once** in either repo: release
  tags are cut by release-please under `GITHUB_TOKEN`, and GitHub creates no workflow
  runs from events that token authored. So the tag landed, nothing built, and no
  versioned image ever existed to pin to. **This repo already knew that rule from the
  other side** — it is why `promote.yml` must not also dispatch `deploy.yml`, since a
  PAT-authored push fires it where a `GITHUB_TOKEN` one would not. Fixed upstream in
  SERV-125 by calling publish from the release-please run instead, the same shape
  aperture and lyceum already used; amber and purser were the two before them
  (SERV-89).
  Note what the sha pins cost while they lasted, because it is the argument for not
  accepting the next one: no patch float, a `git log -p versions.env` rollback index
  that reads as a list of hashes, and nothing to promote *to* — "promote argosy to
  0.25" was not expressible.
  **A `sha-<short>` tag and a release tag can be different images from the same
  commit.** A release builds the same source twice, seconds apart — once for the push
  to `main` and once for the release — so the two digests differ. SERV-88 read that
  digest difference as purser running *ahead* of its release; it was not —
  `sha-2156151` and `0.13.0` both carried
  `org.opencontainers.image.revision=2156151434…`. **Compare the `revision` label,
  not the digest, before concluding anything about what code is deployed.** A
  digest comparison alone will invent version drift that does not exist, which
  matters for the delivery ledger and for rollback, where "is this the same code"
  is the whole question.
  **Dev pins separately, to `latest`, and that is not an oversight** (SERV-97).
  `dev-versions.env` is a second file with a `DEV_` prefix on every variable, every value
  `latest`. Dev's job is to run what just merged; sharing prod's variable names would mean
  a misplaced prod `.env` silently pins dev to prod's versions, where distinct names make
  that inert. Note that **a floating tag is not a floating container**: the image string
  never changes, so compose sees no drift and `up -d` alone moves nothing however far main
  has gone. Dev advances only on a `pull`, which is what `deploy-dev.yml` does hourly.
  **Signet pins in `versions-host.env`, and the separate file is forced rather than
  chosen** (SERV-130). It is the one first-party service that is a host binary under
  systemd, so it has no image, no registry tag and no compose service.
  `deploy-scope.sh` maps every changed pin in `versions.env` onto compose services and
  **refuses** one that no image interpolates — and its caller correctly reads any refusal
  as "pull the whole stack", so a `SIGNET_VERSION` in `versions.env` would make each
  signet promote pull and recreate the whole prod stack. That is the SERV-109 regression
  arriving through the file that guards it, and the fix is a second file rather than an
  exception in the script: its safety rests on *every* failure meaning pull-everything,
  and an exception would silently swallow the real cases too — a pin later typo'd, or one
  whose service leaves compose, both map to zero services as well. Two further
  differences follow from there, and neither is a style choice: the value is a **full
  release tag with its `v`** (`v1.9.1`) because `gh release download v1.9` has no
  registry to resolve a patch against, and `promote.yml` verifies it against the
  **releases API including the asset**, because `verify-tag.sh` reads manifests and a
  tag with nothing built behind it is the SERV-125 shape. Everything that *compares*
  versions strips the `v`: signet reports bare since SGNT-38 and the ledger compares
  with strict equality. `deploy-signet.yml` carries the path trigger, so `deploy.yml`
  never fires on it. **A signet release no longer deploys itself** — `signet-released`
  announces that a version is available and nothing more.
  **Third-party images are pinned by digest** (SERV-105), in the form `repo:tag@sha256:…`
  inline in `docker-compose.yml` — the tag is provenance, the digest is the pin. Before it,
  `docker compose pull` moved every floating tag, and the first real rollback recreated
  purser, ollama and semaphore when only purser was asked for.
  A "stable-looking" tag is not a pin —
  `traefik:v3.3` moves on patch releases and `crowdsec:v1.7.8` can be rebuilt in place,
  the same trap as `postgres:16.15-alpine`. **The four watchtower opt-ins stay floating**
  (dozzle, uptime-kuma, datadog, watchtower): watchtower is their update path and it cannot
  roll a digest-pinned container, so pinning them disables the mechanism rather than making
  anything deliberate.
  **A promote or rollback pulls only what it repointed** (SERV-109) — pinning alone could
  not deliver that, because the major.minor pins above are moving tags *by design*, so a
  whole-stack `docker compose pull` moved every first-party service that had published
  since the last deploy. A purser rollback recreated lyceum if lyceum cut a patch in the
  meantime, which is worse than the third-party leaf case since these have dependents.
  `deploy.yml` now asks `scripts/deploy-scope.sh` whether the commit range touches
  `versions.env` and **nothing else** — the exact shape `promote.yml` writes — and if so
  pulls and recreates only the services behind the pins that actually moved, `--no-deps`.
  **Every other deploy still pulls the whole stack**, deliberately: that is where the patch
  float is supposed to land. Three things this does *not* bound, and do not write that it
  does: four of the thirteen pins cover more than one service and recreate together —
  `SWITCHYARD_TAG` covers **three** (backend, frontend and `switchyard-mcp`, SERV-99),
  while `APERTURE_TAG`, `CENTRIFUGE_TAG` and `INTERLOCK_TAG` (web + worker) cover two
  each; the pin is still major.minor, so rolling back to `0.13` gets
  the newest `0.13` patch and **not necessarily the image prod ran the last time it was on
  `0.13`**; and a version bump merged inside a larger PR is not a pure pin change, so it
  takes the whole-stack path. The script **refuses rather than guesses**, and every refusal
  falls back to the full pull — the dangerous direction is a scope that narrows to nothing,
  which would be a deploy that goes green having shipped no change at all. The cost of the
  trade: a scoped deploy converges nothing it did not name, so once an earlier deploy has
  left a change unapplied — it **failed**, or it was **cancelled while still queued**, since
  `concurrency` supersedes a pending run and `cancel-in-progress: false` protects only the
  running one — a later promote's green tick no longer means the stack matches `main`. The
  cancelled case leaves nothing red in the Actions tab, so nothing prompts you to look. `cf-access-guard` is
  the one exception, checked explicitly by revision, because it is the one service where a
  stale binary passes every gate — `assert-healthy` sees a healthy container and
  `check-edge-auth` sees the old binary still refusing a spoofed `Host`. Settle the rest by
  re-running `deploy.yml` from the Actions tab — a `workflow_dispatch` carries no push
  range, so it always takes the full path. **Not** with `check-compose-drift.sh`, which
  compares mounts and the compose project root and nothing else, so an unapplied env or
  digest change is invisible to it.
  The `:-latest` fallback is a bootstrap convenience and a hazard in prod, and
  both halves matter. It cannot simply be deleted: an unset **or empty** var
  interpolates to `image: …/argosy:`, which is neither an error nor `latest`, and
  a fresh host with no pins would stop starting. But left unguarded, a var dropped
  from `versions.env` does not fail either — it silently floats that service back to
  `latest`. So the fallback stays *and* `deploy.yml` asserts on `docker compose
  config --images`, failing loudly if any first-party image resolves to `:latest`
  or a bare `:`. The two guard different things; neither supersedes the other, and
  a failing deploy is not fixed by deleting the check.
- **Signet owns `PROD_ENV_FILE` and nothing else — the prod project has no host file
  target** (SERV-94). The vault renders one thing, the `home-server` environment secret;
  `deploy.yml` turns that into `/opt/construct-server/.env` via `render-env.sh` and is
  the only writer of the credentials in it — ansible re-renders the *pin block* of that
  same file in place on a cold host, which is a reconcile of git's values and not a
  second source. Signet used to claim the path as well, and that one is a second source:
  drift stops being a state you can read and becomes a race, and `signet target list` sat
  at `changed` for a week and a half saying so with nobody able to act on it. It claimed `~/construct-server/.env` too — a third copy that stopped driving
  anything when SERV-76 moved the deploy root, and which reported `in sync` the whole
  time, because a render against a file nothing reads always succeeds. **A target whose
  destination has another writer, or no consumer, is worse than no target**: both report
  a state that means nothing, and the second one reports it in green.
  **The vault must never deliver a key `versions.env` owns.** It delivered all ten from
  2026-08-15, when SERV-96 moved the pins to git and the vault kept its copies, until
  SERV-94 detached them — and eight had gone stale in that time. Nothing broke, for one
  reason: `render-env.sh` strips every key the versions file defines from the base
  before appending the tracked pins, so git won every time. That is a mitigation sitting
  in one script, not a property — take `render-env.sh` out of the path, or let the vault
  become the sole source, and prod silently rolls back every service whose vault copy
  went stale. `deploy.yml`'s SERV-88 assertion would **not** catch it: a stale pin is a
  real version, not `:latest`. The strip now names what it dropped instead of doing it
  silently, and `make env-ownership-check` asks the vault directly so the answer does
  not depend on that script still being there.
  **Signet actively recommends the wrong fix here, and it does so in red.** `signet
  render --project construct-server --check --against /opt/construct-server/.env` exits
  **non-zero in the correct state**: it reports `WOULD DROP 11 key(s)` and ends `import
  them into the vault, then signet target add-key …`. Both are right in general and
  wrong for anything git owns, and following that advice re-creates the exact hazard.
  The check compares the vault against the *deployed* file, and the deployed file is the
  render **plus** what `render-env.sh` appends — so a healthy pipeline reads as a
  shortfall. Dev's copy of this reports the same way over its four `DEV_*_TAG` keys. The
  answer to a report like that is to confirm the dropped set is **exactly** the versions
  file and nothing else — a credential in that list is a real problem — which is what
  `make env-ownership-check` asks and exits 0 on.
  Two consequences of having no file target, both easy to trip over:
  **`import` no longer widens the key set**, because what `import` widens is a *file*
  target's. A new stack credential is `signet set --project construct-server --name X`
  followed by `signet target add-key --project construct-server --gh-secret
  PROD_ENV_FILE --name X` — `signet set` alone mints a value that reaches nothing, which
  is how four secrets in this project came to have no destination at all. And
  **do not detach the render target and re-add it**: `--seed-from` reads a file target's
  key set, there is no longer one to read, and an unseeded rendered target is created
  with an *empty* key set. Use `target add-key` to change what it delivers.
  **Dev's allowlist is deliberately not empty**: `construct-server-dev` keeps
  `creds/dev.env`, the readable credential source it was seeded from, which
  `deploy-dev.yml` never writes. One writer, so it is a state and not a race.
- **`postgres` is pinned by digest, and recreating it breaks the Node services**
  (SERV-102). Every first-party service depends on the one postgres container, so
  it has the largest blast radius in the stack — and under the old floating
  `16-alpine` tag it was recreated whenever upstream published, on a
  `docker compose pull` aimed at something else entirely. When that happened on
  2026-08-15 postgres moved to a new address on `construct_net` and **switchyard and
  interlock-worker never recovered**: Go's drivers re-resolve DNS per connection
  attempt, but Node/Bun's `pg-pool` caches the container IP and retries the dead one
  forever. The split is by runtime, not by service. Recovery is
  `make force-recreate svc=<svc>` — a plain `make recreate` is a no-op, because the
  container spec has not changed. Bumping the pin is a real upgrade, not a
  version-string edit: expect to force-recreate the Node services afterwards until
  they re-resolve on error (SWY-267, ITLK-30). Third-party *leaf* images still float
  by design; postgres is pinned because it is shared.
  **A digest, not a patch tag** — `16.15-alpine` is itself mutable, and upstream had
  already rebuilt it (prod ran `sha256:44c4ee98…` while the tag pointed at
  `sha256:075f7ba6…`, both reporting 16.15). A patch-tag pin looks precise and still
  moves. Note also that **any** edit to the image string costs one recreate even when
  the image is byte-identical: compose decides from the literal spec, not from what it
  resolves to.
- **Docker computes health and acts on none of it.** `restart: unless-stopped`
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
  compose file and env file together. `deploy-dev.yml` calls those same targets
  rather than restating the flags (SERV-97) — ansible creates the dev root and the
  dev network, the workflow owns steady state, the same split as prod. Never copy the prod `.env` into dev: purser
  provisions real accounts across four services, so a dev purser with prod
  credentials does not fail safely — it succeeds, against production. **Nothing
  is on both networks**, which is what makes "dev cannot reach prod" true rather
  than merely intended.
  **Dev has its own edge, and that is why the sentence above still has no
  exceptions** (SERV-93). `traefik-dev`, `cf-access-guard-dev` and `cloudflared-dev`
  live in the dev project on `construct_dev_edge_net` (172.31.241.0/24), with a
  second Cloudflare tunnel and dev's own Access applications. The cheaper option —
  attaching prod's Traefik to `construct_dev_net` — was by then no longer dangerous:
  `internal` binds a single address on `construct_edge_net` that only cloudflared
  shares (SERV-107), every router on it validates the Access JWT at the origin
  (SERV-106), and a dev hostname absent from `CF_ACCESS_AUD_MAP` fails closed. It was
  rejected anyway, because it needs a **carve-out** in "nothing outside the dev
  project is attached to `construct_dev_net`" — and that check exists precisely
  because the exception was made once before. Trading a property that holds
  structurally for one that holds while a middleware stays correctly attached is the
  wrong direction. **If a change starts needing a container on both networks, that is
  the rejected design arriving by the back door.**
  The dev edge mirrors prod one tier down and drops what dev must not hold: no
  `public` entrypoint, no ACME (so no `CF_DNS_API_TOKEN` in dev), no CrowdSec, no
  dashboard, and **no exemptions from origin auth at all** — prod's one exemption is
  the GitHub webhook, and dev holds no webhook secret. Only switchyard and lyceum get
  hostnames; **argosy deliberately does not**, because video does not traverse the
  tunnel (the same reason prod Argosy gets a direct WAN path) and dev shares prod's
  media read-only. Dev services still carry no `CF_ACCESS_*` of their own, so in-app
  SSO stays off — dev is reached *through* Access at the edge, not by trusting an
  Access JWT internally.
  **The edge is gated on its own credential, not on a flag.** The three services carry
  `profiles: [edge]` and the Makefile enables that profile exactly when
  `DEV_CLOUDFLARE_TUNNEL_TOKEN` is non-empty in the deployed dev `.env`. Half of
  SERV-93 is a Zero Trust dashboard change no file here can make (a second tunnel, one
  Access application per hostname, its AUD into `CF_ACCESS_AUD_MAP` on
  `cf-access-guard-dev`), and an empty `TUNNEL_TOKEN` does not disable cloudflared —
  it crash-loops it. The runbook is in `docs/dev-environment.md`; do not re-derive it.
  **The credential is an on switch; compose does not make it an off switch.**
  `up -d` with a profile off does NOT stop the containers that profile created — they
  stay `Up` and are not orphans. So removing the token leaves a live edge serving while
  every intent-based check calls it "not deployed", which takes the auth assertion
  silent over a running origin. `make dev-up` reconciles (see `dev-edge-down`), and
  `make dev-edge-auth-check` keys off what is **running** rather than off the token:
  if something is serving, it gets probed. Do not re-gate that check on the token.
  Isolation is asserted by `make dev-verify-isolation` — which now probes
  **reachability** from the dev network with a positive control, not just attachment,
  because attachment is a proxy and proxies are what let SERV-25's deferral hide for
  six weeks. Dev origin auth is `make dev-edge-auth-check`; dev-vs-prod config drift is
  `make dev-parity`.
- **The origin validates the Access JWT — reaching the entrypoint is not enough**
  (SERV-106). Cloudflare Access is enforced at Cloudflare's **edge**. The origin
  used to re-check nothing, so anything that could connect to Traefik's `internal`
  entrypoint got the tunneled apps by naming one in a `Host` header; that was
  demonstrated, not theorised, and returned unauthenticated prod Switchyard. Every
  router on that entrypoint now carries the `cf-access-jwt` forwardAuth middleware,
  pointed at `cf-access-guard` (`services/cf-access-guard/`), which verifies the
  token against the team's published signing keys and **the AUD registered for that
  exact host**. Per-host matters: every app on the team domain is signed by the same
  key, so a single static audience would let a wiki token open Switchyard.
  **SERV-107 did not close this and neither closes the other.** The bind decides who
  can *connect*; the middleware decides who is *served*. "Unroutable" is not
  "rejected" — conflating them is how SERV-25's deferral stayed invisible for six
  weeks. A host with no AUD entry is refused, so a new tunneled router that nobody
  mapped is unreachable (loud) rather than unauthenticated (silent), and
  `scripts/check-edge-auth.sh` fails if a router lacks the middleware or the map and
  the routers disagree. **Exemptions are an allowlist, not a pattern, and there are
  exactly two, of two different shapes.** `switchyard-github-webhook` is one host and
  one **exact** `Path()`, because GitHub cannot authenticate to Access — Access
  carries a Bypass policy on that path and injects no assertion at all, so without
  an exempt router the webhook 403s and external-ref updates and PR-merge auto-close
  stop silently (SERV-45). It is not unauthenticated; it is HMAC-gated by
  `GITHUB_WEBHOOK_SECRET`, which is authentication Access cannot express. `placard`
  is one bare `Host()` — **whole-host, public by design** (IDEA-22 / PCAD-5): every
  surface it serves is contractually fetchable with no session, its content mirrors
  a public GitHub repo, and its one write path is token-gated in the app. The
  checker verifies each shape differently: an exact-path exemption must bypass the
  guard on that path while the rest of the host still 403s; a whole-host exemption
  is asserted **inverted** — a sessionless request must get a 200 with the guard
  uninvolved, and the host must carry **no AUD** (an Access application on a host
  the origin serves openly is the edge and origin disagreeing). Anything broader
  than those two shapes — a `PathPrefix()`, multiple hosts, an OR — is refused as
  too broad to verify, and an internal router that is neither gated nor on the
  allowlist fails the check. It also runs the exploit itself against the live edge, from
  the **host** — an unpublished container port is still routable from there, which no
  container-side probe sees. `--dev` points the same script at the dev edge (SERV-93)
  rather than there being a second copy of it — one question, one implementation, and
  the only difference in substance is that dev's exemption allowlist is empty. `deploy.yml` runs it as a post-deploy gate; locally it is
  `make edge-auth-check`. The guard is the one first-party image **built on the box**
  rather than pinned (stdlib-only Go, no deps), so `deploy.yml` builds it explicitly —
  `up -d` alone would keep running a stale image without complaint. Its image carries
  `org.opencontainers.image.revision`, stamped at build time from
  `git log -1 -- services/cf-access-guard pkg/cfaccess` (SERV-109, widened by SERV-131 —
  the guard's behaviour is partly in the shared module now, so a revision taken from the
  service directory alone would call a stale guard current after a module-only change). That label is the guard's **only** identity: it has no pin, and
  its image ID is useless for comparison because BuildKit re-exports the config on every
  build, so a full cache hit still yields a new ID. Recreating on an ID difference would
  bounce the auth path on every deploy; recreating on a revision difference bounces it
  exactly when the source moved.
- **The remote MCP endpoint is a tunneled host like any other, and its AUD variable is
  deliberately not `CF_ACCESS_AUD`** (SERV-99 / SWY-260). `switchyard-mcp` serves
  Switchyard's MCP tool surface over Streamable HTTP at `mcp.zerogravity.industries`, so
  a **hosted** Claude surface can reach it — those connect from Anthropic's cloud, not
  from the user's device, which is why the local stdio MCP cannot serve them. It reads
  `MCP_CF_ACCESS_AUD`, because Access audiences are per-application and this endpoint is
  its own application; a `CF_ACCESS_AUD` sitting beside it in the same env file is
  ignored on purpose, and reusing switchyard's would let a Switchyard session drive the
  MCP. **It holds no Switchyard token at all** — every session exchanges its own Access
  assertion at `POST /v1/auth/sso/cloudflare` for the real person's token, so a tool call
  lands attributed to them rather than to a shared identity, and the image refuses to
  read a process-wide token. Two consequences that are easy to miss: it ships on
  switchyard's release train, so `SWITCHYARD_TAG` now covers **three** services and
  carries a **rollback floor of 4.18** (the mcp image's first release — `verify-tag.sh`
  refuses anything below it rather than half-deploying); and it must never go behind
  `crowdsec-bouncer`, since Anthropic's egress is one narrow range hitting one endpoint
  repeatedly and a single decision against it breaks every remote tool call at once.
  That last one needs no guarding — the bouncer is attached per-router on `public` only.
  The Zero Trust half (the Access application, its **Managed OAuth**, the tunnel
  hostname) is SERV-100 and no file here can make it; without Managed OAuth an
  unauthenticated request gets a `302` to a login page where Claude needs a `401` with
  `WWW-Authenticate: … resource_metadata="…"`, which is why the earlier attempts failed.
  Runbook: `docs/zerogravity-edge.md` §4.
  **That one AUD tag lives in THREE places and the third is the one that fails silently.**
  `MCP_CF_ACCESS_AUD` on `switchyard-mcp`, the `mcp.zerogravity.industries` entry in
  `CF_ACCESS_AUD_MAP` on `cf-access-guard`, and `CF_ACCESS_MCP_AUD` on **switchyard** —
  which is what lets the SSO exchange accept an assertion minted for the MCP application,
  since the MCP holds no token and forwards each caller's JWT to
  `POST /v1/auth/sso/cloudflare` verbatim. Miss the third and Access authenticates, the
  guard passes, the container is healthy, `check-edge-auth` passes and `assert-healthy`
  is green while **every remote tool call 401s** — the only evidence being a line in
  switchyard's own request log. That was SERV-99's actual bug. All three are now
  cross-checked by `check-edge-auth.sh` (SERV-161); note the first two are compared by a
  regex sweep over names *ending* in `CF_ACCESS_AUD`, which structurally cannot see the
  third, so it is asserted by name and widening that pattern is not the fix — it would
  also swallow `CF_ACCESS_AUD_MAP` and compare the map against itself.
- **There is ONE Cloudflare Access verifier, and it is `pkg/cfaccess`** (SERV-131).
  Do not hand-roll a second one, and do not copy this one into a service. There
  were three Go copies, written by copying, and they drifted: Lyceum's lacked the
  `len(e) > 8` exponent bound, so a JWKS key with a nine-byte exponent sliced a
  fixed buffer at index `-1` and **panicked the process** — remote input, security
  path, no `recover` (LYCM-122). Nobody was wrong at any point, which is the
  problem: the copy was correct when it was made. Chronicle was green only because
  a review caught it mid-flight. Consumers `go get` it by tag —
  `pkg/cfaccess/v0.1.0`, and the `tag-separator: "/"` in
  `release-please-config.json` is what makes that form resolvable at all, not a
  cosmetic choice. **cf-access-guard is the one exception**, tracking HEAD through
  a path `replace`, which is also what keeps its build hermetic; it therefore
  reaches the guard's Docker build as a **named build context**, never by widening
  the context to the deploy root — that root holds the rendered `.env`.
  Switchyard stays on `jose` deliberately: replacing a maintained library with
  estate code is the wrong direction, and the cross-language check is
  `pkg/cfaccess/testdata/vectors.json`, shared vectors that **both** suites run.
  A `class: protocol` vector must hold in any conforming verifier; `keypolicy`
  ones are estate hardening a general JWT library need not enforce, and a
  legitimate difference is recorded in `expectBy` rather than skipped.
- **The wiki is generated, and its generator must never read a resolved
  environment** (SERV-101). `wiki/docs/` is wiped and rewritten on every run, so a
  hand-written page there is deleted without warning — anything a person wants to
  write belongs in the relevant repo's `CLAUDE.md`, or in tier 2 (IDEA-21). The
  generator parses the **raw** `docker-compose.yml` and never `docker compose
  config`, never a `.env`: the resolved view interpolates every variable, so
  reading it would publish the contents of `PROD_ENV_FILE` onto a Markdown page.
  The tracked compose file holds no secret by construction, which is the entire
  safety argument — env tables therefore show variable *names*, and values only
  where the tracked file spells one out. It also parses raw in order to keep
  **comments**, which are the best documentation in that file and which
  `docker compose config` discards. Build it in a container (`make wiki-build`), not
  against host node.
  **A repo's system map is the one thing on a wiki page that a person authors, and
  it is authored in that repo** (SERV-159). A repo that commits
  `docs/architecture.archify.json` gets an interactive map on its page, rendered at
  build time by the vendored archify in `wiki/vendor/archify` — pinned per SERV-91,
  and vendored because it is `private: true`, is not on npm, and its repository root
  has no `package.json`. That does not bend the rule above: the IR is a source file
  in the repo it describes, the same category as that repo's `CLAUDE.md`, and the
  render is the generator's job. Nothing hand-made reaches `wiki/docs/`.
  Two consequences. **The build container is `node:22` and not `node:22-alpine`**,
  because archify verifies each component's `SRC` links against the pinned commit
  with `git cat-file` before it will render — alpine ships no git, and `apk add git`
  is unavailable to a container deliberately running `--user $(id -u)`, besides
  being the floating install SERV-91 exists to stop. Note that the Debian image
  *carries* git rather than pinning it: `node:22` is a moving tag, so the git behind
  it changes with no edit here — the same trap as `traefik:v3.3`. And **a map can never fail the
  build**: every failure becomes a warning block on that repo's page carrying
  archify's own diagnostic, and is named in the build log. The IRs are written in
  other repos, so the alternative is the estate wiki ceasing to publish because
  somebody moved a node in switchyard. Design of record: `docs/estate-wiki.md`.
- **The delivery ledger gets ONE host-side cron, whatever the producer count**
  (SERV-111). `delivery-prober.timer` runs `scripts/probe-delivery.sh` every 5
  minutes, which probes the **dev** tier over loopback and posts what it saw to
  Switchyard. It exists on the host because Switchyard's in-process reconciler
  sits on `construct_net` and dev sits on `construct_dev_net` — it covers prod
  and structurally cannot cover dev, and bridging the two to fix that would undo
  SERV-106/107 for a status page. The host can reach both, so the probe runs here
  and posts inward. **A second producer attaches as another `ExecStart` on that
  same unit** — SWY-194's container-inspect collector is the next one — sharing
  the timer, the `EnvironmentFile` and the one token. Two host jobs with two
  configs writing one ledger is how they disagree at 3am with nothing to say
  which was stale; `probe-delivery.sh` takes the in-image script path as `$1` so
  the second producer reuses it.
  **A host daemon the reconciler can already reach is NOT a producer, and signet
  is the case that settles it** (SERV-128). The obvious reading of the rule above
  is that anything on the host becomes another `ExecStart`; for signet that is
  wrong twice over. The prober posts under one `PROBE_ENVIRONMENT` for the whole
  unit, and signet is not dev — while `prod` is `probe_mode: internal`, so ingest
  **400s** an external probe result for it (`environment … is probed internally`).
  A third `ExecStart` could therefore only file signet under a tier it does not
  run in, or need a whole new environment column. Meanwhile signet binds
  `172.17.0.1` deliberately — its `Serve()` refuses to start if the docker-bridge
  bind fails, precisely so it cannot come up answering the host while refusing
  every container — so the in-process reconciler can simply probe it. It is
  registered as an ordinary first-party service on port 4010 and observed in the
  **prod** column, with `extra_hosts: signet:host-gateway` on the switchyard
  container making prod's `http://{service}:{port}` template resolve. No new cron,
  no new environment, and the one-cron rule is untouched because nothing was
  added to the host at all. The per-pair `host_override` column looks like the
  intended seam for this and is not usable: no API writes it, and its row does not
  exist until after the first probe has already been recorded at the wrong address.
  **Its token carries `deployments:observe` and never `deployments:write`.** A
  report is a claim, an observation corroborates it, and
  `claimed_not_confirmed` only means something if corroborating is the harder of
  the two — a prober that could report would confirm its own claims. Mint it with
  `scripts/mint-prober-token.sh`, which **asserts** the granted scopes: the server
  defaults to `admin` when `scopes` is omitted, so a typo in the field *name*
  mints a working admin token and nothing ever surfaces it.
  The prober script itself is **not vendored here** — it lives in switchyard's
  `server/scripts/` and is run out of the image the live switchyard container is
  already using, so prober and ingest are always the same build. That is also why
  `scripts/**` is a `deploy.yml` path trigger: the unit executes
  `$DEPLOY_ROOT/scripts/probe-delivery.sh`, so a wrapper fix that never deploys
  leaves the box running the old copy.
  **Adding a target requires the service to exist in Switchyard's inventory
  first.** A probe that got no usable answer deliberately does not auto-register
  one (SWY-284) — "down" and "misspelled" are indistinguishable from outside — so
  an unknown name 404s every run, which the wrapper treats as a hard failure.
- **The pre-push lint gate fails OPEN, and must keep doing so** (SERV-58).
  `scripts/lint-gate.sh` blocks a `git push` whose format/lint checks fail, and it sits
  in front of every push in every repo on this box — including the runner's `$HOME`,
  which is shared. So it blocks **only** on a check that ran to completion and reported a
  real finding: a missing `node_modules`, a `go vet` that could not build, a tool not on
  PATH and any internal error are reported as skips and **allow**. This looks like a bug
  and is the design. CI is still the backstop, so a false allow costs one red run —
  exactly what the status quo costs. A false block is unbounded, cannot be worked around
  by the thing it is blocking, and the reflex it trains is `CONSTRUCT_LINT_GATE=0`
  forever, which costs the whole feature. `make lint-gate-test` exists because that bias
  makes a broken gate and a clean tree look identical.
  It must also never **write**. `prettier --write`, `gofmt -w` and a bare `dart format`
  rewrite the tree; a gate that edits your files mid-push, after you reviewed the diff,
  is worse than the bug it catches. Every command it runs is a check.
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
- `make workflow-size` after editing any GitHub workflow (SERV-136). A `run:` block
  is ONE expression and GitHub caps an expression at 21,000 characters — over it,
  the workflow does not load at all: every run fails before a job exists, named
  after the file path, with no log, and the error points at the `run:` key rather
  than at your edit. **Shell comments inside the block count**, so a comment-only
  change can break CI, and `actionlint` accepts the file either way. Prose belongs
  in a YAML comment *above* the step, which is free.
- `docker compose config` catches compose syntax and interpolation errors.
- The two Go modules are the only real test suites here. After touching either,
  `docker build --build-context cfaccess=./pkg/cfaccess --target test -f
  services/cf-access-guard/Dockerfile services/cf-access-guard` runs **both**
  through the pinned toolchain — the same thing CI does, so there is still exactly
  one compiler pin in the repo. `cd pkg/cfaccess && go test ./...` is the fast
  local loop; regenerate the shared vectors with `-run TestUpdateVectors -update`.
- `gh workflow run verify.yml -f ticket=<key>` after touching the verifier
  (SERV-80) — and against a ticket whose answer you already know, because a
  verifier is only worth something once you have seen it say `not_met`. Its check
  goes green on a `not_met` verdict by design, so "it passed" and "it found
  nothing" look identical from the checks list; read the verdict, not the colour.
- `./scripts/check-compose-drift.sh [service]` after any mount or env change.
- `make health-check` (or `./scripts/assert-healthy.sh [service]`) to ask whether
  the stack actually works, which `docker compose ps` does not answer — it fails
  on anything unhealthy and lists every container with no healthcheck at all.
  `deploy.yml` runs it as a post-deploy gate (SERV-102). `make dev-health-check`
  is the dev project's copy, run by `deploy-dev.yml`.
- `make assert-tokens` / `make dev-assert-tokens` after anything that changes the
  rendered environment — a vault edit, a `signet sync`, a rotation. It asks whether the
  switchyard API tokens in the resolved compose config carry a shape switchyard will
  accept, and **both tiers now gate their deploy on it** (SERV-118 for dev, SERV-124 for
  prod), ahead of any pull or recreate. Malformed is not a degraded state: switchyard
  refuses to boot on one (SWY-295), and `ensureBootstrapToken` is additive, so correcting
  the variable afterwards adds a second dead row instead of repairing the first — the
  last good copy lives in the running container's environment and dies with the recreate.
  Stopping the deploy before that recreate is the recovery path, not just the alarm.
  It **fails closed**: the pattern is a shell copy of switchyard's `API_TOKEN_RE_SOURCE`,
  so if switchyard ever widens the alphabet or the length, a valid new token blocks the
  prod deploy until `scripts/assert-token-shapes.sh` follows. Accepted deliberately;
  SWY-303 removes the copy. Being Signet-managed is **not** a substitute — `signet render
  --check` compares key sets, not values, so a vault seeded from a stale file renders the
  stale value and reports success.
- `make env-ownership-check` / `make dev-env-ownership-check` after changing what the
  vault *delivers* — a `signet target add-key`, an `import`, a re-seeded render target.
  It is the ownership question, not the value question `assert-tokens` asks: whether the
  vault claims a key `versions.env` owns, or writes a file something else also writes
  (SERV-94). Both conditions held on the prod project for a week or two and neither was visible
  from anywhere — the pins because `render-env.sh` strips them, the file target because a
  losing writer leaves no trace. It reads target metadata only and never a value.
  Host-side, and **not a deploy gate**: while the strip is in the path the hazard is
  latent, and a red prod deploy is the wrong way to learn that a vault edit was careless.
- `make promote-dispatch-check` after minting or rotating `PROMOTE_DISPATCH_TOKEN`, the
  credential that lets Switchyard ask `promote.yml` for a promote (SERV-104). **Not
  `signet sync`**, which reports that a value was delivered and says nothing about
  whether the grant behind it works — SGNT-29 is that exact bug, a fine-grained PAT that
  403'd in use while the sync check called it healthy. The bare target is **inconclusive
  by construction**: `Actions: Read` and `Actions: Read and write` are separate boxes on
  the PAT form and only a POST tells them apart, so `dispatch=1` is the one that settles
  it, by dispatching a promote whose version **no registry can resolve** — so `promote.yml`
  refuses it at `Verify the target version exists`, which runs before `Repoint the pin`,
  and nothing can be written whatever anyone does with the approval prompt. Do not
  "improve" this into re-pinning a service to its current version: that reads as safer and
  is not, because the dispatch names `ref: main` while a local `versions.env` goes stale
  on its own, and re-pinning a stale value is a silent **rollback** filed as a promote.
  **Cancel the run it creates** — approving only makes it go red at the tag check.
  `vault=1` asks the vault instead of the deployed `.env`, which is the
  form to use straight after minting: `signet sync` writes the `PROD_ENV_FILE` secret and
  only a **deploy** renders that into `/opt/construct-server/.env`, so in between the
  default form reports "not provisioned" for a token that is provisioned correctly — and
  without it the only way to test a new grant is to ship it first. Run both, at their own
  moments: a wrong grant should be caught before the merge, a failed render after it.
  Cancelling promptly matters for a second reason: the run holds the `version-change`
  concurrency group while it waits for its reviewer, and `cancel-in-progress: false`
  means the next real promote queues behind it. Note also that a fine-grained PAT with no
  repo grant answers **404, not 403** — the same shape that hid `EXTERNAL_REF_POLLER`'s
  missing scope for weeks, so a 404 here is a grant problem and not a missing workflow.
- `make lint-gate` runs this repo's format/lint checks the way the pre-push hook does,
  and `make lint-gate-test` proves the hook still BLOCKS (SERV-58). The second one is the
  one that matters: the gate fails open on purpose, so a gate that has quietly stopped
  working is indistinguishable from a clean tree — both are green. Re-run
  `make lint-gate-install` after pulling a change to `scripts/lint-gate.sh`; the installed
  copy is a copy, and `make lint-gate-status` is what surfaces the drift.
- `make probe-status` after touching the prober or its role — it shows the timer
  *and* the last oneshot run, which is the pair that matters: the failure mode is
  the service landing in `failed` while the timer keeps cheerfully firing it.
  `make probe-delivery` runs one probe now, using the deployed credential rather
  than one you exported by hand.
- `make versions` / `make dev-versions` to answer *what is actually running* — the
  image ref, the resolved digest, and the commit each image was built from. **Read
  the revision column, not the digest**: the publish workflow builds the same source
  twice seconds apart, so two digests from one commit is normal and comparing them
  invents drift that is not there (SERV-88).
- `make dev-edge-auth-check` after touching the dev edge (`config/traefik-dev/`,
  the dev guard's AUD map, the dev routers). It skips itself when the dev edge is not
  deployed, which is the honest answer — there is no origin to interrogate then;
  `config_only=1` checks the committed config from a checkout and names which dev
  Access applications still have no AUD recorded.
- For edge or auth changes, the only real check is a request through the public
  path — internal container-to-container success proves nothing about Access.
