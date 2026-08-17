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

## Layout

```
wiki/
  package.json          # the whole toolchain: generator + renderer
  generate/
    index.ts            # entry point; wipes docs/ and writes the corpus
    fetch.ts            # fills .repo-docs/ from the GitHub API (or ~/projects)
    model.ts            # assembles the sources into one model
    sources/            # compose.ts, versions.ts, repos.ts — reading
    emit/               # one module per page family — writing
    lib/md.ts           # Markdown helpers
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

`wiki-build` runs in a `node:22-alpine` container. That is deliberate: it pins the
toolchain so a host node upgrade cannot change what gets built, and it means the
deploy runner needs only docker — which matters because that runner is a systemd
service with a bare system PATH and no login shell (the trap SERV-62 hit twice).

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
