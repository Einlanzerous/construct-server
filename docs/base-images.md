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
   the digest is the pin, the SERV-105 shape.

Cycle precision comes from the data: Alpine and Go cycles are `major.minor`, Node and
Debian are `major`, so `node:24` is pinned and `alpine:3` is not. Bun's only cycle is `1`,
so `oven/bun:1.3-alpine` passes; pin it tighter when a repo has a reason to (lyceum does,
LYCM-71), but the rule does not demand it.

A cycle inside the 90-day warning window is reported and does not fail. That is the
window in which to bump on your own schedule instead of the guard's.

## The guard

`scripts/check-base-images.sh` — one script, three modes, one policy source.

- `--estate` reads every Dockerfile on every first-party repo's **default branch**
  through `gh api`, so it sees what is merged rather than what is checked out. The repo
  list is derived from `docker-compose.yml`'s `ghcr.io/einlanzerous/*` images the same
  way `verify-tag.sh` and the wiki derive theirs, plus `EXTRA_REPOS` for repos that ship
  no image here (this repo, cta-watch). A new service needs no edit.
- `--dir ~/projects` does the same for local checkouts — the form to run before pushing
  a Dockerfile change.
- `--self-test` proves the script can **fail**: fixture policy, fixture Dockerfiles, and
  an assertion that an EOL tag, a floating tag, an unmapped image and an unreachable
  policy source each produce the non-zero exit they should. A guard that cannot fail is
  indistinguishable from a clean estate, which is the SERV-58 lesson applied here.

It **refuses rather than guesses**. An image whose product is not in `PRODUCT_MAP` is a
finding, not a skip; so is a version endoflife.date does not list, a `FROM ${VAR}` with
no `ARG` default earlier in the file, and — in estate mode — a repo whose tree the token
could not read. A sweep that silently skipped the private repos would be green on an
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
(your checkouts), `make base-images-test` (the self-test).

## What the guard does not cover, deliberately

- **Third-party images in `docker-compose.yml`.** `traefik:v3.3` is EOL (2025-05-05,
  Traefik supports only its newest minor), `redis:7-alpine` names a major where Redis
  cycles are `major.minor`, and the four watchtower leaves float by design (SERV-75).
  That is a different sweep with a different exemption list — it is SERV-105's domain and
  has its own ticket. The one third-party image this repo *builds from* rather than runs,
  the wiki's nginx, was fixed alongside because it is the same class as the service repos'.
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
