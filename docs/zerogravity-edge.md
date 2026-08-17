# Zero Gravity Industries — Hybrid Edge

Public edge for the Imperial Construct stack under `zerogravity.industries`.
Tracked in Switchyard under the **SERV** project (epics SERV-9 … SERV-13).

**Live today:** the tunneled path — `cloudflared` → Traefik `internal` → Switchyard,
gated by Cloudflare Access. **Authored but not deployed:** Authentik (SERV-19, gated
behind the `identity` compose profile). **Not wired yet:** the direct/Argosy path
(CGNAT-blocked, Phase 3). See *Status* below.

## Architecture (plan of record)

Two paths, one identity source:

- **Tunneled path** — Cloudflare Tunnel (`cloudflared`) + Cloudflare Access in front
  of Switchyard, Lyceum, and (pending SERV-18) Eido. No open ports.
- **Direct path** — Argosy (media/video) cannot traverse the tunnel (video ToS +
  performance), so it gets a DNS-only (grey-cloud) record → WAN IP → open 443 →
  Traefik. **Blocked by CGNAT** (see below).
- **Identity** — self-hosted **Authentik**, source of truth.

### The non-negotiable constraint

The open WAN 443 must never provide a bypass around Cloudflare Access. Traefik runs
**split entrypoints**:

| Entrypoint | Container port | Published? | Serves |
|-----------|----------------|-----------|--------|
| `public`   | `:8443` | yes (host `443:8443`) | direct routers only — Argosy + Lyceum's direct path (SERV-60) — + a deny-all catch-all |
| `internal` | `172.31.240.10:9080` (HTTP) | **no** (bound to construct_edge_net only) | tunneled apps; cloudflared origin. Every router validates the Access JWT (SERV-106) |
| `traefik`  | `:8080` | **no** | dashboard/API |

The `internal` entrypoint is plain HTTP: Cloudflare terminates TLS at the edge and
the tunnel encrypts the wire, so the cloudflared→Traefik leg inside `construct_net`
needs no origin cert. Only the public/Argosy path uses the Let's Encrypt cert.

Because the tunneled routers exist *only* on `internal`, and `internal` is never
published to the host, a request arriving on the open WAN port physically cannot
reach a tunneled hostname. The catch-all (403) is defense-in-depth on top of that.

On **both** entrypoints, spoofable identity headers (`X-Authentik-*`, `Remote-*`,
`X-Forwarded-User/Groups/Email/...`) are stripped on ingress. On `public` only,
`Cf-Access-*` headers are also stripped (Access isn't in front of Argosy, so a
client must not be able to forge them). On `internal`, `Cf-Access-Jwt-Assertion`
is preserved and cryptographically validated at the origin by `cf-access-guard`
(SERV-106) — every router there carries the `cf-access-jwt` forwardAuth
middleware, so reaching the entrypoint is not sufficient to be served.

## Status

**Done / live:**
- **Traefik (SERV-20)** on `construct_net` + `construct_edge_net`; **cloudflared (SERV-23)**
  on `construct_edge_net` only, so the `internal` entrypoint binds one address that only
  the tunnel can reach (SERV-107). Host
  connector retired (single container connector).
- **Switchyard tunneled + Access (SERV-24/25):** `switchyard.zerogravity.industries`
  → tunnel → `traefik:9080` → switchyard-frontend, gated by **Cloudflare Access**
  (team domain `<team>.cloudflareaccess.com`, Allow-by-email, built-in
  one-time-PIN IdP per SERV-17). Verified: unauthenticated → `302` to the Access login.

**Blocked / pending:**
- **CGNAT (SERV-15):** carrier-grade NAT — the router's WAN IP is a `100.64.0.0/10`
  (RFC 6598) CGNAT address, distinct from the public IP the internet sees. A router 443
  port-forward cannot deliver traffic, so the `public` entrypoint has no host bind (also,
  host 443 is held by Tailscale Funnel). Needs a Phase 3 relay (Tailscale Funnel / VPS +
  WireGuard). See ticket SERV-15 for the measured values.
- **Certs (SERV-21):** the DNS-01 resolver is configured but needs `CF_DNS_API_TOKEN`;
  only the direct/Argosy path needs it (tunnel apps use Cloudflare's edge cert).
- **Authentik (SERV-19):** authored, gated behind the `identity` profile — see bring-up
  below. Not started by a plain `docker compose up -d`.
*(Origin JWT validation is no longer pending — see below.)*

**Origin JWT validation (SERV-106) — done.** SERV-25 shipped the Access policies and
deferred this half in a closing comment, where it stayed invisible for six weeks.
`cf-access-guard` (`services/cf-access-guard/`) is a Traefik `forwardAuth` target on
every `internal` router: it verifies the assertion against the team's published
signing keys and **the AUD registered for that specific host**, and 403s anything
else. Per-host is not incidental — all three apps are signed by the same team key,
so one static audience would let a wiki token open Switchyard.

The reason it stopped being optional: the deferral rested on "there is no non-edge
path to the origin", which was a claim about network topology, not authentication.
It reproduced in one command from any container on the shared network, and still
reproduces from the host, where an unpublished container port is routable anyway.
SERV-107 (binding `internal` to one address on `construct_edge_net`) and this are
complementary: the bind decides who can connect, the middleware decides who is
served. Assert both with `make edge-auth-check`, which `deploy.yml` runs as a
post-deploy gate.

## Files

| Path | Purpose |
|------|---------|
| `config/traefik/traefik.yml` | Static config: entrypoints, providers, ACME resolver |
| `config/traefik/dynamic/routers.yml` | Routers, services, header-strip + deny-all + `cf-access-jwt` middlewares |
| `services/cf-access-guard/` | Origin-side Access JWT validation (SERV-106); the only stack image built on the box |
| `scripts/check-edge-auth.sh` | Asserts the origin rejects a spoofed Host — config *and* a live probe |
| `docker-compose.yml` | `traefik`, `cf-access-guard`, `authentik-server`, `authentik-worker`, `authentik-redis` |
| `db/init-db.sh` | Provisions the `authentik` DB/user on the shared postgres |
| `.env.example` | New vars (`CF_DNS_API_TOKEN`, `AUTHENTIK_*`) |

## Bring-up runbook (do NOT run unattended — reviewed deploy)

Prereqs in `.env` (gitignored) first:

```bash
# Authentik secret key + a strong DB password
openssl rand -base64 60 | tr -d '\n'   # -> AUTHENTIK_SECRET_KEY
openssl rand -base64 30 | tr -d '\n'   # -> AUTHENTIK_DB_PASSWORD
# Set AUTHENTIK_BOOTSTRAP_PASSWORD too. CF_DNS_API_TOKEN once the token is minted.
```

### 1. Authentik (SERV-19)

```bash
# 0. postgres must carry AUTHENTIK_DB_PASSWORD in its env before init-db can create
#    the role. That env line is committed, but the RUNNING postgres predates it, so
#    recreate it once (brief blip for all DB-backed apps) to pick it up:
docker compose up -d postgres

# 1. Provision the authentik DB/user on the shared postgres (idempotent).
make db-init

# 2. Bring up identity. Authentik is gated behind the `identity` profile, so it is
#    NOT started by a plain `docker compose up -d` — you must opt in:
docker compose --profile identity up -d authentik-redis authentik-server authentik-worker
make drift-check svc=authentik-server

# First-boot admin: reach the UI via an SSH tunnel (port is localhost-bound).
#   ssh -L 9000:127.0.0.1:9000 <server>   then open http://localhost:9000/if/flow/initial-setup/
```

### 2. Traefik (SERV-20)

```bash
# Validate config parses before starting.
docker compose config -q

docker compose up -d traefik
docker logs traefik 2>&1 | grep -i -E 'error|acme|entrypoint' | head

# Once CF_DNS_API_TOKEN is set, confirm a cert is issued for *.zerogravity.industries
# (test against LE staging first — see the caServer note in traefik.yml).
```

### 3. Cloudflare Tunnel (SERV-23) — cutover from the host connector

The token tunnel may already be running as a **host** process/service. A host
connector can't reach Traefik's unpublished `internal` entrypoint, and running two
connectors on one token lets Cloudflare route to the one that can't serve. Retire the
host connector, then run it in-stack:

```bash
# 1. Stop the host connector(s). If installed as a service:
sudo cloudflared service uninstall     # or: sudo systemctl disable --now cloudflared
pgrep -a cloudflared                    # confirm none linger; kill any stray `tunnel run`

# 2. Bring the tunnel up in the stack (reuses CLOUDFLARE_TUNNEL_TOKEN from .env).
docker compose up -d cloudflared
docker logs cloudflared 2>&1 | grep -iE 'registered|connection|error' | head

# 3. In the Zero Trust dashboard (SERV-24), point each public hostname at the
#    in-network origin:  http://traefik:9080   (NOT https, NOT a host port)
#    Add the Access policy (SERV-25) BEFORE mapping — else the app is open.
```

**Adding a tunneled app now takes a fourth step.** Copy the new Access application's
AUD tag out of the Zero Trust dashboard and add `host=aud` to `CF_ACCESS_AUD_MAP` on
the `cf-access-guard` service, alongside the router in `dynamic/routers.yml` and its
`cf-access-jwt` middleware. Forgetting it does not open the app — the guard refuses a
host it has no audience for — so the failure is a 403 on a route that should work, not
a silent exposure. `make edge-auth-check config_only=1` names exactly which half is
missing.

### Verification (subset of SERV-30, run once the relay + tunnel exist)

- `curl --resolve switchyard.zerogravity.industries:443:<WAN_IP> https://switchyard.zerogravity.industries`
  must be refused on the public entrypoint (proves no tunnel bypass).
- A request with a forged `X-Authentik-Username` header must not be trusted (proves stripping).
- `./scripts/check-edge-auth.sh` — a spoofed `Host` against the internal entrypoint,
  **from the host**, must return 403 (SERV-106). Runs today, no relay required. The
  host angle is the one a container-side probe misses: an unpublished container port
  is still routable from the host on Linux, so "unreachable from `construct_net`" was
  never the same claim as "rejected".
