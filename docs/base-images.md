# Base images

What every first-party service is allowed to build `FROM`, the check that enforces it,
and the decision on what should own the ongoing case (SERV-170).

## Why

On 2026-09-05 a reviewer caught `alpine:3.20` in a brand-new Dockerfile — inherited by
copying Chronicle's. That prompted a survey of every Dockerfile in the estate, and the
answer was that it was not a Catenary problem. On the day the guard first ran against
`main`, it reported eighteen findings across ten repos:

| what | where | since |
|---|---|---|
| `alpine:3.20` | chronicle, lyceum, placard, purser | EOL 2026-04-01 |
| `node:20` | cook_book, cta-watch (×4) | EOL 2026-04-30 |
| `golang:1.24` | aperture | EOL 2026-02-10 |
| `golang:1.25` | lyceum, **cf-access-guard** (this repo) | EOL 2026-08-19 |
| `nginx:1.27` | aperture, centrifuge, drydock, **wiki** (this repo) | EOL 2025-06-24 |
| `alpine:3`, `nginx:alpine` | centrifuge, cta-watch | floating — no cycle to evaluate |

Nothing surfaced any of it. An EOL base image builds, passes CI, deploys, and reports
healthy. The only difference is that `apk add` and `apt-get install` resolve against a
branch nobody patches, on images that are public. The ticket's own survey missed two of
these rows (Go 1.25 went EOL between the survey and the fix; nginx was never on the list)
and missed interlock's Dockerfiles entirely, because they are named `docker/web.Dockerfile`
and a `Dockerfile*` glob does not see them. A survey is a snapshot that is wrong by the
time it is read. The guard is what replaces it.

## The rule

Two conditions, per `FROM` line, in every first-party repo:

1. **Not past end-of-life.** The tag's version maps onto a release cycle of the product
   behind the image, and that cycle must still be supported. Support is asked of
   [endoflife.date](https://endoflife.date), not of a table kept here — a table is the
   thing that goes stale, which is what happened to the Dockerfiles.
2. **Not floating.** The tag names the version to at least the product's cycle precision:
   `alpine:3.23`, `node:24-alpine`, `golang:1.26-bookworm`, `debian:trixie-slim` pass;
   `alpine:3`, `nginx:alpine`, `node:latest` do not. A floating tag changes underneath a
   rebuild with nothing in the diff to show it, and it cannot be evaluated by rule 1
   either. A digest (`@sha256:…`) satisfies this rule on its own — the tag is provenance,
   the digest is the pin, the SERV-105 shape. It does not satisfy rule 1: a
   digest-pinned ref whose tag names no cycle (`FROM alpine@sha256:…`) is `UNKNOWN`, a
   finding (exit 1). The pin is real, but nothing says whether the image behind it is
   still supported, and "could not tell" is loud here. A digest on a tag that does name
   a cycle (`alpine:3.23@sha256:…`) is checked like any other ref. (SERV-294 settled this;
   the header and the FLOATING branch used to disagree.)

Cycle precision comes from the data: Alpine and Go cycles are `major.minor`, Node and
Debian are `major`, so `node:24` is pinned and `alpine:3` is not. Bun's only cycle is `1`,
so `oven/bun:1.3-alpine` passes; pin it tighter when a repo has a reason to (lyceum does,
LYCM-71), but the rule does not demand it.

A cycle inside the 90-day warning window is reported and does not fail. That is the
window in which to bump on your own schedule instead of the guard's. Go and nginx publish
no EOL date — a cycle is supported until the second-next one ships — so for those the
guard **estimates** it: the oldest supported cycle is retired by the next release, whose
date is taken as the newest cycle's release date plus one release cadence (the gap between
the oldest supported cycle and the one it replaced). `golang:1.26`
warns about 90 days before 1.28 is due and fails the day it ships. It is an estimate and
the row says so; without it the guard would go straight from OK to EOL for Go.

## The guard

`scripts/check-base-images.sh` — one script, three modes, one policy source.

- `--estate` reads every Dockerfile on every first-party repo's **default branch**
  through `gh api`, so it sees what is merged rather than what is checked out. The repo
  list is derived from `docker-compose.yml`'s `ghcr.io/einlanzerous/*` images the same
  way `verify-tag.sh` and the wiki derive theirs, plus `EXTRA_REPOS` for repos that ship
  no image here (this repo, signet, cta-watch). A new service needs no edit, and a
  derivation that matches nothing is exit 2 rather than a sweep of `EXTRA_REPOS` alone.
- `--dir ~/projects` does the same for local checkouts — the form to run before pushing
  a Dockerfile change.
- `--self-test` proves the script can **fail**: fixture policy, fixture Dockerfiles, and
  an assertion that an EOL tag, a floating tag, an unmapped image and an unreachable
  policy source each produce the non-zero exit they should. A guard that cannot fail is
  indistinguishable from a clean estate, which is the SERV-58 lesson applied here.

It **refuses rather than guesses**. An image whose product is not in `PRODUCT_MAP` is a
finding, not a skip; so is a version endoflife.date does not list, a `FROM ${VAR}` with
no `ARG` default earlier in the file, a digest-pinned ref whose tag names no cycle, and —
in estate mode — a repo whose tree the token could not read. A sweep that silently skipped the private repos would be green on an
estate it had only half examined. And when endoflife.date is unreachable it exits **2**,
never 0: "could not check" must not come out the same colour as "checked and fine".

`.github/workflows/base-images.yml` runs it **every Monday**, on `ubuntu-latest`, plus on
any PR that touches the script or the workflow. On a schedule because a base image goes
EOL with no commit anywhere — a check on the service repos' own CI would run exactly when
nobody is looking at the base image. Not on the self-hosted runner because it needs only
`curl`, `jq` and `gh`, and should still report when the box is busy or down. It is
deliberately **not a deploy gate**: a stale base image is a rotation-class problem, not a
"stop the deploy" one, and a red prod deploy is the wrong way to learn that Alpine cut a
release.

A red run emails the repo owner. That is the alarm. The fix is always in the service repo:
bump the tag to the newest supported cycle the row names, build, release, and re-run from
the Actions tab.

Locally: `make base-images-check` (the estate), `make base-images-check dir=~/projects`
(your checkouts), `make base-images-test` (the self-test, and the publish and sweep
scripts' test; CI runs it before every sweep).

## Machine-readable output

Satlink's Practices board needs the per-repo result and must not re-derive the rule (the
SERV-111 lesson: one definition of each rule). `--json` prints the result as one JSON
document; `--json-out FILE` writes the same document to a file. Exit codes are unchanged
(0 clean, 1 findings, 2 usage or policy unreachable); under `--json` the human table, the
footer and `gh`'s noise go to stderr so stdout is the document alone. A run that exits 2
prints no document and removes a stale `--json-out` file. A failure while assembling the
document is exit 2, never 1.

```
{ schema: 1, scope: "public-only" | "unfiltered", generatedAt, today,
  policy: { source, warnDays }, mode: "estate" | "dir" | "files",
  exit: 0 | 1,
  summary: { findings, warnings, ok, unreadableRepos, withheldRepos|null, visibilityUnreadable|null },
  repos: [ { repo, state, unreadablePaths|null } ],        // estate mode, else null
  images: [ { repo|null, path, line, ref, image, tag|null, digest|null, product|null,
              cycle|null, eolDate|null, eolDateEstimated, newestSupported|null,
              status, detail } ] }
```

- **One object per `FROM` line** in `images[]`, the same lines the human output reports.
  A repo or a file that could not be read is never a row (and never a fake `line 0`);
  `repos[]` carries it.
- **Nothing is coalesced.** A field the script cannot determine is `null`, never `""` or
  `0`. `eolDate: null` with `status: "OK"` is legitimate: Go and nginx publish no date,
  and `status` is what says whether the image is fine. `eolDateEstimated` is `true` when
  the date is the script's estimate (see "The rule"). `withheldRepos` and
  `visibilityUnreadable` are `null` when `scope` is `unfiltered` (not measured), never 0.
  `generatedAt` is the real clock; `today` is the policy date (`BASE_IMAGE_TODAY`).
- **`status` is the script's seven statuses, verbatim**: `OK`, `SOON` (inside the warning
  window, not a finding), and the findings `EOL`, `FLOATING`, `UNKNOWN`, `UNMAPPED`,
  `UNRESOLVED` (a `FROM ${VAR}` with no default). `cycle` is `null` unless the tag named one
  that endoflife.date lists, so a `FLOATING`, `UNKNOWN` or `UNMAPPED` row has no cycle.
- **`repos[].state`**: `read` (tree read, every Dockerfile read); `partial` (tree read, at
  least one Dockerfile read and at least one not: `unreadablePaths` names the failed ones
  and the readable files' rows stay in `images[]`); `unreadable` (the tree could not be
  read, or it read but no Dockerfile could); `no_dockerfile`.
- **`summary`** is computed from the rows the document publishes and nowhere else:
  `findings` is the `images[]` rows with a finding status plus `unreadableRepos` (repos in
  state `unreadable` or `partial`), so it reconciles against `images[]` and `repos[]`.
  This is not the human footer's count, which also counts every unreadable file.
- **`exit`** is 1 when `summary.findings > 0` or `visibilityUnreadable > 0`, else 0. It
  describes the published view only and can never exceed the process exit.
- **`detail` is free text** for a person. It is not part of the contract: do not parse it.

### Scope: public repos only

Everything published is world-readable (the repository is public, and so are the data
branch and workflow artifacts), and the sweep also reads private repos. So the filter runs
in the script, before any file exists: `--public-only` (estate mode only) publishes a repo
only when `GET repos/<owner>/<repo>` made with `PRIVACY_GH_TOKEN` exits 0 and `.private` is
exactly `false`. That token is the workflow's own `GITHUB_TOKEN`, which cannot read private
repos: a 404 is its answer for them, and a 200 `false` is itself the proof the repo is
public. It is deliberately not the sweep token, which can read private repos and would
answer 200 for them. There is no fallback: `--public-only` without `PRIVACY_GH_TOKEN` is
exit 2.

- A repo answering `private: true` or 404 is **withheld**, counted in `withheldRepos`, with
  no row, no name and no path anywhere in the document.
- Any other answer (5xx, rate limit, network, odd output) is withheld too, counted in
  `visibilityUnreadable`, and is itself a finding (process and document exit 1). Such a
  repo may be public: a consumer must treat a repo absent from `repos[]` as **unreadable**,
  never as clean, whenever `visibilityUnreadable` is above 0.
- Withheld repos are still swept, so a finding in one still turns the Monday run red (the
  process exit is whole-sweep). **`exit: 0` in the document therefore means the public view
  is clean and says nothing about the estate: never render it as estate-green.** The
  document can never say whether a withheld repo is healthy.
- The run log and the step summary still print every row, private repos included. That is
  existing behaviour this change does not touch (SERV-350).

### Where it is published, and how fresh it is

`base-images.yml` writes `base-images.json` to the `estate-results` branch of this repo,
as a single orphan commit force-pushed each run (no history; the file is a current
reading, not a ledger). Read it with `GET repos/Einlanzerous/construct-server/contents/base-images.json?ref=estate-results`.
Only the sweep's scheduled, `main`-push and `main`-dispatch runs publish; a pull request
never does. The publish job refuses a document that is not `scope: "public-only"`, that
does not parse, whose `schema` is not 1, or that is older than the branch's `generatedAt`.

The sweep is weekly, so a document up to 7 days old is normal. **Treat a `generatedAt`
older than 9 days as unreadable.** A 404 on the file (no branch, no file) is `unreadable`,
not an empty estate. A red sweep means findings; a red publish job means the file is stale.

### Stability

`schema` is an integer. A change that adds a field, or a value to a closed set, is
compatible and does not bump it; a consumer must ignore fields it does not know. Removing
or renaming a field, or changing what one means, bumps `schema`, and the publish job and
every consumer refuse a `schema` they do not know.

## What the guard does not cover, deliberately

- **Third-party images in `docker-compose.yml`.** `traefik:v3.3` is EOL (2025-05-05,
  Traefik supports only its newest minor), `redis` named a bare major (`7-alpine`) where
  Redis cycles are `major.minor` until SERV-179's first PR moved it to `7.4-alpine`, and
  the four watchtower leaves float by design (SERV-75).
  That is a different sweep with a different exemption list — it is SERV-105's domain and
  has its own ticket. The wiki's nginx was bumped alongside because the sweep that found
  the service repos' nginx found it too — but it is a compose `image:`, not a `FROM`, so
  **its pin stays manual until SERV-179**; when 1.30 goes EOL, Monday's run will not say so.
- **sextant.** It has a Dockerfile (`golang:1.26-alpine` → distroless, clean) but its
  checkout has no git remote, so `--estate` cannot read it; only `--dir ~/projects` does.
- **Vulnerabilities.** A supported base can still ship a CVE. That is a scanner's question
  (Trivy or Grype in the publish workflows), not this one's, and it is worth its own
  ticket rather than being bolted on here.
- **The Go and Node versions in CI.** `setup-go` / `setup-node` pins were bumped where a
  Dockerfile was, so tests run on the toolchain the image ships. The guard does not read
  workflows; a CI toolchain older than the image is a warning sign, not a security hole.

## Decision: what owns the ongoing case

The ticket asked for a recommendation on whether to build a service for this or adopt
one. The answer has two halves, because there are two jobs.

**The policy check stays as it is — a script and a schedule, not a service.** It is a
few hundred lines of bash with no state, no port and no consumer other than a red run.
The estate's own rule (SERV-111) is that a producer with nothing to store is a cron and
not a container, and a "base image monitor" service would be a fourth thing rendering
the same endoflife.date JSON. It also should not become a Switchyard instrument or a
delivery-ledger column: the ledger records what is *running*, and base-image support is
a property of *source* whose consumer is a pull request, not a dashboard.

**The bump PRs should come from Renovate, and that is the recommended next ticket.** The
guard says "this is stale"; someone still has to open nine PRs. Of the options:

| option | what it gives | why not on its own |
|---|---|---|
| **Renovate** (Mend-hosted GitHub App, or self-hosted) | Opens the bump PR the week a new cycle ships, across `Dockerfile`, `docker-compose.yml` (**with digest pinning** — the SERV-105 shape, kept current), `go.mod`, `package.json`, `bun.lock` and GitHub Actions, from **one shared preset** in this repo that every service repo `extends`. | Knows what is *newest*, not what is *supported* — it will happily leave `alpine:3.20` alone if nobody merges the PR. That is what the guard is for. |
| Dependabot | Zero infrastructure, already in GitHub. | Per-repo config with no shared preset, so sixteen copies that drift; no digest pinning for compose; no grouping of a `major.minor` policy. |
| xeol / Trivy | Scan built images for EOL packages and CVEs. | Answers a different question (what is *inside* the image), at publish time rather than on a clock. Worth adopting for CVEs; not a replacement for the FROM-line rule. |
| A recorded convention plus a periodic manual sweep | Honest, no machinery. | Is the status quo that produced eighteen findings. |

Renovate over Dependabot specifically because of the shared preset and compose digest
pinning. Hosted over self-hosted because a Renovate container on this box would run on the
runners that already race each other over `$HOME` (SERV-114), and the app has no reason to
be inside the estate's network. Two things to settle in that ticket before turning it on:

- **The reviewer race.** Renovate opening a Node bump in six repos at once is exactly the
  burst SERV-114 describes. Either land SERV-114 first, stagger with per-repo `schedule`
  and `prConcurrentLimit`, or have `pr-review.yml` skip `renovate[bot]` authors — the
  bumps are one-line and the guard already reviews them.
- **Private repos.** amber and switchyard need the app installed with access to them; the
  hosted app's terms for private repositories should be checked at the time, not assumed.

Until then the guard is the whole mechanism, and it is sufficient for the ticket's
"something that fails when this stops being true": the next answer to "how many repos are
on an EOL base" is Monday's run, not another survey.

## Adding a product

A `FROM` on an image the script has never seen fails as `UNMAPPED`. Add the image
repository to `PRODUCT_MAP` in the script, keyed as written in the Dockerfile with
`docker.io/library/` stripped, valued with the endoflife.date product slug
(`https://endoflife.date/api/v1/products/<slug>`). Do not add an exemption instead: an
image the policy cannot evaluate is the case the guard exists to make loud.

## Traps (moved from `CLAUDE.md`, SERV-317)

**A base image names a supported cycle, to cycle precision, in every first-party
Dockerfile** (SERV-170). `alpine:3.23`, `node:24-alpine`, `golang:1.26-bookworm`;
never `alpine:3`, `nginx:alpine` or `latest`. On 2026-09-05 four repos were on an
Alpine five months past EOL, two on a Node four months past, and three nginx runtimes
fifteen months past — including this repo's wiki — and nothing surfaced any of it,
because an EOL base builds, deploys and reports healthy. `base-images.yml` sweeps every
repo's default branch each Monday against endoflife.date and goes red; it is
deliberately **not a deploy gate**. It reads `FROM` lines only: the wiki's nginx is a
compose `image:` and **its pin stays manual until SERV-179**. Two traps. A new Dockerfile written by copying an
old one inherits its base, which is how catenary got `alpine:3.20` in 2026-09 (CANT-78).
And `cf-access-guard` is built **here**, so its `golang:` pin is this repo's to keep
current — a toolchain bump there is validated by the `--target test` build, the same
one CI runs. `docs/base-images.md` is the rule and the decision of record.
