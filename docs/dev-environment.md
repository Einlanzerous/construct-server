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
4. **No dev router on the public entrypoint.** Dev routers exist only on
   `internal`. Traefik runs no Docker provider, so a dev service cannot expose
   itself with a label even by accident; routing is the committed allowlist in
   `config/traefik/dynamic/routers.yml`.

The single crossing point is Traefik, which joins `construct_dev_net` as a second
network attachment so it can route the dev hostnames. It bridges routing and
nothing else.

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

## Running it

```sh
# One-time, needs root because /opt is root-owned:
sudo install -d -o "$(id -un)" -g "$(id -gn)" /opt/construct-server-dev

make dev-bootstrap          # create the network, sync stack files to the dev root
#   put the dev .env at /opt/construct-server-dev/.env
make dev-up                 # postgres first, then init the databases, then the rest
make dev-ps
make dev-logs svc=purser-dev
make dev-recreate svc=switchyard-dev
make dev-down
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

**The dev tunnel hostnames.** The Traefik routers for
`<svc>-dev.zerogravity.industries` are committed and on the `internal` entrypoint,
but they are inert: `cloudflared` here runs a dashboard-managed token tunnel
(`tunnel --no-autoupdate run`, no config file), so hostname→origin ingress and the
Access applications live in the Cloudflare Zero Trust dashboard, not in this repo.

To activate, in the dashboard:

1. Add a public hostname per service on the tunnel, pointing at
   `http://traefik:9080` — the same origin the prod internal routers use.
2. Add an Access application for each, restricted to whoever should reach dev.
3. Set `DEV_*_PUBLIC_URL` in `DEV_ENV_FILE` to the new hostnames.

Until then dev is reached on its loopback ports, which is why they exist.

**`lyceum-dev-pg`.** A hand-run stray (`docker run`, no compose project, host port
55433) predating this work. It was left alone deliberately: it holds a real
`lyceum_dev` database, 11 tables and 8 MB. `lyceum-dev` in this project supersedes
it, but migrating or discarding that data is a decision for whoever created it.
