# Dev environment

The `construct-server-dev` compose project (SERV-77). A second, isolated copy of
the services with real cross-service coupling, so a change can be exercised
somewhere before it reaches prod — the "somewhere to promote *from*" that the rest
of `docs/delivery-pipeline.md` assumes exists.

## What runs

| Service | Container | Loopback port | Why it is in the slice |
|---|---|---|---|
| Postgres | `postgres-dev` | 55432 | Dev's own database server |
| Switchyard | `switchyard-dev` + `switchyard-frontend-dev` | 14002 | Actively dev-tested |
| Argosy | `argosy-dev` | 18096 | Actively dev-tested |
| Lyceum | `lyceum-dev` | 14005 | Completes the Purser triangle |
| Purser | `purser-dev` | 14006 | Calls all three — the contract under test |
| Traefik | `traefik-dev` | — | Dev's own edge (SERV-93), `edge` profile |
| Access guard | `cf-access-guard-dev` | — | Origin-side Access JWT validation, `edge` profile |
| Tunnel | `cloudflared-dev` | — | Dev's own Cloudflare tunnel, `edge` profile |

Lyceum and Purser are here because Purser is the service that calls everything
else: Purser → Switchyard `/v1`, Purser → Lyceum `/admin`, Purser → Argosy
provisioning. That is the coupling SERV-81's contract tests target, and it cannot
be tested with only half the triangle present.

## Isolation — what makes dev unable to touch prod

Five properties, each asserted by `make dev-verify-isolation` rather than assumed:

1. **Dev is on its own networks.** Dev containers attach to `construct_dev_net` and
   `construct_dev_edge_net` only — never `construct_net`, never `construct_edge_net`.
2. **Dev has its own Postgres.** Not extra databases in the shared server. A dev
   migration cannot run against a prod database because there is no route and no
   credential. Prod cannot reach `postgres-dev` either.
3. **Dev ports are loopback-bound.** Reachable from this host, refused from the
   LAN — verified against the host's own LAN address.
4. **Nothing from outside the dev project is attached to either dev network.**
   There is no bridge at all, which is what makes property 1 true rather than
   merely intended — and this is checked from the *network's* side, by asking who
   is attached to it, because the regression worth catching is a **prod**
   container reaching into dev. A dev-side check cannot see that: the offending
   container is not in the dev project, so it falls outside the filter.
5. **Prod's edge does not answer from the dev network.** Properties 1 and 4 are
   about *attachment*; this one runs the original exploit — a spoofed `Host` at
   prod's internal entrypoint — from a throwaway container on `construct_dev_net`
   and asserts nothing replies. Attachment is a proxy for reachability, and a proxy
   is what let SERV-25's deferral stay invisible for six weeks.

   It carries a **positive control**: the same tool, from the same container, must
   first reach a dev backend. A probe that cannot connect to anything reports
   "unreachable" for every target and looks exactly like perfect isolation, so
   without the control the check could pass by being broken. When the control fails,
   the negatives are reported as untested rather than as a pass.

### Why the history here matters

An earlier revision of SERV-77 attached prod's Traefik to `construct_dev_net` as a
second network so it could route `<svc>-dev.` hostnames. Review caught that this
handed dev an **unauthenticated route into prod's HTTP tier**: Traefik's `internal`
entrypoint listened on every interface with no source restriction, and the prod
routers on it carried no auth middleware, so a request arriving at `:9080` from
inside Docker was authenticated by nothing. Demonstrated, not theorised — a spoofed
`Host` returned `HTTP/1.1 200 OK` from prod Switchyard.

**Both halves of that are closed.** SERV-107 bound `internal` to a single address on
`construct_edge_net`, which only `cloudflared` shares; SERV-106 put origin-side Access
JWT validation on every router there, so a request that does connect is refused unless
it carries a valid token for that host's own AUD. The reproduction no longer
reproduces — it fails to connect, and would 403 even if it did.

So by the time SERV-93 was decided, sharing prod's Traefik was **cheap and no longer
dangerous**, and it was still rejected. The reason is property 4. Any shared-Traefik
design needs a carve-out in it — "nothing crosses" becomes "nothing crosses except the
one container we decided is fine" — and that is the exact sentence which preceded the
original regression. Dev gets its own edge instead, so every assertion above survives
unweakened. If a future change adds an exception to property 4, that is the rejected
design arriving by the back door.

## Secrets — Signet owns `DEV_ENV_FILE`

Dev reads `/opt/construct-server-dev/.env`, rendered by `deploy-dev.yml` from
**`DEV_ENV_FILE`** on the `home-server-dev` GitHub Environment. That secret is not
hand-written: **Signet renders it**, from the `construct-server-dev` vault project,
the same way it already renders `PROD_ENV_FILE` for `home-server`.

```
             Signet vault — project construct-server-dev
                      (the source of record)
                              │
                 signet sync  │
              ┌───────────────┴───────────────┐
              ▼                               ▼
        creds/dev.env            home-server-dev · DEV_ENV_FILE
       (file target, the             (gh-render target)
        local readable copy)                  │
                                              │  deploy-dev.yml, via render-env.sh
                                              ▼  merged with tracked dev-versions.env
                                  /opt/construct-server-dev/.env
                                     (what compose actually reads)
```

Both boxes below the vault are **outputs**. Editing either one directly is editing a
render, and the next `signet sync` overwrites it.

To change a dev credential: change it in the vault, then `signet sync`.

```sh
signet set --project construct-server-dev --name SOME_TOKEN
signet sync
```

**Do not `gh secret set DEV_ENV_FILE` by hand.** It appears to work and is reverted by
the next `signet sync`, which is the worst kind of wrong — a value that is live until
something unrelated runs. The same now applies to `PROD_ENV_FILE`.

Start from `.env.dev.example`, which has the same key names as `.env.example` and
different values. **Never copy the prod `.env`.** Purser provisions real accounts
across four services; a dev Purser holding prod credentials does not fail safely,
it succeeds against production.

### Establishing it, and the two traps

`import` is the **one-time bootstrap**, and it runs against the arrow above: it reads
`creds/dev.env` into the vault. Afterwards the direction reverses and that file is a
render target — so this is the only moment at which editing it is how you change a
value, rather than a thing the next sync undoes.

```sh
# 1. Import the dev credentials. Creates the project's secrets AND registers the file
#    target — which is the thing --seed-from reads in step 2.
signet import --project construct-server-dev creds/dev.env

# 2. The render target, key set seeded from that file target.
signet target add --project construct-server-dev --render-as-secret \
  --gh-repo Einlanzerous/construct-server --gh-secret DEV_ENV_FILE \
  --gh-environment home-server-dev --seed-from creds/dev.env

# 3. Push.
signet sync
```

**Seed from `creds/dev.env`, never from `/opt/construct-server-dev/.env`.** Two
reasons, and both have already bitten the prod project:

1. **The deploy root has a writer.** `deploy-dev.yml` regenerates that file on every
   run. A Signet file target there means two writers on one file, and drift becomes a
   race rather than a state — which is why `file:/opt/construct-server/.env` read
   `changed` on the prod project for the week and a half before SERV-94 detached it.
2. **It carries the tag pins.** The deployed `.env` is `creds/dev.env` *plus* the four
   `DEV_*_TAG` values `render-env.sh` appends from tracked `dev-versions.env`. Those
   belong to git (SERV-96), and importing them makes the vault a second apparent source
   for a value it does not own. The prod project held all ten `*_TAG` values until
   SERV-94 dropped them from its render — that was the bug, not a pattern to copy.

`signet set` alone does **not** add a key to a target — it mints the value and leaves it
reaching nothing, which is how `construct-server/DEV_SWITCHYARD_BOOTSTRAP_TOKEN` came to
sit in the vault with no destination. Either add the key to `creds/dev.env` before
importing, or attach it afterwards with `signet target add-key`.

This was the dev half of **SERV-94**. The prod half is now done too, and landed one
asymmetry worth knowing before you reason from dev to prod: **`construct-server` has no
file target at all.** Dev keeps `creds/dev.env` because it is the readable credential
source and nothing else writes it; prod's credentials were imported once years of
deploys ago and the vault has been the source ever since, so there is no local file it
should be writing. Signet owns `PROD_ENV_FILE` and stops there.

The consequence is that `import` cannot widen prod's key set — what `import` widens is a
*file* target's, and prod has none. A new prod credential is two commands:

```sh
signet set --project construct-server --name SOME_TOKEN
signet target add-key --project construct-server --gh-secret PROD_ENV_FILE --name SOME_TOKEN
```

`make env-ownership-check` asserts both halves of the rule for either tier — see the
invariant in `CLAUDE.md`.

## How code gets into dev — `deploy-dev.yml` (SERV-97)

Dev is a pipeline stage, not a sandbox someone starts by hand. `deploy-dev.yml` renders
the dev `.env`, pulls, and runs the same `make dev-*` targets a human would:

| Trigger | When |
|---|---|
| `schedule` | hourly — the backstop that makes "dev tracks HEAD" true |
| `repository_dispatch: deploy-dev` | what a service repo should send on every merge (**SERV-108**) |
| `repository_dispatch: image-updated` | what service repos send today, on release |
| `push` to `main` | touching `docker-compose.dev.yml`, `dev-versions.env`, `db/`, `scripts/` |
| `workflow_dispatch` | by hand |

**Why a schedule, given the design says dispatch.** Switchyard dispatches — but from
`release.yml`, gated on release-please cutting a version, so `image-updated` fires on a
*release*; argosy, lyceum and purser dispatch nothing. A dispatch-only workflow would have
left dev moving on releases while looking like it had fixed the staleness. SERV-108 adds
the per-merge dispatch where one helps.

**The cron is not going away, and only two of the four repos can be made prompt.** A
dispatch only helps if a merge produced an image dev can move to, and `dev-versions.env`
pins `latest` for all four. `argosy` and `purser` publish `:latest` from main's tip, so a
dispatch moves them. **`lyceum` publishes `:latest` only from a release** (LYCM-121, and
deliberate — a main build has no semver, so its label could never match the ledger's
strict equality), and **`switchyard` builds no image on a merge at all** — its
`build-and-push` job is gated on `release_created`. For those two the cron is the only
thing that moves them, and what it moves them to is the last release. So **dev tracks
releases for lyceum and switchyard, and main for argosy and purser.** Nobody chose that
split; it is an open decision on SERV-108. Until it is resolved, do not read a green
`deploy-dev` run as "dev is running what just merged".

**What actually moves dev.** A floating tag is not a floating container. The image string
in the compose file never changes, so compose sees no drift and `up -d` alone is a no-op
however far `main` has moved. Dev advances only when something **pulls** — which is why the
workflow pulls before it ups, and why `make dev-up` on its own will not refresh anything.

The workflow's closing steps are its acceptance criteria, asserted rather than assumed:
`make dev-health-check` (nothing crashed), `make dev-verify-isolation` (nothing joined a
prod network, and prod does not answer from the dev one), `make dev-edge-auth-check` (the
dev origin refuses a request with no valid Access assertion — skipped when the edge is not
deployed), and `make dev-versions` into the run summary, so *what dev is running* is
answerable from the run instead of by shelling in.

Dev needs no registry credential: all four first-party dev images are public GHCR packages,
verified with an anonymous `docker manifest inspect`. That is what keeps `DEV_ENV_FILE`
free of a GitHub PAT. If one is ever made private the pull fails with an auth error, which
is the right way round.

## Versions — `dev-versions.env`

Dev's own pin file, and every value in it is `latest` on purpose. It is **not** shared with
prod's `versions.env`, and every variable carries a `DEV_` prefix:

```
DEV_ARGOSY_TAG=latest
DEV_LYCEUM_TAG=latest
DEV_PURSER_TAG=latest
DEV_SWITCHYARD_TAG=latest
```

Sharing prod's variable names would work right up until prod's `.env` ended up at the dev
root, at which point dev would silently run prod's pinned versions and look fine doing it.
Distinct names make that inert — with no `DEV_*_TAG` set, the `:-latest` fallback applies
and dev floats, which is dev's intended state anyway. (Copying the prod `.env` into dev
remains forbidden for much larger reasons; this is a second line, not the first.)

What the file buys, given it changes nothing by default: a **temporary** dev pin — "hold
dev at switchyard 4.7 while I reproduce this" — becomes a reviewable one-line diff that the
next deploy re-applies, rather than an edit to the deployed `.env`, which `render-env.sh`
regenerates and discards without warning.

`postgres-dev` is pinned by digest to the **same image prod runs**. Under the old floating
`16-alpine` it was recreated whenever upstream published and a pull happened to run, and a
postgres recreate moves its address on the network — which Node/Bun's `pg-pool` caches and
retries forever (SERV-102). `switchyard-dev` is the same runtime, and dev pulls far more
often than prod ever did. Bump both together; a dev postgres ahead of prod's is a rehearsal
of something that is not going to ship.

## Running it

```sh
# One-time, needs root because /opt is root-owned. `ansible-playbook ansible/site.yml`
# does this for you; this is the one-off equivalent:
sudo install -d -o "$(id -un)" -g "$(id -gn)" /opt/construct-server-dev

make dev-bootstrap          # create the network, sync stack files to the dev root
#   put the dev .env at /opt/construct-server-dev/.env
make dev-up                 # postgres first, then init the databases, then the rest
make dev-ps
make dev-versions           # what dev is running, by the commit each image was built from
make dev-assert-tokens      # will switchyard accept the tokens this .env renders? (SERV-118)
make dev-health-check       # fail if anything crashed
make dev-verify-isolation   # can dev reach prod? (probed, not inferred)
make dev-edge-status        # ON / HALF-ON / OFF, and why
make dev-edge-down          # take the edge down now (dev-up does it when the token goes)
make dev-edge-auth-check    # does the dev origin refuse an unauthenticated request? (SERV-93)
make dev-logs svc=purser-dev
make dev-recreate svc=switchyard-dev
make dev-down
```

A hand-made `.env` needs no `DEV_*_TAG` entries — the compose fallback covers it. To apply
the tracked pins the way the workflow does:

```sh
./scripts/render-env.sh /opt/construct-server-dev/.env dev-versions.env \
                        /opt/construct-server-dev/.env
```

`make dev-up` is deliberately several steps rather than one `docker compose up -d`.
`depends_on: service_healthy` waits for Postgres to accept connections, which says
nothing about whether the per-service *databases* exist — those are created by
`db/init-db.sh` afterwards. A single `up -d` against a cold dev root starts every
service with no database to connect to; measured at **10 restarts each** before the
ordering was fixed. Cold start is now clean at zero restarts.

When the `edge` profile is on, `dev-up` also **builds** `cf-access-guard-dev` before
starting anything. That is not decoration: `up -d` builds only when the image is
*missing*, so without an explicit build a source edit to the guard would be ignored
for as long as a stale image existed — the worst possible silent no-op for the
container that decides whether dev requests are authenticated. It is a layer-cache hit
when nothing changed.

`db/init-db.sh` is used **unmodified**. Its roles are created inside `postgres-dev`,
so `switchyard_user` there is a different role from `switchyard_user` in prod. The
prod-only roles it also tries to create are skipped loudly by its empty-password
guard, which is the correct outcome — they are not part of the dev slice.

## Keeping dev honest: `make dev-parity`

`docker-compose.dev.yml` is written out explicitly rather than using compose
`extends:`. That was the first choice and it does not work here: verified against
compose v5.0.0, `extends` treats `networks` as a **union** and inherits
`depends_on`, so a dev service extending a prod one drags in `construct_net` and a
dependency on the prod Postgres — exactly the isolation this exists to create.

The cost is drift: add an env key to a prod service and its dev counterpart
silently does without it. `make dev-parity` reports that, and it earned its place
on its first run by catching a real bug — prod Purser sets both
`PURSER_*_BASE_URL` (the internal API endpoint) and `PURSER_*_URL` (the user-facing
link), and the dev file had only the first set.

Keys dev deliberately omits are listed with a reason in
`scripts/check-dev-parity.sh`, so an intentional gap reads differently from drift.

## The dev edge — SERV-93

Dev gets its own edge, mirroring prod's shape one tier down and sharing nothing
with it:

```
                    Cloudflare Access (dev applications, per-host AUDs)
                                     │
                          dev Cloudflare tunnel
                                     │
   construct_dev_edge_net  ┌─────────┴──────────┐
   (172.31.241.0/24)       │  cloudflared-dev   │
                           └─────────┬──────────┘
                                     │  http://traefik-dev:9080
                           ┌─────────┴──────────┐     forwardAuth
                           │    traefik-dev     ├──────────────────► cf-access-guard-dev
                           │ binds 172.31.241.10│                    (verifies the JWT
                           └─────────┬──────────┘                     against this host's AUD)
                                     │
   construct_dev_net                 │
                        switchyard-frontend-dev : lyceum-dev
```

| Piece | What it is |
|---|---|
| `traefik-dev` | One entrypoint, `internal`, bound to **one address** on `construct_dev_edge_net`. No `public` entrypoint, no ACME, no CrowdSec, no dashboard |
| `cf-access-guard-dev` | The same source as prod's guard, built again for this project. Its own `CF_ACCESS_AUD_MAP` |
| `cloudflared-dev` | A **second** tunnel, not a second connector on prod's |
| `construct_dev_edge_net` | `172.31.241.0/24`, compose-managed. Only those two containers are on it |

**Hostnames.** `switchyard-dev.zerogravity.industries` and
`lyceum-dev.zerogravity.industries`. Argosy and Purser deliberately have none —
video does not go through the tunnel (the reason prod Argosy gets a direct WAN path
instead), and Purser is called by peers rather than reached by a person. They stay on
their loopback ports.

**Everything the design rests on, stated once:**

- The `internal` bind is **one address**, not `:9080`. `:9080` means "every interface",
  which on a shared network means every neighbour — the bug SERV-107 fixed in prod.
  `config/traefik-dev/traefik.yml` and the `ipv4_address` in `docker-compose.dev.yml`
  must agree; `make dev-edge-auth-check` asserts they do.
- **Per-host AUDs, never one shared audience.** Every application on the team domain
  is signed by the same key, so a single static audience would let a dev token open
  prod Switchyard. A host missing from `CF_ACCESS_AUD_MAP` is *refused*, so an
  unmapped router is unreachable (loud) rather than unauthenticated (silent).
- **No exemptions.** Prod has exactly one — the GitHub webhook, which Access cannot
  authenticate and which is HMAC-gated instead. Dev holds no webhook secret and must
  never receive a real webhook, so it has none, and `check-edge-auth.sh --dev` carries
  an empty allowlist to keep it that way.
- **The loopback ports keep working.** A dev loop never depends on the edge being up.

### Turning it on

The three edge services carry `profiles: [edge]`, and the switch is
`DEV_CLOUDFLARE_TUNNEL_TOKEN` in `DEV_ENV_FILE`: the Makefile enables the profile
exactly when that variable is non-empty. That is deliberate rather than a flag
someone has to remember — half of this ticket lives in the Cloudflare Zero Trust
dashboard and no file in this repo can create it, and an empty `TUNNEL_TOKEN` does
not disable `cloudflared`, it crash-loops it. Until the token exists, dev runs on
loopback exactly as before.

**Turning it off is not symmetrical, and the Makefile has to do the work.**
`docker compose up -d` with a profile *off* does not stop the containers that profile
created — measured on compose v5.0.0; they stay `Up` and are not treated as orphans.
So removing the token stops the edge being *started* without stopping it *running*:
the tunnel stays connected, the hostnames stay served, and every check keyed on the
token calls it "not deployed". That is the worst of the three states, because the auth
assertion goes quiet over a live origin.

Two things close it. `make dev-up` **reconciles** — token gone, containers up, it takes
them down and says why (`make dev-edge-down` does it immediately). And
`make dev-edge-auth-check` keys off what is **running**, not off the token, so anything
serving gets probed regardless of what the environment claims. `make dev-edge-status`
names all four states, including `HALF-ON`.

**Where the token lives.** In Signet, as `construct-server-dev/DEV_CLOUDFLARE_TUNNEL_TOKEN`
— the same place prod keeps its own `CLOUDFLARE_TUNNEL_TOKEN`. `DEV_ENV_FILE` is how it
*reaches* the stack, and the vault is what fills `DEV_ENV_FILE`. See *Secrets* above.

**The dashboard half — written down here rather than remembered.** `cloudflared` runs
a dashboard-managed *token* tunnel (`tunnel --no-autoupdate run`, no config file), so
ingress and the Access applications live in the Zero Trust dashboard, outside this
repo.

1. **Create the dev tunnel.** Zero Trust → Networks → Tunnels → *Create a tunnel* →
   Cloudflared. Name it something unmistakably dev (`construct-dev`). Copy the token.
   **A second tunnel, not a second connector on the prod one** — two connectors
   sharing one token lets Cloudflare route a prod hostname to whichever it likes, and
   the dev one cannot serve it.
2. **Add its public hostnames**, both pointing at the same origin:

   | Hostname | Service |
   |---|---|
   | `switchyard-dev.zerogravity.industries` | `http://traefik-dev:9080` |
   | `lyceum-dev.zerogravity.industries` | `http://traefik-dev:9080` |

   HTTP, not HTTPS, and the container name — not a host port, which does not exist.
3. **Create one Access application per hostname**, *before* mapping anything. Same
   team domain and policy shape as the prod applications. Copy each application's
   **AUD tag**.
4. **Record the AUDs** in `CF_ACCESS_AUD_MAP` on `cf-access-guard-dev` in
   `docker-compose.dev.yml` — tracked in git, because an AUD is a public application
   identifier rather than a credential, and an Access application change should be a
   reviewable diff:

   ```
   - CF_ACCESS_AUD_MAP=switchyard-dev.zerogravity.industries=<aud>,lyceum-dev.zerogravity.industries=<aud>
   ```

   Leave it empty and the guard refuses to start, saying so in as many words. That is
   the intended direction: a permissive default would serve dev to anything that
   reached the entrypoint.
5. **Put the tunnel token in `DEV_ENV_FILE`** as `DEV_CLOUDFLARE_TUNNEL_TOKEN`, and
   point the two public URLs at the new hostnames:

   ```
   DEV_CLOUDFLARE_TUNNEL_TOKEN=<token>
   DEV_SWITCHYARD_PUBLIC_URL=https://switchyard-dev.zerogravity.industries
   DEV_LYCEUM_PUBLIC_URL=https://lyceum-dev.zerogravity.industries
   ```

   Through the vault, not `gh secret set` — see *Secrets* above:

   ```sh
   $EDITOR creds/dev.env          # add all three
   signet import --project construct-server-dev creds/dev.env
   signet sync
   ```
6. **Deploy and verify.** `deploy-dev.yml` picks the profile up on its next run, or
   run it by hand:

   ```sh
   make dev-up                 # prints whether the edge is ON or OFF
   make dev-edge-auth-check    # config + a live spoofed-Host probe against traefik-dev
   make dev-verify-isolation   # still true with the edge up?
   ```

   Then verify **through the public path**. Container-to-container success proves
   nothing about Access: the only real check is a browser at
   `https://switchyard-dev.zerogravity.industries`, which must bounce to the Access
   login and land on dev Switchyard afterwards.

**Adding a dev hostname later takes four steps, not one:** a router in
`config/traefik-dev/dynamic/routers.yml`, an Access application, its AUD in
`CF_ACCESS_AUD_MAP`, and the ingress rule on the dev tunnel.
`make dev-edge-auth-check config_only=1` names whichever half is missing.

**Dev keeps token-paste login.** The dev services still carry no `CF_ACCESS_*` of
their own, so in-app SSO stays off — dev is reached *through* Access at the edge, not
by trusting an Access JWT internally. Only `cf-access-guard-dev` holds the team domain
and the AUDs.

## Not done yet

**`lyceum-dev-pg`.** A hand-run stray (`docker run`, no compose project, host port
55433) predating this work. It was left alone deliberately: it holds a real
`lyceum_dev` database, 11 tables and 8 MB. `lyceum-dev` in this project supersedes
it, but migrating or discarding that data is a decision for whoever created it.
