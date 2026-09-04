# Estate Wiki — generated tier-1 documentation

The cross-repo view of what the Construct actually is, right now. Tracked in
Switchyard as **SERV-101**; the aspirational notes-and-discussion tier that layers
on top of it is **IDEA-21** and is deliberately a different system.

**Live at** `wiki.zerogravity.industries` — tunneled, behind Cloudflare Access,
same pattern as Switchyard and Lyceum.

## The load-bearing rule

**Generated, published read-only, never hand-edited.**

The failure mode of a systems wiki is drift, and a drifted wiki is worse than no
wiki because it lies confidently. So this tier has exactly one owner and it is not
a person — the same discipline release-please has over `CHANGELOG.md`.

Two consequences worth stating plainly:

- **The generator is the product**, not the site. VitePress is a view of the
  corpus. Tier 2 is expected to layer on the same corpus, which is why the
  generator emits Markdown to disk rather than rendering HTML directly.
- **`wiki/docs/` is wiped on every run.** A file placed there by hand disappears
  without warning at the next build. The one exception is `.vitepress/`, because
  config is code rather than content.

Anything a person wants to *write* belongs in tier 2, or in the relevant repo's
`CLAUDE.md` where it will be maintained next to the thing it describes.

## What it reads

Everything was already present; the gap this closes is that nothing assembled it.

| Source | Contributes |
|---|---|
| `docker-compose.yml` | services, images, ports, mounts, networks, `depends_on`, env var names |
| `versions.env` | what version of what is live, and what each pin does on a pull |
| `docker-compose.dev.yml` | the dev tier, rendered as a diff against prod |
| each repo's `CLAUDE.md` / `README.md` | intent and invariants, reproduced verbatim |
| each repo's `docs/architecture.archify.json` | its own system map, rendered onto its repo page |
| `docs/*.md`, `PRINCIPLES.md`, `CLAUDE.md` | the design documents, reproduced verbatim |

The repo list is **derived from the first-party images in compose**, so adding a
service to the stack adds it to the wiki with no second edit. Only repos that ship
no image at all (`construct-server`, `signet`) are named explicitly, in
`wiki/generate/sources/repos.ts`.

**Not ingested yet: switchyard's `graphify-out/graph.json`.** SERV-101 lists it
among the available sources — 4,939 nodes and 9,831 edges of code graph, already
CI-refreshed — and it is deliberately deferred rather than forgotten. It covers one
repo out of twelve, it is a different kind of content from everything else here
(symbol-level, not estate-level), and rendering it usefully means a graph view
rather than a Markdown page. Worth revisiting once there is a second repo with the
same artefact; until then it would be a large one-off feature serving a single
service.

## Two rules inside the generator

**It parses raw YAML, never `docker compose config`, and never reads a `.env`.**
The resolved view interpolates every variable, so running it would pipe the
contents of `PROD_ENV_FILE` into a Markdown page. The tracked compose file contains
no secret by construction (SERV-31): an `environment:` entry is either a literal
that was already public or a `${VAR}` reference whose value lives somewhere the
generator cannot see. Env tables therefore show variable **names**, and values only
where the tracked file spells one out. That safety argument holds only while this
stays true — if a future change needs resolved values, it needs a different
argument, not a quiet exception.

**It keeps comments.** The compose file carries genuinely good prose — why
Watchtower's label gate exists, why Ollama's context is 64K, what an `extra_hosts`
line is working around. `docker compose config` discards all of it, and a wiki
assembled from the resolved model would be a table dump with the documentation
stripped out. Comments are lifted onto the service and env-var they sit above and
rendered as quoted material.

## Architecture maps (SERV-159)

A repo can commit **`docs/architecture.archify.json`** — a typed JSON IR — and its
wiki page grows an **Architecture** section: an interactive system map with pan and
zoom, search, guided views, and `SRC` chips on each component that deep-link to the
code the component is a claim about. A repo without the file simply has no map, the
same degrade-don't-fail posture as a repo with no `CLAUDE.md`.

**This keeps the load-bearing rule rather than bending it.** The IR is the source
and it lives in the repo it describes, which puts it in exactly the category
`CLAUDE.md` is already in: maintained next to the code, reviewed in that repo's PRs,
owned by the people who would notice it going wrong. The *render* is the generator's
job. Nothing hand-made lands in `wiki/docs/`, which is still wiped on every run.

**The maps are the one thing on this site that is framed, and the origin has to
allow it.** `config/wiki/nginx.conf` sets `X-Frame-Options: DENY` at the server
level, which — unlike `SAMEORIGIN` — has no same-origin exception, so the repo page
would render its heading, provenance line and a working full-screen link around an
*empty frame*, with the build, the log and the page structure all green. A
`location /architecture/` block relaxes it to `SAMEORIGIN` for the maps alone. Note
what could not have caught this: `vitepress build` sends no such header, so a map
verified in the build output is still broken through nginx. Only a request through
the deployed path answers it, which is what `REVIEW.md` already says about anything
at the edge.

**And editing that file is not enough to change the origin** — `deploy.yml` now
recreates the `wiki` container when a commit touches `config/wiki/`, because
neither half of the obvious reasoning holds. `up -d` does not recreate `wiki`: its
spec does not drift (digest-pinned image, unchanged mount paths), so compose
correctly leaves it alone on the full path as much as the scoped one, and nginx
reads its config once at startup. A reload would not help either: the config is a
**single-file** bind mount and `rsync -a` renames a temp file over the target, so
the inode the container is bound to is replaced and the container keeps reading the
old one. The result without the recreate is the correct config sitting at
`$DEPLOY_ROOT` two directories from the process that needs it, with the deploy
green, `assert-healthy` green, and `check-compose-drift.sh` reporting nothing —
it compares mount *sources* and the project root, neither of which changed.

It also answers the reviewer note on #108 asking for a code-level layer. An authored
map per repo is the estate-level shape of that layer — unlike
`graphify-out/graph.json`, which is symbol-level, single-repo, and still deferred
above for the same reasons.

The `<REPO>_TAG` pin on the same page says **what** is running. The map says **how
it is put together**, and the `SRC` chips say **where that claim comes from** — at a
pinned commit, so the links stay true as the code moves, and go visibly stale rather
than silently wrong.

### The convention

`schema_version: 1`, `diagram_type: architecture`, and a `meta.repository` of
`{ url, revision }` pinned to a **full 40-character SHA**, with components carrying
`sources[]`. `meta.quality_profile` is the author's call and the wiki does not
override it: archify's `showcase` profile treats a crossed edge, a shared corridor
or a label overlapping a node as an *error*, which is most of why the maps are worth
reading — but a shape that genuinely cannot be drawn planar is entitled to
`standard`, and forcing the stricter profile from here would fail a map for a
decision made in another repo.

Authoring an IR is per-repo work and belongs in that repo's project, not here. What
this repo owns is the pipeline: cache the file, put the pinned commit on disk,
render, and put the result on the page.

### Evidence needs a git object store, and that is why the build container changed

archify does not take the `sources[]` on trust. It verifies them **locally with
git** before it will render: the checkout must have a remote literally named
`origin` whose slug matches `meta.repository.url`, `git cat-file -e <sha>` must
succeed, and every source path must be a blob at that revision. Without a
`--repo-root` it refuses the diagram outright.

The chosen answer is to **shallow-fetch the pinned commit**, in `fetch.ts`, into
`.repo-docs/<repo>/.evidence`:

```
git init                                   # in the evidence directory
git remote add origin https://github.com/Einlanzerous/<repo>
git fetch --depth 1 <url-or-local-path> <sha>
```

Three things about that recipe are deliberate.

- **An object store, not a checkout.** archify reads every source with `git
  cat-file`, so nothing needs a working tree. For this repo the pinned commit costs
  848 KB and about half a second.
- **`origin` is set to the canonical URL for the repo the page is about, not to the
  one the IR names.** archify compares the two; pointing `origin` at the IR's own
  value would make that check vacuous. As written it asserts that a repo's map
  actually describes that repo.
- **The token never touches the URL or `.git/config`.** A URL on the command line
  shows up in `ps`, and one written with `remote add` is persisted inside the
  workspace. Credentials go in `GIT_CONFIG_*` as an `http.<url>.extraheader`, which
  is the form `actions/checkout` uses. `GIT_TERMINAL_PROMPT=0` goes with it —
  without that, a private repo and no token is a hung build rather than a warning.

The alternative was to strip `sources` and `meta.repository` before rendering, which
needs no git at all. It was rejected: the evidence links are most of what a map has
over the Mermaid the wiki already renders, and a map that cannot say where its claims
come from is a picture rather than documentation.

Because both the fetch and the generate step now need git, the build container is
`node:22` rather than `node:22-alpine` — see *Working on it* below for why `apk add
git` is not the cheaper option it looks like.

### archify is vendored, and pinned

`wiki/vendor/archify/`, at the release named in `vendor/archify/skill-release.json`
(MIT, [tt-a1i/archify](https://github.com/tt-a1i/archify)). Vendored rather than
installed because it is `private: true`, is not on npm, and its repository root has
no `package.json`, so neither a dependency nor a git dep can reach it. Pinned to one
release per SERV-91 — never a floating checkout.

It has **no runtime dependencies**, which is what makes vendoring cheap: `npm ci`
never sees it and the pin cannot drift underneath the build.

**To bump it:** clone the new tag, copy `archify/` over `wiki/vendor/archify/`, and
drop `test/` and `examples/` — those two directories are 5 MB of the 7.5 MB and
nothing at runtime reaches them. Do **not** trim further by intuition: `scripts/` is
half development tooling and half the artifact checker the CLI shells out to on every
render, and dropping it produces the maximally unhelpful `Artifact checker failed
without a parseable receipt`. `wiki/vendor/` rather than `wiki/tools/` so the
pre-push lint gate prunes it — `vendor` is already on its list of directories that
never hold source we own (SERV-58).

### A map must never be able to fail the build

archify is strict, the IRs are written in other repos, and the wiki must not become
the thing that stops publishing because someone moved a node in switchyard. So every
failure — malformed JSON, a layout error, a pinned commit that a force-push removed,
a timeout — becomes a `::: warning` block on that repo's page carrying archify's own
diagnostic and its suggested fix, and the rest of the corpus is emitted unchanged.
The same failures are named in the build log, because a warning block is only seen by
someone who visits the page.

**"Leaves nothing but a warning block" is load-bearing, and a timeout nearly broke
it.** archify stages its candidate *inside* the output directory it is given and
removes it in a `finally`, which does not run when the render timeout kills it. Aimed
straight at `docs/public/`, a timed-out map would leave a partial artifact exactly
where VitePress copies `public/` verbatim — the wiki publishing its own wreckage.
The generator therefore renders into a scratch directory under the system tmpdir and
copies only a finished map in. Sweeping the leftovers afterwards was tried first and
is *nearly* right: it still loses to an orphaned renderer grandchild that recreates
the staging tree after the sweep, which is observable — kill a render early enough and
the scratch directory reappears in `/tmp` after the generator has already deleted it.
Keeping archify out of `docs/` has no such window.

The diagnostic is rewritten to name `docs/architecture.archify.json` rather than the
path inside the build's cache: the person who can fix it is in the other repo.

## Layout

```
wiki/
  package.json          # the whole toolchain: generator + renderer
  generate/
    index.ts            # entry point; wipes docs/ and writes the corpus
    fetch.ts            # fills .repo-docs/ from the GitHub API (or ~/projects)
    model.ts            # assembles the sources into one model
    sources/            # compose.ts, versions.ts, repos.ts, architecture.ts — reading
    emit/               # one module per page family — writing
    lib/md.ts           # Markdown helpers
  vendor/archify/       # the diagram renderer, pinned (SERV-159)
  docs/                 # GENERATED. Wiped every run.
    .vitepress/config.ts  # the only hand-maintained file under docs/
config/wiki/nginx.conf  # static server config, mounted into the container
```

## Working on it

```bash
make wiki-fetch-local   # cache repo docs from ~/projects (fast, no token)
make wiki-generate      # emit the Markdown corpus only — the fast inner loop
make wiki-serve         # hot-reloading preview on http://localhost:5173
make wiki-build         # full static build, exactly as deploy.yml does it
```

`wiki-build` runs in a `node:22` container. That is deliberate: it pins the
toolchain so a host node upgrade cannot change what gets built, and it means the
deploy runner needs only docker — which matters because that runner is a systemd
service with a bare system PATH and no login shell (the trap SERV-62 hit twice).

**The Debian image rather than `node:22-alpine`, and the reason is git.** The
architecture maps below verify their source evidence with `git cat-file` before
archify will render one, so both the fetch and the generate step need a git binary.
Alpine ships none, and `apk add git` is not the cheaper option it looks like: the
container runs `--user $(id -u)` so that what it writes into the mounted checkout
belongs to the invoker, and that user cannot install packages. It would also be a
floating install of exactly the kind SERV-91 exists to stop.

Be precise about what that buys, though: `node:22` **carries** git in its base image,
it does not **pin** it. The tag is rebuilt on every 22.x patch and every Debian base
refresh, so the git version behind it moves with no edit here — the same
stable-looking-tag trap `CLAUDE.md` records for `traefik:v3.3` and
`postgres:16.15-alpine`. The `--user` argument is the one that decides this; SERV-91
is no more satisfied here than it was by `node:22-alpine`.

## How it deploys

**Its own workflow, `wiki.yml` — deliberately not `deploy.yml`.** It builds the
site and rsyncs it to `$DEPLOY_ROOT/wiki/site`, which the `wiki` container serves
read-only. The site is **content, not an image**, so a docs change updates it with
no container recreate at all, and no compose action of any kind.

The split exists for two reasons, both found in review on #108 after the build
initially lived inside `deploy.yml`:

- **Documentation must not be on the critical path of shipping the stack.** The
  build ran before `docker compose up -d` with no `continue-on-error`, so an npm
  registry outage, a failed `docker pull`, or a Vue-hostile character landing in an
  unrelated repo's README could abort a deploy — *after* the rsync step had already
  put new config on the box, leaving it holding new files against old containers.
  That is the exact opposite of the degrade-don't-fail behaviour the fetch step was
  written for.
- **A README edit must not roll a service.** The wiki's sources include
  `README.md`, `CLAUDE.md` and `docs/**`. Adding those to `deploy.yml`'s `paths:`
  meant a docs-only push ran `docker compose pull` — and under major.minor pins, a
  pull is precisely where a new patch release enters. Editing a README could
  therefore ship a version nobody chose at that moment. That unattended-change
  property is what SERV-75 took away from Watchtower; it should not return through
  the docs.

The `wiki/site` directory is generated content and so is **not in the repo**. That
matters more than it sounds: if compose reaches the missing bind source first, the
Docker daemon creates it as **root**, and every later rsync (running as the runner
user) fails against it permanently. `ansible/roles/server` claims the path before
`Start Docker Stack` on a cold host, and `deploy.yml` `mkdir -p`s it to cover the
ordering race on a warm one — nothing sequences the two workflows.

### Cloudflare bring-up (one-time, manual)

Two distinct pieces of Zero Trust config, in this order. Neither is created by the
deploy — the stack side (compose service + Traefik router) ships itself, but the
edge is dashboard state.

**1. Access application first.** Zero Trust → **Access → Applications → Add an
application → Self-hosted**. Domain `wiki.zerogravity.industries`, with an
Allow-by-email policy and the one-time-PIN IdP, exactly like Switchyard (SERV-24).
Plain self-hosted is the right type here — this is a browser app, not the MCP
application type that SERV-100 needs.

**2. Tunnel public hostname second.** Zero Trust → **Networks → Tunnels →** the
construct tunnel → **Public Hostname → Add**. Hostname
`wiki.zerogravity.industries`, service **`http://traefik:9080`** — not https, not a
host port. This creates the proxied DNS record for you; there is no separate DNS
step.

**The order is the whole point.** Access on a hostname that does not route yet is
harmless — requests error until the tunnel route exists. A tunnel route on a
hostname with no Access policy is an open door. Same warning as the runbook in
`docs/zerogravity-edge.md`: add the policy BEFORE mapping, else the app is open.

Verify with an unauthenticated request: it must `302` to the Access login, not
serve the wiki.

**What the origin checks, and what it does not.** Since SERV-106 the origin
validates `Cf-Access-Jwt-Assertion` itself: the `wiki` router carries the
`cf-access-jwt` middleware, so a request arriving at Traefik's `internal`
entrypoint with a `wiki.` Host and no valid token for the wiki's own AUD gets a
403 rather than the site. That matters more here than for Switchyard and Lyceum,
which authenticate their own users — nginx serving static files will hand the
estate map to whoever asks, so for the wiki that middleware is not defense in
depth, it is the entire gate.

What it does **not** cover is the backend directly: any container already on
`construct_net` can reach `http://wiki:80` and bypass Traefik altogether. The
guard sits on the router, not on the service. That is acceptable for this content
and worth knowing before anything more sensitive is put behind the same pattern.

### The optional token

`WIKI_DOCS_TOKEN` is a repo-level GitHub secret used only by the workflow, so it
belongs to Signet like the reviewer's tokens:

```bash
signet set --project construct-server --name WIKI_DOCS_TOKEN
signet target add --secret construct-server/WIKI_DOCS_TOKEN --gh-repo Einlanzerous/construct-server
signet sync
```

It needs **Contents: Read** on the estate's repos and nothing else.

**The rate limit matters more than the privacy.** The first run after merge made
this concrete: unauthenticated GitHub API calls are capped at 60/hour per IP, this
fetch makes 12 repos × 4 files = 48, and on a shared runner IP it 403'd partway
through — most repo pages came out empty even though ten of the twelve repos are
public. So `wiki.yml` passes the workflow's own `GITHUB_TOKEN` as a fallback, which
costs nothing to configure and lifts the ceiling to 1,000/hour.

That leaves `WIKI_DOCS_TOKEN` responsible for exactly one thing: the two **private**
repos, `amber` and `switchyard`. Without it their pages render compose-derived facts
and a link out to GitHub.

Neither token can fail the build. `fetch.ts` prefers `WIKI_DOCS_TOKEN`, falls back
to `GITHUB_TOKEN`, degrades to a warning if neither can read a repo, and stops the
loop on the first rate-limit response rather than turning one problem into fifty
lines of noise. A documentation fetch must not be able to block shipping the stack.

## Why not a wiki app

Docmost, Outline and BookStack were the obvious alternatives. Each buys editing,
full-text search and an off-the-shelf MCP server, and each costs another stateful
service, another database and another auth surface. The decisive objection is
narrower than the cost: **the first hand-edit of a generated page reintroduces
exactly the drift this tier exists to prevent.** Search here is a build-time index
shipped with the bundle, so it costs nothing at runtime.

Reconsider only if search on the static site proves inadequate — and the answer
then is a better index, not a stateful wiki.

## Known deviations

- **The generator is TypeScript, where PRINCIPLES §1 defaults a CLI to Go.**
  VitePress requires Node regardless, so a Go generator would mean two toolchains
  for one artefact. One `package.json` covers reading, emitting and rendering.
- **It targets Node, not Bun**, which PRINCIPLES §2 prefers for TypeScript. Bun is
  not on the runner's bare system PATH; Node is, and the build container pins it.
- **VitePress over MkDocs Material.** MkDocs is the obvious pick from outside and
  is Python, which PRINCIPLES §1 pushes back on. VitePress is TypeScript and
  Vue-flavoured, matching the estate frontend default.
