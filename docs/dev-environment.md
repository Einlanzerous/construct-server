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

Lyceum and Purser are here because Purser is the service that calls everything
else: Purser → Switchyard `/v1`, Purser → Lyceum `/admin`, Purser → Argosy
provisioning. That is the coupling SERV-81's contract tests target, and it cannot
be tested with only half the triangle present.

## Isolation — what makes dev unable to touch prod

Four properties, each asserted by `make dev-verify-isolation` rather than assumed:

1. **Dev is on its own network.** Dev containers attach to `construct_dev_net`
   only. They cannot resolve, let alone reach, any prod service — verified:
   `getent hosts switchyard` from `purser-dev` returns NXDOMAIN.
2. **Dev has its own Postgres.** Not extra databases in the shared server. A dev
   migration cannot run against a prod database because there is no route and no
   credential. Prod cannot reach `postgres-dev` either.
3. **Dev ports are loopback-bound.** Reachable from this host, refused from the
   LAN — verified against the host's own LAN address.
4. **Nothing from outside the dev project is attached to `construct_dev_net`.**
   There is no bridge at all, which is what makes property 1 true rather than
   merely intended — and this is checked from the *network's* side, by asking who
   is attached to it, because the regression worth catching is a **prod**
   container reaching into dev. A dev-side check cannot see that: the offending
   container is not in the dev project, so it falls outside the filter.

That last one was not the original design, and the reason it changed is worth
knowing before anyone re-adds the bridge.

An earlier revision attached prod's Traefik to `construct_dev_net` as a second
network so it could route `<svc>-dev.` hostnames. Review caught that this hands
dev an **unauthenticated route into prod's HTTP tier**. Traefik's `internal`
entrypoint used to listen on every interface it has with no source restriction —
only header stripping — and the prod `switchyard` and `lyceum` routers sit on it with
no auth middleware, because the Cloudflare Access JWT validation their comments promise
is still unimplemented (**SERV-106**). Access is enforced at *Cloudflare's* edge, so a
request arriving at `:9080` from inside Docker was authenticated by nothing:

```
$ docker exec crowdsec wget -S -O /dev/null \
    --header 'Host: switchyard.zerogravity.industries' http://traefik:9080/
  HTTP/1.1 200 OK
```

**SERV-107 closed the reachability half**: `internal` now binds one address on
`construct_edge_net`, which only cloudflared shares, so the command above no longer
connects from `construct_net`. The demo is kept because the *reason* is unchanged — the
routers still have no auth middleware, so the protection is now topology rather than
authentication.

That distinction is the whole point here: attaching Traefik to the dev network would
make the bound address reachable **from the dev network**, which is precisely what the
bind stopped. So the address restriction does not make routing dev hostnames safe.
SERV-106 (origin-side JWT validation) is what would.

Every dev container runs `:latest` — the untested code this project exists to
exercise, and now pulled hourly by `deploy-dev.yml` rather than whenever someone
remembered — so that route is exactly the wrong one to open. Note the database
isolation was never affected: neither Postgres is behind Traefik.

Dev is therefore reached on loopback, and giving it a real edge is **SERV-93**,
which has to answer the auth question rather than route around it.

## Secrets

Dev reads `/opt/construct-server-dev/.env`, materialised from **`DEV_ENV_FILE`** on
the `home-server-dev` GitHub Environment — the same arrangement as `PROD_ENV_FILE`
on `home-server`.

```
gh secret set DEV_ENV_FILE --env home-server-dev < your-dev.env
```

Start from `.env.dev.example`, which has the same key names as `.env.example` and
different values. **Never copy the prod `.env`.** Purser provisions real accounts
across four services; a dev Purser holding prod credentials does not fail safely,
it succeeds against production.

This is an interim arrangement. **SGNT-24** gives Signet an environment dimension
so dev and prod values live in one vault project, and **SGNT-20** teaches it to
push a rendered file to a GitHub Environment secret. Between them the vault takes
ownership of `DEV_ENV_FILE` without the stack changing how it reads anything —
which is why the interim deliberately has the same shape as the end state.

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

**Why a schedule, given the design says dispatch.** The service repos already dispatch —
but from `release.yml`, gated on release-please cutting a version, so `image-updated`
fires on a *release*. `latest` is pushed by `publish.yml` on every push to `main` and
announced to nobody. A dispatch-only workflow would have left dev moving on releases while
looking like it had fixed the staleness. SERV-108 adds the per-merge dispatch in each
service repo; until then the cron is what makes the criterion true.

**What actually moves dev.** A floating tag is not a floating container. The image string
in the compose file never changes, so compose sees no drift and `up -d` alone is a no-op
however far `main` has moved. Dev advances only when something **pulls** — which is why the
workflow pulls before it ups, and why `make dev-up` on its own will not refresh anything.

The workflow's last three steps are its acceptance criteria, asserted rather than assumed:
`make dev-health-check` (nothing crashed), `make dev-verify-isolation` (nothing joined
`construct_net`), and `make dev-versions` into the run summary, so *what dev is running* is
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
make dev-health-check       # fail if anything crashed
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

`make dev-up` is deliberately three steps rather than one `docker compose up -d`.
`depends_on: service_healthy` waits for Postgres to accept connections, which says
nothing about whether the per-service *databases* exist — those are created by
`db/init-db.sh` afterwards. A single `up -d` against a cold dev root starts every
service with no database to connect to; measured at **10 restarts each** before the
ordering was fixed. Cold start is now clean at zero restarts.

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

## Not done yet

**Dev has no edge — SERV-93.** No `<svc>-dev.` hostnames, and no Traefik routers
for them; the ones drafted here were removed rather than left committed, because
without a network path they could not work and dead routing config is worse than
none.

Two things have to be decided together there, which is why it is its own ticket:

- **Auth.** Whatever routes dev must not reopen the hole above — which is now
  closed from both directions: the `internal` entrypoint binds one address that
  only cloudflared shares (SERV-107), and every router on it validates the Access
  JWT at the origin (SERV-106). A dev hostname on the prod Traefik would be
  *refused*, because a host with no entry in `CF_ACCESS_AUD_MAP` fails closed. So
  the remaining decision is not "how do we avoid the hole" but "does dev get its
  own Access applications and AUDs on the prod Traefik, or its own Traefik".
- **The tunnel.** `cloudflared` runs a dashboard-managed token tunnel
  (`tunnel --no-autoupdate run`, no config file), so hostname→origin ingress and
  the Access applications live in the Zero Trust dashboard, not in this repo. A
  dev edge either shares that tunnel or gets its own.

Until then dev is reached on its loopback ports, which is why they exist.

**`lyceum-dev-pg`.** A hand-run stray (`docker run`, no compose project, host port
55433) predating this work. It was left alone deliberately: it holds a real
`lyceum_dev` database, 11 tables and 8 MB. `lyceum-dev` in this project supersedes
it, but migrating or discarding that data is a decision for whoever created it.
