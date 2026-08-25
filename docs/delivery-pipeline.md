# Delivery Pipeline — dev, prod, and the Verified gate

Design of record for how code reaches the Construct. Tracked in Switchyard under
**IDEA-19**; this doc is the starting point for the deep dive that graduates it to
an epic with per-service children (SERV / SWY / SGNT / LOOP).

**Status: mostly built.** This said *"design only. Nothing below is built"* until
2026-08-23, long after most of it shipped — and because the header is what people read
first, it sent them looking for work that was already done. The per-section *"Closed
by …"* annotations below are accurate and are the thing to trust; the pipeline exists
end to end, and what remains is the quality gate (SERV-80, SERV-81) plus the loose ends
each section names.

**Now ticketed.** The Switchyard slice is **SWY-184** (children SWY-185…194); the
construct-server slice is **SERV-73** (children SERV-74…81, and since SERV-108, 128,
130). Where a ticket and this document disagree, the ticket is newer.

**Superseded since writing.** imperium-loop was wound down in August 2026 (SERV-82,
SWY-222) and its containers no longer exist, so the Servo-Signal rows in *Shape* and
**sequencing step 3 are dropped, not deferred**. The
verifier instead runs as a Claude Code job on the self-hosted runner, following
`.github/workflows/pr-review.yml` (SERV-80) — which takes the security item off the
critical path entirely. Reconciler tier B (SWY-194) was scoped around that same agent
and needs re-planning.

## Goal

```
approved PR (CI green)
      │
      ▼
  deploy to dev automatically          ← every merge to main, no gate
      │
      ▼
  cross-service gate suite             ← smoke → contract → e2e → (load)
      │
      ▼
  verifier agent vs. plan_criteria     ← does the ticket actually work?
      │
   green?
   /    \
 auto   manual gate                    ← GitHub Environment, required reviewer
   \    /
      ▼
  promote pinned version to prod
      │
      ▼
  post-deploy smoke → rollback on fail
```

Two properties we do not have today and want most: **you can see which version is
in which environment**, and **a ticket can be asserted working in dev before it
ships**.

## Where we actually are

Inventory taken from the box on 2026-07-30. This differs materially from the
mental model, so it is recorded here rather than summarized.

### There is no dev environment

What we have been calling "dev instances" are long-lived **host processes**, not
containers — which is why none of them appear in a compose file, a Traefik router,
or any config:

| Process | Uptime | Notes |
|---|---|---|
| `go run ./cmd/argosy serve` | 5d 22h | the "permanent argosy dev env" |
| `bun run dev -- --port 5176` + vite | 1d 17h | switchyard client, listening on `*:5176` |
| `bun .output/server/index.mjs` | 10d | |
| `bun packages/worker/src/index.ts` | 10d | |
| `bun switchyard/mcp/src/index.ts` | ×11, oldest 20d 5h | leaked stdio MCP servers from dead Claude sessions |

Plus an orphaned `lyceum-dev-pg` (`postgres:16-alpine`, up 2 weeks).

### Version state is nondeterministic

As surveyed, every first-party image in `docker-compose.yml` was a hardcoded
`:latest` — aperture, cook_book, argosy, switchyard, centrifuge, lyceum, purser,
interlock. **Closed by SERV-74 + SERV-88.** All 14 read `${<SERVICE>_TAG:-latest}`
against real values: major.minor for the services with release-please versions, a
sha for argosy and drydock, which at the time had no semver image to pin to.
Verified by deploying twice
from `main` with no merge in between and diffing the running digests — identical,
and the second deploy recreated nothing.

Those values started out in the `PROD_ENV_FILE` secret and **SERV-96 moved them to
a tracked `versions.env`**, which is what makes steps 8 and 9 below implementable.
An image tag is not a credential, and a promote that has to edit an environment
secret needs a credential no workflow can be given — `secrets` is not a
`permissions:` scope, so `GITHUB_TOKEN` cannot do it, and the fine-grained PAT
grant that could 403'd in SGNT-29 while `signet sync --check` reported it healthy.
A promote that edits a tracked file needs `contents: write`. It also gives step 9's
"last-good version" an index before the ledger exists: `git log -p versions.env`.
`scripts/render-env.sh` merges the secret and the pins into the deployed `.env`, so
the stack still reads one complete environment file.

Pinning also made drift legible for the first time, and **SERV-89** then resolved
it — with one correction worth carrying forward.

**amber** really was behind: it ran `v0.4.1` while `0.5.0` existed, because
watchtower used to roll it forward and SERV-75 correctly stopped that. Now pinned
to `0.5`, a deliberate one-commit upgrade.

**purser was never ahead of its release.** SERV-88 inferred that from a digest
mismatch between `sha-2156151` and `0.13.0`, and the inference was wrong: both
images carry `org.opencontainers.image.revision=2156151434…`. They are the *same
commit*, built twice — once by the push-to-`main` publish and once by the
release-tag publish, eight seconds apart. Non-reproducible builds, identical
source.

That is a trap this document should name, because the whole delivery design turns
on "which version is in which environment". **A digest comparison alone will invent
version drift that does not exist.** Compare the `revision` label. It matters most
exactly where the stakes are highest — the deployments ledger (SWY-185/191) and
rollback (SERV-79), where "is this the same code" is the entire question.

So two of the ten pins were shas — argosy and drydock. Since SERV-125 all ten
track major.minor.

**They were not "genuine no-semver cases", which is what this document called them
for months.** Both cut releases normally the whole time (`v0.25.1`, `v1.7.0`). What
neither published was a semver-tagged *image*, and that is a different claim — the
one the pin actually depends on. Their publish workflows asked for the semver tags
on `on: push: tags`, and that trigger had never fired once in either repo, because
release-please cuts tags under `GITHUB_TOKEN` and GitHub creates no workflow runs
from events that token authored. The tag landed, nothing built, nothing complained.
Fixed upstream in SERV-125 by publishing from the release-please run instead.

The phrasing mattered more than it looks: read as written it says the upstream repos
have no releases, so the reader concludes there is nothing to pin to and stops
looking — which is exactly what happened, for as long as it took SERV-73's audit to
go and check the registry.

One float is kept on purpose: major.minor means patch releases still land on a
`docker compose pull`, so security fixes do not need a secret edit. Exact-version
pinning is what `promote.yml` (SERV-78) makes practical, since it can write the
version rather than a human remembering to.

Three independent things mutated prod against those floating tags:

1. `deploy.yml` on push to `main` (`docker compose pull && up -d`)
2. `repository_dispatch: [deploy, image-updated]` from app repos
3. **watchtower** — schedule `0 0 4 * * 1` (Mondays 04:00), cleanup + rolling
   restart. **Closed by SERV-75.** As surveyed this was recorded as "monitoring
   *every* container, only servo-signal opts out"; the survey was wrong on the
   detail — 20 services carried opt-out labels — but right that the default was
   monitor-everything, which left 12 of 29 services in scope, 4 of them
   first-party. It is now `WATCHTOWER_LABEL_ENABLE=true`, monitoring an opt-in set
   of four third-party leaves and no first-party image. Mutators 1 and 2 remain.

The versioned artifacts already exist: `lyceum/.github/workflows/publish.yml:31`
emits `latest`, `sha-<short>`, `{{version}}`, and `{{major}}.{{minor}}`. Compose
simply never consumes them. **Pinning tags is the prerequisite for everything else
in this document.**

### The stack had a split identity — resolved by SERV-76

As surveyed, `docker compose ls` reported the `construct-server` project bound to
two config files at once:

```
/home/magos/runners/construct-server/_work/construct-server/construct-server/docker-compose.yml
/home/magos/construct-server/docker-compose.yml
```

24 containers came from the first, 5 from the second. The cause was two independent
deploy systems pointed at two directories: `deploy.yml` at the runner's checkout,
and the ansible server role at the home checkout.

This document's original framing — "deploys run from the runner's checkout" — was
the wrong resolution, and SERV-76 rejected it on evidence. That `_work` directory is
CI scratch shared by `deploy.yml`, `deploy-signet.yml` and `pr-review.yml`;
`actions/checkout` resets it every run, and since `pr-review.yml` fires on
`pull_request` it regularly holds an *unmerged* PR merge ref. It cannot be a source
of truth for anything.

Both systems now deploy from **`/opt/construct-server`**: ansible bootstraps it,
`deploy.yml` owns it in steady state. Adoption is gradual — a container keeps the
root it was created from until next recreated — so expect more than one path in
`docker compose ls` until the stack cycles. `check-compose-drift.sh` reports what is
outstanding.

There are still two other compose projects on the box (`argosy-acquisition`,
`interlock`) that no environment model knows about.

## Shape: expand, don't build

The instinct to "build our own Jenkins" is the expensive answer. GitHub Actions plus
the self-hosted runner is already a competent executor; `deploy.yml` is 40 lines.
What is missing is a **promotion path and an environment × version matrix**, and that
belongs in Switchyard.

Nothing in this design requires a new CI system, scheduler, or UI shell.

| Component | Verdict | Gains |
|---|---|---|
| **Switchyard** | expand (largest) | `environments` + `deployments` tables, version-matrix view, Verified status, feature flags |
| **GitHub Actions** | expand | `deploy-dev.yml`, `promote.yml`. GitHub Environments with required reviewers **is** the manual gate — no code |
| **Signet** | expand | environment dimension on secrets (`construct-server/dev` vs `/prod`); materializes the dev `.env` |
| **Servo-Signal** | expand | verifier tool surface (HTTP probes, running suites in its existing ephemeral-docker sandbox) + auth |
| **Traefik** | expand | `dev.` router tier on the **internal** entrypoint only, never public |
| **Dev compose project** | **new** | `docker-compose.dev.yml`, own project name / network / databases |
| **Cross-service test suite** | **new — largest lift** | contract → e2e → load. Nothing exists today |
| **Verifier agent** | **new, small** | Claude + `plan_criteria` + existing MCP |
| **Feature flags** | **new, small** | if it lives in Switchyard |

## Switchyard already anticipated the Verified gate

The schema needs **no migration** to support this:

- `resolution` (`schema.ts:41`) is `["done", "released", "cancelled"]` — a post-merge
  lifecycle stage is already modeled.
- `external_ref_kind` (`schema.ts:411`) includes `github_action`; `external_ref_state`
  includes `success` / `failed`. A deploy or gate run attaches to a ticket as a
  first-class polled ref, and the existing `ticket.external_ref_state_changed` rule
  trigger — the same one that closes tickets on PR merge — fires on it.
- Statuses are per-project rows with an explicit `status_transitions` edge table, so
  **Verified** is a row plus an edge.
- `plan_criteria` (`schema.ts:1283`) stores acceptance criteria per-criterion with a
  `verdict` and `reviewer_note`; `plan_reviews.reviewer_id` FKs to `users`, where
  `user_type` includes `agent`.

The verifier is therefore not a new model. It is a **second review pass — post-deploy
instead of pre-build** — writing into tables that already exist, by an actor that is
already a first-class user. It lands in `llm_observations` for cost attribution for free.

## The flow, step by step

**0. Merge.** PR green on the repo's existing CI, reviewed, merged to `main`.

**1. Publish.** `publish.yml` builds and pushes `sha-<short>` and `latest`. Already
happens today; no change.

**2. Auto-deploy to dev.** `repository_dispatch` → construct-server `deploy-dev.yml`,
deploying *that sha* to the dev project only. Dev always tracks HEAD. No gate here —
the gate is what comes after.

*Shipped as `deploy-dev.yml` (SERV-97), with two departures from the sentence above.*

- *Dev **floats on `latest`** rather than pinning a dispatched sha. The pinning machinery
  exists — `dev-versions.env`, a separate file with a `DEV_` prefix on every variable so a
  misplaced prod `.env` cannot pin dev to prod's versions — but every value in it is
  `latest`, deliberately. Dev's job is to run what just merged; a pinned dev is a second
  prod. The file earns its place by giving a **temporary** dev pin a reviewable home, and by
  making dev's version state answerable from git rather than from the box.*
- *A dispatch alone would not have worked, and this is the part worth carrying forward. The
  service repos do dispatch `image-updated` — from `release.yml`, gated on release-please
  cutting a version. So it fires on a **release**, not on a merge. `latest` is pushed by
  `publish.yml` on every push to main and announced to nobody. A dispatch-only workflow
  would have left dev moving on releases while looking like it had fixed the problem. An
  **hourly schedule** is what makes step 2 true today; the dispatch is what makes it prompt.
  Adding a per-merge `deploy-dev` dispatch to each service repo's `publish.yml` is
  **SERV-108**, and it is what lets the cron drop back to a backstop.*

*Note what actually moves dev, because it is not obvious: a floating tag is not a floating
container. The image string never changes, so compose sees no drift and `up -d` alone is a
no-op however far main has moved. Dev advances only when something **pulls**.*

**3. Record the deployment.** The deploy writes a `deployments` row: environment,
service, version, actor, source ref. Ticket keys come from commit trailers. This table
is what makes the version matrix possible, and doubles as the rollback index.

**4. Gate suite runs against dev**, ordered by cost so failures are cheap:

| Stage | Scope | When |
|---|---|---|
| Smoke / health | every service's healthcheck + one authenticated request | every deploy |
| Contract | consumer-driven, per service pair | every deploy |
| E2E | cross-service user journeys | every deploy |
| Load | throughput / latency budgets | nightly or on-label |

Start with **contract**, not e2e — cheaper to write, and it catches more of what
actually breaks us. The real coupling worth pinning first: Purser → Switchyard `/v1`,
Purser → Lyceum `/admin`, Switchyard → Signet over `host.docker.internal`, Aperture →
Docker socket.

**5. Attach results.** The run attaches as a `github_action` external ref with
`success` / `failed`. Existing rule trigger, existing polling loop, no new mechanism.

**6. Verifier agent.** Runs against live dev, reads the ticket's `plan_criteria`,
writes a per-criterion `verdict` + `reviewer_note` and a `plan_review` row. Transitions
the ticket to **Verified**, or back to Blocked with the failing criteria as a comment.

**7. Promotion**, by policy — three tiers:

- **Auto** — all criteria pass and the service is on the auto-promote allowlist.
  Proposed start: aperture, cook_book, centrifuge.
- **Manual gate** — GitHub Environment `prod` with a required reviewer. This is the
  "let someone look at the dev version of a major feature first" case, and it is
  zero code.
- **Forced manual** — a `needs-human` label on the ticket overrides the allowlist.

**8. Promote.** `workflow_dispatch` with an explicit version input → pin that semver →
`docker compose pull && up -d` → record a prod `deployments` row.

*Shipped as `promote.yml` (SERV-78, SERV-79), with three things worth recording:*

- *It is **one workflow with a `kind` input**, not a promote and a rollback. "Make prod
  run this exact version" is the same operation in both directions, and rollback is the
  path you least want to be the less-tested one, since it runs when prod is already
  broken.*
- *It **does not deploy**. It edits one line of `versions.env` and commits; `deploy.yml`
  already fires on a push touching that file, and is the only thing that deploys
  (SERV-76). This keeps the deploy path single.*
- *The recreate **is now** scoped to the pins the workflow moved. It took two tickets to get
  there, and this document asserted the bound before measuring it — so record both halves.*

  - ***As surveyed, the claim was wrong.** `deploy.yml` pulled before `up -d`, so compose
    recreated the named service **and anything else whose reference moved since the last
    pull**. The first real rollback (purser 0.13 → 0.12) recreated purser, ollama and
    semaphore; only purser was named.*
  - ***SERV-105** removed the third-party half, pinning those images by digest — including
    `traefik:v3.3` and `crowdsec:v1.7.8`, which look like pins and are not, since a minor tag
    moves on patch releases and a patch tag can be rebuilt in place. Four stay floating by
    design: the watchtower opt-ins, which cannot be rolled by watchtower once pinned.*
  - ***SERV-109** removed the first-party half, the larger one. Pinning could not close it:
    a major.minor pin moves on a patch release *deliberately*, which is the whole point of
    the convention — so the fix is to scope rather than to pin harder. `scripts/deploy-scope.sh` recognises the one commit
    shape a promote produces (`versions.env` and nothing else) and `deploy.yml` then pulls
    and recreates only the services behind the pins that changed, `--no-deps`. Ordinary
    merges still pull the whole stack, which is where the patch float is meant to land. The
    script refuses rather than guesses, and every refusal degrades to the old whole-stack
    pull — the dangerous direction is a scope narrowing to nothing, which would be a green
    deploy that shipped no change at all.*
  - ***What is deliberately still unbounded:** four of the ten pins cover two images each and
    recreate in pairs — `APERTURE_TAG`, `CENTRIFUGE_TAG`, `SWITCHYARD_TAG` (backend +
    frontend) and `INTERLOCK_TAG` (web + worker), which ship from one release; and a rollback to
    `0.13` fetches the newest `0.13` patch rather than the digest prod ran the last time it
    was on `0.13`. Exact-version pins — SERV-109's option 2 — would close the second and cost
    the "a security fix lands without an edit" property, which was chosen on purpose and
    kept. Keeping it means "roll back to 0.13" is a statement about the version, not about
    the bytes; `make versions` and the `revision` label are what answer the bytes question.*
- *It verifies the tag exists in the registry **before** committing, across every image
  behind the pin — a repo's backend and frontend ship from one release, so a version
  that published for one and not the other is refused rather than half-deployed.*

*The `deployments` row is no longer outstanding. **SERV-117** wired the three call sites
that actually deploy — `deploy.yml`, `deploy-dev.yml`, and `promote.yml` by way of the
commit `deploy.yml` fires on — and **SERV-130** added the fourth, `deploy-signet.yml`.
The commit remains the durable record either way (`git log -p versions.env`).*

*Three git trailers carry a promote's intent to whichever run deploys it, because
`promote.yml` deliberately does not deploy: `Delivery-Kind`, `Delivery-Reason` and —
since SERV-130 — `Delivery-Actor`. The last one is not redundant with `github.actor`.
The push that fires the deploy is authored by `PROMOTE_PUSH_TOKEN`'s owner, so both
`github.actor` and `github.triggering_actor` in the deploying run name the PAT rather
than the person who asked, and a rollback row with no actor is missing the one field an
incident review wants from it. All three live in a single `-m` block: git parses only
the last paragraph as trailers, so a second block would make them invisible to
`%(trailers:key=…)`. Dev reports an actor only for a `workflow_dispatch` — its other
triggers are a cron and `repository_dispatch`, and on a scheduled run `github.actor` is
whoever last edited the workflow file, which is worse than recording nobody.*

### Signet takes the same path, out of a second pins file

*Closed by **SERV-130**. Until then signet was the one first-party service still on the
pre-SERV-73 shape: a release deployed itself straight to prod, with no pin, no rollback
and no report. It did not appear in `git log -p versions.env` at all.*

*It now promotes and rolls back through the same `promote.yml` as everything else —
same direction input, same required reason, same `production-promote` gate, same
`Delivery-Kind` / `Delivery-Reason` trailers. Three things differ, and all three follow
from signet being a **host binary under systemd** rather than a container:*

- ***The pin lives in `versions-host.env`, not `versions.env`.** Not a filing preference.
  `deploy-scope.sh` maps each changed pin in `versions.env` onto compose services and
  refuses one that no image interpolates — and its caller correctly reads any refusal as
  "pull the whole stack". A `SIGNET_VERSION` in `versions.env` would therefore make every
  signet promote pull and recreate the entire prod stack: the SERV-109 regression,
  arriving through the file that guards against it. The separate file has its own path
  trigger on `deploy-signet.yml`, so `deploy.yml` never fires and `deploy-scope.sh` never
  sees it.*
- ***The pin is a full release tag (`v1.9.1`), not major.minor.** The container pins let
  the registry resolve the newest patch behind `1.12`, which is the one float kept
  deliberately. A releases API has nothing to resolve — `gh release download v1.9` 404s —
  so a host pin names the exact release. The `v` stays because the value is consumed as a
  git tag; everything that **compares** versions strips it, since signet has reported bare
  since SGNT-38 and the ledger compares with strict equality.*
- ***Verification asks the releases API, not a registry.** `verify-tag.sh` derives its
  image list from `docker-compose.yml` and has no entry to find, so `promote.yml` checks
  that the release exists **and carries the binary and its checksum**. Tag-exists alone
  would not be enough: SERV-125 is a whole ticket about release tags that existed for
  months with no artifact ever built behind them.*

*Rollback is now the pin, run backwards through the gated workflow. `.prev` survives as
documented break-glass for when that path cannot serve, rather than as the primary
recovery advertised in an ansible failure message — which is what it used to be, on the
credential daemon, discovered at the moment it was needed (SERV-79's argument, applied).
A rollback below `v1.4.1` is **refused** at promote time rather than warned about: the
unit binds two addresses and an older binary cannot parse that, so it fails to start
entirely, loopback included, instead of degrading.*

*A signet release still fires `signet-released` at this repo and it no longer deploys
anything — it writes a summary saying a version is available and how to promote it. The
dispatch keeps its meaning and loses its authority, which is step 3 semantics rather
than step 2.*

**9. Post-prod smoke.** On failure, auto-rollback to the last-good version, which the
`deployments` table already knows.

*Half of this exists. `deploy.yml` now ends with `scripts/assert-healthy.sh`, so a
deploy that leaves anything unhealthy fails loudly instead of going green (SERV-102) —
that is the smoke. It **detects rather than recovers**: `up -d` has already run by the
time it fails. Wiring the failure to an automatic re-run of `promote.yml` pointed
backwards is what remains, and it needs step 1's ledger to answer "back to what".*

*One dependency that was not obvious until it bit: this step presumes health is a
question the stack can answer, and until SERV-102 it partly could not — `interlock-worker`
had no healthcheck at all, and an unhealthy container triggered nothing, because Docker
restarts **exited** containers and not unhealthy ones.*

**10. Close.** Ticket resolution → `released`.

## Who produces the delivery matrix

The matrix at `/delivery` has **three** producers, and they are not
interchangeable. Knowing which one owns a cell is how you tell "the service is
down" from "nothing has looked at it".

| Producer | Covers | Runs | Scope |
|---|---|---|---|
| Reports | claimed versions | Switchyard, on deploy | `deployments:write` |
| In-process reconciler | **prod** observations | inside the switchyard container | n/a (internal) |
| Host prober (SERV-111) | **dev** observations | `delivery-prober.timer` on this box | `deployments:observe` |

### Why dev needs a producer on the host

The reconciler runs on `construct_net`; dev runs on `construct_dev_net`. The two
share nothing, which is what makes "dev cannot reach prod" true rather than
merely intended (SERV-106/107). So the reconciler covers prod and **structurally
cannot** cover dev — and bridging the networks to let it would undo a deliberate
security boundary in order to populate a status page.

The host can reach both: dev publishes on `127.0.0.1`. So the probe runs here and
posts inward. Switchyard never crosses the boundary; it receives.

`dev` is seeded `probe_mode: external`, which is what makes an outside writer
legal at all — the ingest refuses probe results aimed at an `internal`
environment, so a misconfigured prober cannot fight the reconciler for prod.

### The scope split is the point

The prober's token carries `deployments:observe` and **not**
`deployments:write`. A report is a claim; an observation corroborates it. The
matrix's `claimed_not_confirmed` state only means something if corroborating is
the harder of the two — a prober that could also report would be able to confirm
its own claims. `scripts/mint-prober-token.sh` asserts the granted scopes rather
than trusting them, because the server defaults to `admin` when `scopes` is
omitted, so a typo in the field *name* mints a working admin token silently.

### One cron, however many producers

SWY-194's container-inspect collector is a second host-side producer for the same
ledger. It attaches as another `ExecStart` on `delivery-prober.service`, sharing
the timer, the `EnvironmentFile` and the one observe-scoped token. It does **not**
get its own timer: two host jobs with two configs posting to one ledger is how
the two disagree about what dev is running with nothing to say which was stale.
`scripts/probe-delivery.sh` takes the in-image script path as `$1` for exactly
this reason.

**But "runs on the host" does not imply "becomes a producer"** (SERV-128). The
obvious extension of the rule above — a host daemon needs a probe, the probe runs
on the host, so it is another `ExecStart` — is wrong, and signet is the case that
shows why. Two things block it:

- The unit posts under a single `PROBE_ENVIRONMENT` for all of its targets, and
  signet is not dev.
- `prod` is `probe_mode: internal`, and ingest **rejects an external probe result
  for an internal environment** with a 400 (`environment … is probed
  internally`). That guard exists so a misconfigured prober cannot fight the
  in-process reconciler over prod.

So a third `ExecStart` could only file signet under a tier it does not run in, or
justify a whole new environment column for one service.

The answer is that signet does not need a producer at all. It binds `172.17.0.1`
deliberately — its `Serve()` refuses to start if the docker-bridge bind fails,
precisely so it cannot come up answering the host while refusing every container
— so the **in-process reconciler** can reach it like anything else on
`construct_net`. It is registered as an ordinary first-party service on port 4010
and observed in the prod column, with `extra_hosts: signet:host-gateway` on the
switchyard container making prod's `http://{service}:{port}` template resolve.

Nothing was added to the host, so the one-cron rule is untouched rather than
bent. The rule to carry forward is narrower than it first reads: **a host-side
producer is for what the reconciler structurally cannot reach** — which is the
dev tier, on a disjoint network — not for everything that happens to run outside
a container.

### What the prober can see today

The whole dev tier — `switchyard`, `argosy`, `lyceum`, `purser` — since SERV-140.

**"Since SERV-140" means configured, not applied.** `PROBE_TARGETS` is rendered
into `/etc/delivery-prober/prober.env` by the `delivery_prober` role, and
`deploy.yml` rsyncs `scripts/**` without ever running ansible — so merging a
change to that role leaves the box probing whatever it probed before, with git
reading done. It takes `ansible-playbook ansible/site.yml --tags
delivery_prober` (the untagged sops `fail` pre-task is skipped on a tagged run,
so a host without the age key can apply it by supplying
`delivery_prober_token`). `make probe-status` shows the last run and
`journalctl -u delivery-prober` reports `targets=N` on every tick, which is the
cheapest way to tell which state the host is actually in.

That gap is worth naming because it is the SERV-140 shape one layer up: three
commented-out lines were at least *visible* as unfinished, and an applied-vs-
merged divergence is not visible anywhere.

For most of this design's life it was `switchyard` alone. That was never a
schedule limitation: the other three sat commented out in
`ansible/roles/delivery_prober/defaults/main.yml`, one line each, behind three
blockers. All three closed in other tickets, none of them came back here to
uncomment a line, and the dev column showed one cell out of four for weeks after
it could have shown four. The blockers, and what closed each:

- **argosy** answered `/healthz` with plain-text `ok`, which both probers
  classified as `unreachable` — a healthy argosy rendering as down. Its version
  lived at `/api/v1/ping`, which is what `health_path` exists to point at, but it
  could not self-register: registering needs a clean probe and a clean probe
  needed the `health_path` that registration would set. **SWY-292** broke the
  deadlock by classifying on content type rather than parseability — only markup
  means something in *front* of the service answered — and argosy has since
  adopted the SWY-192 shape on `/healthz` anyway. Either alone would have done.
- **lyceum** and **purser** answered `{status, service}` with no version: an
  honest `no_version`. **SERV-128**'s per-service PRs landed the health contract;
  lyceum reports a real semver and purser reports the literal `dev` for an
  unreleased build.
- **Registering any of them would have painted three *prod* cells red**, because
  the reconciler probes the environment × service cross-product using prod's
  `host_template` — then the literal `http://{service}:4002`, switchyard's port
  and nobody else's — and `service_environments.host_override` has no writer.
  **SWY-294** replaced the template with `http://{service}:{port}`, and
  `resolveProbeUrl` returns null rather than a failure for a service with no
  port, so a registration is at worst inert. `host_override` still has no writer
  and no longer needs one.

Two consequences worth stating, because both look like bugs and are not:

- **`version: "dev"` is recorded verbatim, and reads as drift.** `deriveDrift`
  does not parse semver — this estate pins bare shas as legitimate versions, so a
  semver comparison would decide an unreleased build has no drift. purser and
  argosy therefore show drifted against prod, which is exactly true.
- **A dev rebuild that leaves `version` at `dev` is still a new row.** The
  ingest's unchanged check compares version, digest *and* sha.

The infrastructure containers in the dev project — `cf-access-guard-dev`,
`traefik-dev`, `postgres-dev`, `cloudflared-dev` — are deliberately absent.
`postgres-dev` has no HTTP health endpoint at all, so tier A cannot describe it.
If they belong on the matrix that is tier B (SWY-194) work.

### A dead prober is not yet visible

The unit lands in `failed` if a probe result cannot be recorded — `make
probe-status` shows both the timer and the last run. But a timer that was never
installed, or a token that expired, leaves the page confident and stale: the
cells keep their last observed version and nothing reads a frozen `last_probe_at`
as a signal. That is the SWY-128 shape, and the real fix is environment-level
observer freshness in the matrix itself (**SWY-285**), which this ticket unblocks
by making a prober exist to die.

## Feature toggles (stretch)

Lives in Switchyard: a `feature_flags` table (key, description, per-environment state,
optional rollout percentage), served by a cached `GET /v1/flags?env=`.

The important design detail is a **flag → ticket FK**. Every flag has an owner and a
removal ticket, which is what keeps a flag system from silently becoming permanent dead
config. Build this *after* the promotion path works — flags earn their keep once you
ship often enough to need release decoupled from deploy.

## Blocking security item

A host-exposed service in the pipeline's path has an authentication weakness that
becomes load-bearing the moment a verifier agent is driving deployments.

Detail is deliberately not recorded in this public repo while the service is still
running — see **IDEA-19** and **SERV-73** in Switchyard. Resolved outright by
**SERV-82**, which decommissions the service rather than fixing it.

## Sequencing

| # | Work | Notes |
|---|---|---|
| 0 | **Hygiene** | kill orphaned processes, resolve the two-config-file compose identity, pin image tags, scope watchtower to third-party images via `WATCHTOWER_LABEL_ENABLE` |
| 1 | `environments` + `deployments` + version-matrix view | reuses existing migration / event / rule plumbing |
| 2 | Dev compose project + `dev.` Traefik tier + Signet env scoping | |
| 3 | Servo-Signal auth | independent of the rest; do it early |
| 4 | Contract tests (Purser triangle), then e2e | the only item that is real engineering rather than wiring — timebox it |
| 5 | Verified status + verifier agent | no schema migration needed |
| 6 | `promote.yml` + GitHub Environment gate | |
| 7 | Feature flags | |

Step 0 is not optional. An environment model built on a box where the running set is
not declared anywhere will encode the confusion rather than resolve it.

## Open questions for the deep dive

1. **Dev topology** — second compose project on this box (recommended) vs. a second
   machine. A second box doubles the ansible and Cloudflare surface for a lab.
2. **Scope of dev** — all services, or only those with real cross-service coupling
   (switchyard, lyceum, purser, argosy)? Running 27 services twice on one box is a
   resource question, not just a config one.
3. **Auto-promote allowlist** — which services earn it, and on what evidence?
4. **Contract-test boundary** — how far past the Purser triangle before we stop?
5. **Watchtower** — scope it to third-party images, or drop it entirely now that
   deploys would be version-pinned?
6. **Host-process dev loops** — containerize the argosy / switchyard dev servers, or
   accept host processes and just make them visible in the matrix?
