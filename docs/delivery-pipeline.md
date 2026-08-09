# Delivery Pipeline — dev, prod, and the Verified gate

Design of record for how code reaches the Construct. Tracked in Switchyard under
**IDEA-19**; this doc is the starting point for the deep dive that graduates it to
an epic with per-service children (SERV / SWY / SGNT / LOOP).

**Status: design only.** Nothing below is built. Current state is described in
*Where we actually are*, and it is the reason step 0 is hygiene rather than features.

**Now ticketed.** The Switchyard slice is **SWY-184** (children SWY-185…194); the
construct-server slice is **SERV-73** (children SERV-74…81). Where a ticket and this
document disagree, the ticket is newer.

**Superseded since writing.** imperium-loop is being wound down (SERV-82), so the
Servo-Signal rows in *Shape* and **sequencing step 3 are dropped, not deferred**. The
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
and `PROD_ENV_FILE` carries real values: major.minor for the services with
release-please versions, a sha for argosy and drydock, which publish no semver.
Verified by deploying twice from `main` with no merge in between and diffing the
running digests — identical, and the second deploy recreated nothing.

Pinning also made the drift legible for the first time. Two services were not
where anyone thought: **amber** was running an image *older* than its own `0.5.0`
release, and **purser** a main-branch build *newer* than `0.13.0`. Both are pinned
to what they were actually running, so the change moved no versions; reconciling
them is a deliberate decision rather than a side effect.

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

**9. Post-prod smoke.** On failure, auto-rollback to the last-good version, which the
`deployments` table already knows.

**10. Close.** Ticket resolution → `released`.

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
