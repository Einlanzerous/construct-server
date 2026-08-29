# The post-deploy verifier

Design of record for SERV-80. The second pass in the delivery pipeline
(`docs/delivery-pipeline.md`, IDEA-19): the PR reviewer reads the diff before it
merges, the verifier reads the **running system** after it deploys.

## What it is for

The two passes answer different questions, and the difference is the whole
argument for having both:

| | asks | evidence |
|---|---|---|
| PR reviewer (SERV-59) | is this change correct? | the diff |
| Verifier (SERV-80) | does the deployed thing do what the ticket said? | dev, live |

A change can be correct and incomplete, correct and mis-configured, or correct
and never actually reach the environment — SERV-109 records a scoped deploy going
green having shipped no change at all, and SERV-102 records switchyard sitting at
a failing healthcheck streak of 12 while the deploy that caused it stayed green.
The diff cannot see any of those.

## Shape

`.github/workflows/verify.yml`, a Claude Code job on the self-hosted runner —
the same pattern as `pr-review.yml` (SERV-59) and explicitly **not** IDEA-19's
Servo-Signal design. IDEA-19 specified the verifier as an agent running on
Servo-Signal, which made its unauthenticated `/mcp` on `:8090` a hard
prerequisite. imperium-loop is being wound down, so a runner job does the same
work with no long-lived service, no exposed port and no ambient credential. That
takes Servo-Signal auth off the critical path, which was IDEA-19's cross-system
item 1.

Two jobs, for the SERV-87 reason: declining to verify has to be a **skipped**
job, not a green one.

- **`resolve`** — validates the ticket key, reads the ticket, and decides whether
  there is anything to verify. It **does not check out**, the same way the
  reviewer's triage job does not, which is what keeps it cheap enough to always
  run. Nothing in it may invoke `make` or read a repo file.
- **`verify`** — checks out, snapshots what dev is running, runs the model
  against `.github/verify-prompt.md`, classifies the run, then gates on a
  readable `verify-verdict.json`.

The version snapshot lives in `verify` and not in `resolve` precisely because it
needs the working tree. Moving it "up" to `resolve` for tidiness is the shape
that does not work.

The prompt is the deliverable and the model is configuration (SERV-64 tracks
moving the backend to a local gemma). Judgement lives in `CLAUDE.md` and
`PRINCIPLES.md` §9; procedure lives in `.github/verify-prompt.md`; this workflow
is meant to stay small.

## It records. It does not gate.

Nothing the verifier writes blocks a promote or moves a ticket. SERV-80 asks for
this and gives the reason: a verifier that blocks before it has earned trust
converts every false negative into a production incident. `PRINCIPLES.md` §9
already takes the same position for concerns.

This is enforced by the **credential**, not only by the prompt. The token carries
`tickets:read` + `comments:write` and deliberately not `tickets:write`, so a
verifier cannot transition a ticket even if something talked it into trying.
A verdict of `not_met` is a *successful* verification and the check stays green —
failing on it would make the verifier a gate by the back door, and would train
everyone to re-run it until it went green.

## Why the verdict is a comment and not a plan review

This is the part most likely to be "fixed" by someone reading IDEA-19, so it is
written down here.

IDEA-19 and SWY-189 both state that no migration is needed — *"the verifier is a
second row in tables that already exist"*, citing `plan_criteria` holding a
`verdict` and `reviewer_note` per criterion and `plan_reviews.reviewer_id` FKing
to a user whose `user_type` may be `agent`. **That is true of the review row and
false of the per-criterion verdicts.** Measured against switchyard's schema:

- `plan_criteria.verdict` is a **single column on the criterion row**
  (`server/drizzle/schema.ts`), not a per-review join table. A verification
  posting `criteria_verdicts` through
  `POST /v1/tickets/{key}/plan/revisions/{rev}/review` **overwrites the plan
  review's verdicts in place**. There is no second slot.
- `resolvePlanOutcome` settles a plan from the latest verdict of each reviewer on
  the current revision. So a post-deploy verification posting `approved` or
  `rejected` would count as a reviewer vote and could **approve or reject the
  plan itself**.
- The enums have no vocabulary for this pass: `plan_criterion_verdict` is
  `pending|approved|rejected` and `plan_review_verdict` is
  `approved|changes_requested|rejected`. There is no value meaning "observed, not
  gating", and nothing at all stores an **advisory** — which SWY-189 requires be
  rendered separately from criteria precisely so a non-blocking observation
  cannot masquerade as a failure.
- `SubmitReviewInput` carries no environment, deployed version, commit or run id,
  so a verification written through it could not say what it verified against —
  and SWY-189's own design makes the environment strip the strongest of the four
  devices distinguishing pass 2 from pass 1.

A ticket comment is structurally incapable of any of those failures, needs no
migration, and touches nothing SWY-108 (phase 7) is actively reshaping. Wiring
the structured write is SWY-189's, and **it needs a schema change nobody has
scoped** — per-review criterion verdicts, an environment/deployment reference,
and somewhere to put advisories.

## Triggering

Ticket-keyed, not deploy-keyed:

```
gh workflow run verify.yml -f ticket=SERV-80
```

and `repository_dispatch` with type `verify` and payload `{"ticket": "SERV-80"}`
for a service repo's release pipeline to call.

**Automatic post-deploy triggering is deliberately not wired yet**, and the
blocker is real rather than effort. "Which ticket does this dev deploy verify?"
has no reliable answer today: `deploy-dev.yml` deploys *service images*, so the
commits that matter live in the service repos, and the hourly cron moves whatever
happened to publish since the last tick. SERV-108's dispatch payload (source repo
+ sha) is the seam that can resolve it once something populates a ticket key
there. Guessing one would verify the wrong ticket **silently**, which is worse
than asking — the same silent-pass class the reviewer's concurrency key records
six variants of.

## Concurrency

Grouped per ticket with `cancel-in-progress: false` — the **opposite** of the
reviewer's key, and easy to get backwards. A newer diff supersedes an in-flight
review, so cancelling is right there. Nothing supersedes an in-flight
verification: cancelling one and letting its replacement decide it has nothing to
do is exactly the silent pass the reviewer's key encodes three incidents of. A
second request queues.

## Setup

The token is minted per consumer, because `PRINCIPLES.md` §9 makes *"a credential
reused across consumers rather than minted per-consumer"* a finding — the PR
reviewer's `SWITCHYARD_REVIEWER_TOKEN` is a different consumer even though its
scopes happen to match.

```bash
./scripts/mint-verifier-token.sh
```

It creates a `post-deploy-verifier` agent user if absent, mints a token, and
**asserts the granted scopes** before handing it back. That assertion is not
ceremony: `scopes` defaults to `admin` server-side when omitted, so a typo in the
field *name* mints a working admin token and nothing ever surfaces it (SERV-128
learned this on the prober).

Then add it as `SWITCHYARD_VERIFIER_TOKEN`. Prefer Signet so rotation happens in
the vault rather than per repo; the script prints both forms.

Until the secret exists, `verify.yml` **fails loudly on its first step** rather
than skipping. A verification nobody can read is not a verification, and a
verifier that quietly records nothing is indistinguishable from one that found
nothing wrong.

## Reaching dev

Dev publishes on loopback, which is why this runs on the host runner rather than
in a container: nothing outside the dev compose project is attached to
`construct_dev_net`, and keeping it that way is what makes "dev cannot reach
prod" structural (SERV-77, SERV-93). The host can reach both, so the verifier
probes from there — the same argument that put the delivery prober on the host
(SERV-111).

Ports are the `DEV_*_PORT` variables in `docker-compose.dev.yml`
(switchyard-dev `14002`, lyceum-dev `14005`, purser-dev `14006`, argosy-dev
`18096`, postgres-dev `55432`).

## Validating a change to it

- `actionlint .github/workflows/verify.yml` and `make workflow-size` — the
  reviewer's triage block came within 561 characters of breaking every review
  over accumulated shell comments (SERV-150), and this workflow is written with
  its prose in YAML comments above each step for that reason.
- `gh workflow run verify.yml -f ticket=<key>` against a ticket you know the
  answer for. A verifier is only worth anything if you have checked it can say
  `not_met` — the same reason `make lint-gate-test` exists for a gate that fails
  open.
- Read the verdict, not the check colour. Green means "a verdict was produced",
  which is deliberately not the same as "everything passed".
