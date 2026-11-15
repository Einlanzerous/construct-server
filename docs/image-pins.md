# Image pins

Rationale moved out of the root `CLAUDE.md` (SERV-317). The rule there: first-party
tags are pinned in `versions.env` (git), third-party images by digest, and
`versions.env` is the source of truth for which form each service uses. Everything
below is why.

## First-party pins, `versions.env` and the deploy scope

**First-party image tags are pinned, and tracked `versions.env` holds the values**
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
does: six pins cover more than one service and recreate together —
`SWITCHYARD_TAG` covers **three** (backend, frontend and `switchyard-mcp`, SERV-99),
while `APERTURE_TAG`, `CENTRIFUGE_TAG` and `INTERLOCK_TAG` (web + worker) and
`CATENARY_TAG` (`catenary` + the one-shot `catenary-media-init`, SERV-244) and
`TRESTLE_TAG` (the public `trestle` + the private `trestle-genzo`, GENZO-8) cover two
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

## `postgres`

**`postgres` is pinned by digest, and recreating it breaks the Node services**
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
