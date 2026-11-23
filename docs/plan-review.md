# Reviewing a plan

What the adversarial plan pass verifies a **SERV** plan against. `REVIEW.md` is
the judgement for a diff; this file is the judgement for a plan, before any diff
exists. The procedure (the workflow, the verdict file, the check row) lives in
Switchyard (`.github/workflows/plan-review.yml` and `docs/plan-as-pr.md` there); those two files are not in this tree, so do not look for them;
this file is what a construct-server plan has to get right. The estate standard
it answers is `PRINCIPLES.md` §5 *Plans are reviewed by a machine first*.

This repository is configuration, not code: there is no test suite
(`CLAUDE.md` § Validating a change). So a plan here is judged on whether its
criteria name a **gate or a command that can fail**, and on whether it respects
the rules this repo learned by breaking. Every check below is performable from
**this checkout plus the plan JSON**, and nothing else. Where a check needs a
command, the command is given.

## Who reads this and what they hold

The pass is CI for a plan revision. It runs on a read-only checkout of `main`
with Bash, Read, Grep and Glob, and three files on disk:

- `plan.json`: the revision. `sections[]` (each with an `anchor`), `criteria[]`
  (each with a `method`), `rulings[]` (0-based `position`, `options[]`,
  `recommended_position`, `chosen_option_id`, `required`, `liveness`,
  `gated_by_position`, `gated_on_option`), `work_breakdown[]` (each row with a
  `review_mode` and `depends_on`), and the prior `reviews[]` and `threads[]`.
- `ticket.json`: the ticket's `key`, `title`, `type` and `review_mode`.
- `plan-context.json`: the ticket's `review_mode` and whether the revision
  carries a `live_required_ruling`.

It has **no Switchyard tools and no Switchyard token**, on purpose: the check
row's authorship is treated as a signature, and a pass holding the writer's
token would be the vouch approving itself. Do not compose a Switchyard request;
do not read the operator's credential files; do not read `/opt/construct-server`
or any `.env`, `creds/` or `*.env` file (a plan is checked against the tracked
tree, never the running host). Everything you need is on disk.

It writes **one verdict file** and nothing else:

```json
{ "blocking":  [ { "section_anchor": "approach", "quoted_text": "…", "body_md": "…" } ],
  "advisory":  [ … ],
  "summary_md": "what you looked at, what you found" }
```

`blocking` becomes one `changes_requested` review and re-queues the planner.
`advisory` becomes anchored threads on a **passing** check. `section_anchor`
must name a section in *this* revision; one that does not is refused and the
finding is dropped, so anchor a criterion finding on the section that holds it
and quote the criterion's leading words. An empty `blocking` with a written
`summary_md` is a clean pass, and it must say what was checked, not that
checking happened.

## Checks

Each is stated with what makes it blocking and how to perform it here. Checks
2 to 14 are this repository's invariants restated for a plan; a plan that
violates one is bounced, not advised.

### 1. Every cited path, symbol, line and count exists in this checkout

A plan leans on the tree it describes. `Glob` the path, `Grep` the symbol,
`Read` the cited line before letting the plan lean on it.

- **A wrong citation is blocking when the plan's argument rests on it**;
  advisory when it is a typo beside a correct argument. Line numbers in a
  300-line script or the 3,000-line `docker-compose.yml` drift weekly: a stale
  line beside a correct function name is advisory.
- **A premise the tree already contradicts is blocking.** Read the script or
  workflow before accepting the problem statement. A plan that says "X has no
  gate" when `scripts/` holds one has not read the tree.
- **A claim about a neighbouring repository is `unverified`, never `false`.**
  Service source, Switchyard's rules, Satlink's reader, a service's image tags
  and Cloudflare Access configuration live elsewhere or on the host. Say
  "unverified from this checkout", name what would verify it, and do not bounce
  on it. The same holds for anything only `/opt/construct-server`, the host
  `.env`, the vault (`signet status`) or a live Actions setting could show:
  repository secrets, the `Protect Main` ruleset's current contents, runner
  registration. A plan may state them as read on a date; it may not rest a
  recommended path on one it did not read.
- **Counts are looked up, not copied.** Anything the plan counts (pins in
  `versions.env`, services, workflows, scripts, lines of a script) is
  re-derived: `grep -c '_TAG=' versions.env`, `ls .github/workflows | wc -l`,
  `wc -l scripts/<name>`. `versions.env`'s own header says its variable count
  "has gone stale three times".
- **A state the plan describes as open may have closed.** Where a plan cites a
  sibling ticket, a PR or "no such script exists", read the tree for the
  artefact now. Not `git log`: the checkout has one commit.

### 2. A plan that edits a workflow keeps the permission model — blocking

Workflow permissions are set **per job**, not per step. `CLAUDE.md` § Deploy
path and runner; the shapes are in `.github/workflows/` (`promote.yml`'s
`repoint` job is the one `contents: write` holder besides `release.yml`;
`deploy-dev.yml`, `base-images.yml`, `wiki.yml` and most others declare
`permissions: contents: read` at the top).

- A plan that needs a write (a branch push, a release, an issue) puts it in a
  **separate job** with its own `permissions:` block and leaves the job that
  reads or computes at `contents: read`. A plan that widens a shared job, or
  that adds a top-level `permissions:` write, is blocking.
- **Nothing triggered by `pull_request` writes production data**: a published
  file, a branch, a Signet secret, a deploy root, a ticket. The pull-request
  fork hole on a self-hosted runner is real (`pr-review-reusable.yml`'s
  `triage` job guards it with a same-repository check). A plan whose write job
  can run on `pull_request`, or whose condition is not stated, is blocking;
  the plan names the events (`schedule`, `workflow_dispatch`, `push` to `main`)
  that reach the write.
- **`promote.yml` never also dispatches `deploy.yml`**, and `GITHUB_TOKEN`
  cannot bypass the `Protect Main` ruleset, so a plan that pushes to `main`
  itself needs `PROMOTE_PUSH_TOKEN`'s shape and says where that token is
  minted (`docs/delivery-pipeline.md`). A plan that adds a push-to-`main`
  step with `GITHUB_TOKEN` will be refused by the ruleset.
- **No unpinned third-party action and no untrusted input in a `run:`.** Check
  `uses:` lines the plan adds against the existing ones (`actions/checkout@v4`
  is the house form) and any `${{ github.event.* }}` interpolated into shell.
- **A scheduled or dispatchable job that pushes to a shared ref** (a data branch, a tag) has a `concurrency:` group, or the plan says why two runs cannot race (`deploy.yml`'s `deploy-construct` group is the precedent).
- **A runner job never writes a fixed path under `$HOME` or `/tmp`**: every
  runner shares one `$HOME` (`CLAUDE.md`, SERV-190). The plan names
  `$RUNNER_TEMP`. A tool installed under `$HOME` needs `$GITHUB_PATH` and an
  explicit availability check (`REVIEW.md` § Always check, *Runner tooling*).

### 3. A workflow edit is measured, and deploy paths are not accidents — blocking

- **`make workflow-size`** (`scripts/check-run-expression-size.sh`): a `run:`
  block over 21,000 characters, comments counted, stops the whole workflow
  loading. A plan that adds more than a few lines to `deploy.yml`, `verify.yml`
  or `pr-review-reusable.yml` (the large ones) names the measurement before and
  after, or says the prose goes in a YAML comment above the step.
  `docs/validation-runbooks.md` has the failure mode.
- **`deploy.yml` is path-filtered** (the `paths:` list at its top). A plan that
  adds a file to the stack must say whether that path is in the filter and what
  a merge touching only that path does. `required-env-keys.txt` and `scripts/**`
  are in it deliberately (their comments say why); `docs/**`, `wiki/**` and
  `README.md` are not. Any edit under `scripts/` is a prod deploy, so a plan that edits a script says so. A plan that relies on a deploy running after a change
  outside the filter, or that adds a path to the filter and does not say the
  merge now deploys prod, is blocking. `config/traefik-dev/**` is excluded on
  purpose so a dev edge edit does not roll prod.
- **A plan states what a merge deploys.** "Merging this ships X to prod" is a
  claim the plan carries when any path in the filter changes; "this deploys
  nothing" is the claim for a docs-only change, and it is checkable against the
  filter.
- **A plan that renames a workflow job says whether the `Protect Main` ruleset
  requires it.** The ruleset is not in the tree (unverified, check 1).

### 4. The vault-first env order — blocking

A new stack credential has one order, in `CLAUDE.md` § Secrets and the
environment and `docs/secrets-and-env.md` (*A key the vault does not hold does
not exist*):

1. `signet set --project construct-server --name X`
2. `signet target add-key --project construct-server --gh-secret PROD_ENV_FILE --name X`
3. `signet sync`
4. `scripts/assert-env-keys.sh --vault` (`make assert-env-keys vault=1`), which
   asks the vault what the next deploy will carry
5. only then a line in `required-env-keys.txt`

Bounce a plan that:

- lists the `required-env-keys.txt` line **before** the vault has the key. A
  manifest line whose key the vault does not deliver blocks every prod deploy,
  rollbacks included (`scripts/assert-env-keys.sh` header, `docs/secrets-and-env.md`).
- stops at `signet set`. That mints a value that reaches nothing; the plan needs
  `target add-key`.
- uses `gh secret set PROD_ENV_FILE` or edits the host `.env` as the delivery.
  `signet sync` updates the **`PROD_ENV_FILE` secret**, not the host
  `/opt/construct-server/.env`. The `.env` changes only when a **deploy run**
  renders the secret (`scripts/render-env.sh`), so the plan says which deploy
  delivers the key and that nothing consumes it until that run. A manifest-only
  merge deploys because `required-env-keys.txt` is in the filter (check 3).
- puts a key that may legitimately be blank in `required-env-keys.txt`
  (`dev-required-env-keys.txt` and `DEV_CLOUDFLARE_TUNNEL_TOKEN` is the case), or
  reads a variable as `${KEY:-default}` so empty means "use a default".
  An empty value is not a value (`CLAUDE.md` § Always); it must skip loudly.
- detaches and re-adds the `PROD_ENV_FILE` render target (`--seed-from` has no
  file target to read, the key set comes back empty), or relies on
  `signet render --check` exiting zero. It exits non-zero in the correct state;
  `make env-ownership-check` is the answer.
- has the vault deliver a key `versions.env` owns, or adds a second writer or
  consumerless target.
- passes a credential as a literal process argument (visible in `ps`); it goes
  by stdin or a named env var (`CLAUDE.md` § Always). A plan that pastes a
  token into a ticket, a PR or a `curl` example is the same finding.
- **Dev is separate**: `DEV_ENV_FILE` on `home-server-dev`, `dev-required-env-keys.txt`,
  `make dev-*`. A plan that copies the prod `.env` into dev, or attaches a
  container to both networks, is blocking.

### 5. Image pins and `versions.env` — blocking

`versions.env` is the source of truth for first-party tags; `CLAUDE.md`
§ Images and versions and `docs/image-pins.md` are the rule.

- **First-party tags are `${<SERVICE>_TAG:-latest}`**, one variable per source
  repo. A released service pins `major.minor` (`LYCEUM_TAG=1.14`); a service
  with no release yet pins the full tag it has (`SATLINK_TAG=0.9.0`). The
  `:-latest` fallback stays, and `deploy.yml` fails if a first-party image
  resolves to `:latest`. A plan that pins a first-party image another way, or
  sets the tag in a secret or the deployed `.env`, is blocking. The sha forms
  in the header are history; "a new one should not" use them.
- **A pin is changed by `promote.yml`** (Actions > Promote / Rollback), or a
  merged `versions.env` edit, never by hand on the host. `promote.yml` verifies
  the tag (`scripts/verify-tag.sh`), commits, and `deploy.yml` deploys; the
  plan does not dispatch both.
- **Signet is `versions-host.env`**, a full `v`-prefixed tag, never in
  `versions.env` (it would pull the whole stack on a signet promote). A plan
  adding another host daemon says which file and why.
- **Third-party images are pinned by digest** (`repo:tag@sha256:…`); a tag is
  not a pin. Only dozzle, uptime-kuma, datadog and watchtower float, and adding
  a service does not opt it in. `postgres` is pinned by digest and recreating it
  breaks the Node services; a plan that bumps it says so and names
  `make force-recreate`.
- **A first-party Dockerfile `FROM` names a supported cycle to cycle precision**
  (`alpine:3.23`, never `alpine:3` or `latest`; `docs/base-images.md`,
  `scripts/check-base-images.sh`). `cf-access-guard`'s `golang:` pin is this
  repo's to keep.

### 6. Recreate, not restart; scope, not cascade — blocking

- A plan that changes a mount, env or image says `make recreate svc=<svc>`.
  `docker restart` keeps the old spec. A **single-file bind mount** edit
  (`config/wiki/nginx.conf`, `config/traefik/traefik.yml`, `config/crowdsec/acquis.yaml`,
  `config/copyparty.conf`, `aperture/config.yaml` and the other files listed in
  `CLAUDE.md` § Always) changes nothing until the container is recreated, and
  only `wiki` recreates itself in `deploy.yml`. A plan editing one says who
  recreates it.
- A `docker compose up` against a named service carries `--no-deps`
  (`make recreate` and `force-recreate` bake it in). Without it compose follows
  `depends_on` and bounces `postgres` and everything on it.
- `db/init-db.sh` and `db/init-private-db.sh` additions are idempotent: the
  first runs on every deploy against live Postgres. A role that must not hold
  `ALL PRIVILEGES` never goes through `ensure_db`. A plan adding to it says why
  it is safe to re-run; "runs once" is wrong.

### 7. The repository is PUBLIC — blocking where data leaves

`gh repo view Einlanzerous/construct-server --json visibility` says `PUBLIC`.
Anything committed, published to a branch, written to a Pages site or put in a
release is world-readable, and `main`'s history is permanent.

- **Data in transit counts as published**: a workflow artifact, cache, run log or step summary of a public repo is readable by others. A plan that uploads an unfiltered file between jobs, or prints private-repo rows to a log, exposes it before any later filter runs; the filter sits where the data is produced.
- **A plan that publishes data says what it exposes**, in a section, not only
  in a ruling's consequence line: which fields, which repositories, whether any
  is private. A published file that lists repository names, paths, hostnames,
  image digests, token names or internal addresses of a repo that is not public
  is a leak. `base-images.yml` sweeps with `WIKI_DOCS_TOKEN` precisely so it can
  read private repos; output derived from that sweep is private-derived data.
  "Unknown privacy counts as private" is the fail-closed form a plan should
  carry.
- **A secret that reaches a committed file, a build arg or an image layer is a
  rotation, not a revert** (`CLAUDE.md` § Always). `creds/` and `.env` stay
  gitignored. A fixture the plan proposes with a real token shape, hostname
  or email is blocking.
- **The generated wiki's generator never reads a resolved environment**
  (`wiki/CLAUDE.md`); a plan that feeds `wiki/` from `.env` or `docker compose
  config` output is blocking.

### 8. Host bind mounts, edge and access — blocking

- **Host bind mounts for satlink and genzo use `create_host_path: false`**
  (`docker-compose.yml`, the satlink and genzo blocks): a missing directory must
  fail the `up -d`, not be created root-owned. A plan adding or recreating a
  service with host mounts says which, installs the host side first, and keeps
  the flag. `scripts/genzo-data-dirs.sh` and `scripts/satlink-edge-rollout.sh`
  are the precedents.
- **Every router on Traefik's `internal` entrypoint carries `cf-access-jwt`**
  (`config/traefik/dynamic/routers.yml`), and the host has an entry in
  `CF_ACCESS_AUD_MAP` (`docker-compose.yml`, `cf-access-guard`). The exemptions
  are exactly two shapes: `switchyard-github-webhook` (one host, one exact
  `Path()`, HMAC-gated) and `placard`. A plan adding a third, broadening one, or
  adding a router without the middleware is blocking. `scripts/check-edge-auth.sh`
  enforces it post-deploy; the plan names `make edge-auth-check` (and
  `make dev-edge-auth-check config_only=1` from a checkout) among its criteria.
  For an edge change the only real check is a request through the public path;
  a criterion that is only "Traefik config parses" proves nothing about access.
- **The remote MCP AUD lives in three places** (`switchyard-mcp`,
  `CF_ACCESS_AUD_MAP`, `CF_ACCESS_MCP_AUD` on switchyard) and the third fails
  silently. heitan's AUD is `HEITAN_CF_ACCESS_AUD`, never `*CF_ACCESS_GATEWAY_AUD`.
  A plan touching MCP routing names all of them (`docs/origin-auth.md`).
- **Plimsoll never gets a router, tunnel, public hostname or Access app**
  (`postgres-private`, `plimsoll-llm`), and `scripts/check-plimsoll-sandbox.py`
  holds `plimsoll-llm` to an allowlist. `trestle-genzo` is private.
- **One Cloudflare Access verifier: `pkg/cfaccess`.** A plan that writes or
  copies a second one is blocking.

### 9. Commit type and release: a shipping change is never `chore:` — blocking

`PRINCIPLES.md` §3. `chore:` cuts no release, and release-please
(`.github/workflows/release.yml`, `release-please-config.json`) is what the
stack's versioning hangs from.

- The plan names the commit type of **every commit on the branch**, not only the
  PR title (squash and rebase are both enabled), as `type(scope): subject (SERV-N)`
  with the key in the subject and never a bare `SERV-N:` prefix; the branch is
  `{type}/{slug}-{key}`.
- A change to anything in `deploy.yml`'s `paths:` list (compose, `config/**`,
  `db/**`, `scripts/**`, `versions.env`, `required-env-keys.txt`,
  `services/cf-access-guard/**`, `pkg/cfaccess/**`) typed `chore:` is blocking:
  it silently does not release and a reader of the plan would assume it shipped.
  `docs/`-only and `REVIEW.md`-only changes are legitimately `chore:`. The
  plan that adds a published artefact or a new script behaviour is `feat:`;
  polish inside a shipped feature is `fix:`.
- A change touching `pkg/cfaccess/` lands in both changelogs on purpose
  (`release.yml` header); a plan that expects otherwise has misread it.
- Release-please owns `CHANGELOG.md`, `.release-please-manifest.json` and the
  version; a plan that hand-edits them is blocking.

### 10. A new service meets PRINCIPLES §4 — blocking

A plan that adds a service to `docker-compose.yml`, or promotes one onto the
stack, carries the §4 contract and `docs/stack-service-notes.md`'s wiring:

- `GET /healthz` returning `{status, version, sha}`, unauthenticated, same
  shape on 200 and 503; `version` bare semver with no `v`; `sha` 40 characters
  or `null`; outside a container `dev` and `null`.
- Registered with Switchyard's inventory before the delivery prober targets it
  (`docs/delivery-pipeline.md`; `scripts/register-delivery-service.sh`); a
  healthcheck proven able to **fail**, probing the serving process over HTTP,
  not a `version` subcommand; `scripts/assert-healthy.sh` still passes.
- An image pin (check 5), a `versions.env` variable if first-party, `restart:
  unless-stopped`, the `construct_net` network, a router with `cf-access-jwt`
  or an explicit statement that it has none (check 8), and a Switchyard webhook
  for a new repo (`scripts/add-switchyard-webhook.sh`).
- **One `delivery-prober.timer`**: a second producer is another `ExecStart` on
  the unit, never a second timer; the prober's token is `deployments:observe`,
  never `deployments:write` (`CLAUDE.md` § The delivery ledger).

A plan that adds a service and omits the §4 statement is blocking only if the
service has an HTTP surface; a worker with no HTTP surface says how it reports
its version (`PRINCIPLES.md` §4 *If the service has no HTTP surface*).

### 11. Language: Go or TypeScript, and shell is a stated deviation — blocking when silent

`PRINCIPLES.md` §1. A plan that adds or grows code:

- **Python is not proposed**, here or in CI. A Python-only library is named, with
  the reason said first. (`scripts/check-plimsoll-sandbox.py` and
  `scripts/measure-mcp-tools.py` are existing exceptions, not precedent.)
- **Shell is for operational scripts that mostly drive other commands**; the
  reference shape is `db/init-db.sh` and `scripts/check-compose-drift.sh`. A
  plan that extends a script past that (real control flow, data structures,
  anything that wants a unit test: check `wc -l` and read it) says so as a
  **stated deviation**, names the Go or TypeScript alternative, and files or
  rules on the port. A plan that grows such a script and says nothing is
  blocking: §1 says a deviation "should be visible". A plan that *concedes*
  the deviation with a ruling is conforming; do not bounce the ruling.

### 12. Validation exists, because there is no test suite — blocking

`CLAUDE.md` § Validating a change lists the checks. A plan's criteria for a
config change must name the one that applies and be able to fail:

- the matching `make` target or script (`make assert-env-keys`, `make
  health-check`, `make env-ownership-check`, `make edge-auth-check`,
  `make base-images-check` and `make base-images-test`, `./scripts/check-compose-drift.sh`,
  `docker compose config`, `ansible-lint`, `make workflow-size`);
- **a check proven able to go red**, with the repo's own precedent
  (`make edge-auth-test`, `make base-images-test`, `make lint-gate-test`). A new
  gate with no failing case is blocking, including a gate written inside a workflow `run:` (put it in a script the harness can run): "the script exits 0 on the happy path"
  proves nothing about the gate;
- the `scripts/test/` harness for a script's own test, run by a workflow the
  plan names, not "run it by hand".

The **lint gate** (`scripts/lint-gate.sh`, `docs/lint-gate.md`) fails OPEN and
never writes, deliberately. A plan that makes it fail closed, writes files from
it, or treats it as the only check a push is clean is blocking: it is a hook on
the operator's machine, not CI.

A criterion is checkable by its `method`: `unit` names an assertion a test can
fail; `manual` says who acts and when; `review` says what text it is compared
against; a `workflow_dispatch` run says which job and what it reads. A criterion
that has become rationale, or a method the ticket cannot exercise, is blocking
until it says what fails. `verify.yml` goes green on `not_met`: a plan whose
evidence is a green run of it says which verdict it reads.

### 13. A quoted number is re-derived from where it lives

A plan that quotes a number cites where it lives, and you re-derive it:
`21,000` (`scripts/check-run-expression-size.sh`), a pin
(`grep '^NAME_TAG=' versions.env`), a service count (`docker compose config
--services | wc -l`), a line count, a timeout (the workflow it lives in). A
number copied from another service (a size cap, a body limit, a rate) carries
that service's constraint and is `unverified` here unless the plan cites where
it read it. Advisory when the conclusion survives a wrong number, blocking when
the number is the argument.

### 14. Locked decisions and the deploy path are not re-litigated

`CLAUDE.md` § Deploy path and runner, § Edge and auth, § The delivery ledger and
`PRINCIPLES.md` §2 close these. A plan that touches one **says so and asks a
ruling**; it does not argue the decision away in prose. A plan that quietly
builds on the other side is blocking:

- the stack deploys from `/opt/construct-server` and no other path; a plan that
  deploys from a checkout, or `docker compose`-es the repo root as prod's
  authority, is blocking (`docs/runner.md`);
- `deploy.yml` is the one deploy path (`promote.yml` commits, it does not
  deploy); one Signet `PROD_ENV_FILE` writer; do not retire the `imperium-loop`
  Signet project (it still holds `RELEASE_BOT_APP_ID`/`RELEASE_BOT_PRIVATE_KEY`);
- Docker computes health and acts on none of it: `restart: unless-stopped`
  ignores unhealthy, so a plan that leans on auto-restart for an unhealthy
  container is wrong; `scripts/assert-healthy.sh` is the gate;
- `cf-access-guard` is the one first-party image built on the box; a plan that
  serialises reviews or sets a per-runner `HOME` is re-opening SERV-190.

### 15. Ticket hygiene and `review_mode`

- A plan whose ticket is `evidence` still names the evidence the PR will carry
  (an output, a run URL, a screenshot on Trestle). A change that is visible
  carries an image (`PRINCIPLES.md` §5 *Show, don't describe*); a PR that
  changes only config says what command shows it works.
- A plan may raise a ticket's `review_mode` to `decision` or `full`; it never
  lowers one (`~/.claude/CLAUDE.md`). A `work_breakdown` row that edits the
  deploy path, the edge auth, a Signet-owned secret or `db/init-db.sh` says
  `review_mode: full` and gives the reason (it can reach prod, widen who can
  reach something, or blank a role); so does a row that gives a job `contents: write`; a row for those left at `evidence` is
  blocking. A row claiming `full` for a docs edit is advisory.
- A ticket needing more than one PR is split first, and `depends_on` orders the
  deploy: a row that deploys a consumer before the producer it needs is
  blocking.
- Deferred follow-up work has a ticket key or a named project; "later" is advisory.

## The reviewer's standing

- **Advisory on a passing check; blocking only for a hole a person would
  bounce.** Style, wording and a better shape are advisory. A broken invariant,
  a criterion nobody can run, an unmarked either/or, a citation the argument
  rests on, a data exposure the plan does not state: blocking. You spend your
  own credibility, never the human's revision budget: the cap is five by default
  (`plan_revision_cap`; crossing it is `plan_stuck`), and a bounce for a nit
  costs one of them.
- **The approval half never applies to a plan with human-only rulings.** When
  `plan-context.json` says `live_required_ruling: true`, or `review_mode` is
  `full` or unset, a clean pass means a person is now owed the rulings, not that
  the plan is approved. When the mode is `evidence`, or `decision` with no live
  required ruling, you are the last gate before an agent approval: weigh a clean
  pass accordingly, and never let green mean nothing was reviewed.
- **Never pick a ruling. Never supersede a plan. Never write the check row.**
  Proposing a recommendation is not choosing; say "I would take option N" if it
  helps, and stop there.

## Posture toward rulings

Scrutiny goes to the **recommended option** (`recommended_position`) and to the
criteria, sections and rows written for it. That is the path a person is being
asked to approve, and where a wrong claim costs a revision.

- **Non-recommended options get an honesty check only**: is the option described
  falsely, or strawmanned so the recommendation looks better? An option that
  cannot be built as described and is left pickable is blocking, because a
  person could pick it. Anything else on a non-recommended option (costing,
  criteria, spikes) is advisory, tagged "only if option N is picked". Do not
  demand full coverage of paths the plan recommends against.
- **A genuine either/or argued in prose with no ruling attached is blocking.**
  It is the one thing standing between a ruling-less `decision` plan and an
  agent approval. A data-exposure choice, a commit-type choice, a deploy-path
  choice and a language deviation are all rulings, not sentences.
- **Dependent rulings are gated**, not asserted independent: `gated_by_position`
  and `gated_on_option`. "Eight rulings, all independent" is a claim you check
  against the criteria's wording.
- **An option nothing builds**, whose body says "its own ticket" or that no
  criterion and no row backs, either gets a conditional row now or comes off the
  docket: advisory when it is not the recommendation, blocking when it is.
- **A pick exists (`chosen_option_id` set):** that option is the reviewed path
  and the others are moot. State verdicts against the reviewed path ("clean on
  the recommended path") so a person can tell what an approval means. A criterion
  that says "the picked option" is dischargeable only when the pick is read from
  `rulings[]`; check the pick before judging it.
- **The recommended option itself unsound is blocking, said plainly.** You may
  propose a different recommendation; you never pick.

## Exit condition: ready for a human

The automatic loop (SWY-445) reads this list. A SERV plan is ready for a person
when **all** of these hold on the current revision, checkable from the checkout
plus `plan.json`:

1. **No blocking finding on the recommended path**: checks 1 to 15 pass for the
   recommended option of every live ruling and for the criteria, sections and
   rows written for it.
2. **Every unmarked either/or has a ruling.** No decision is argued in prose
   without a `rulings[]` entry, and dependent rulings are gated.
3. **Every criterion has a `method` and is dischargeable by this ticket**: a
   command or gate that can fail, a `manual` with an actor, a `review` with a
   text to compare against.
4. **The statements each check asks for are present when relevant**: a plan
   adding a key gives the vault-first order and names the deploy that delivers
   it; a plan editing a workflow names its events, its per-job permissions and
   the `deploy.yml` filter outcome; a plan publishing data says what it exposes
   and whether any of it is private; a plan touching the edge names the public
   path check; a plan growing a shell script states the deviation; a plan names
   the commit type of every commit; a plan adding a service carries the §4
   contract.
5. **The work breakdown exists on a `decision` ticket**, every approved
   criterion is in some row's `Done when`, rows that reach prod, the edge or
   the vault say `review_mode: full`, and `depends_on` orders the deploy.
6. **Every citation the argument rests on has been verified here**, and every
   neighbouring-repository, host or vault claim is marked `unverified`.

Reaching it means **a person is now owed the rulings**. It does not mean the plan
is approved, and on a plan with a live required ruling it never can.

## Re-reviews

Round three is shorter than round one. On a revision after the first:

- **New blocking findings only.** Do not restate an open thread; do not add
  advisory findings for things the previous revision also had; do not re-raise
  what the author declined with a reason.
- **Check a fix landed where the invariant lives, not where it was reported.** A
  permission moved from the workflow's top to a step, a `--no-deps` added to the
  prose but not the command, a filter changed in the plan and not in the
  `paths:` list: a fix that changes the text and not the mechanism is not a fix.
- **Re-verify the fixed claims.** Each prior finding's answer is a new citation
  (check 1). Read `reviews[]` and `threads[]` in `plan.json` for what was raised;
  read the tree for whether the answer is true.
- **Say in one line what got fixed, then move on.** If nothing new is blocking,
  the summary says so and names the recommended path the verdict is stated
  against.
