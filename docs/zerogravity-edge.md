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
- **Remote MCP endpoint (SERV-99 / SERV-100):** `mcp.zerogravity.industries` → tunnel →
  `traefik:9080` → `switchyard-mcp`, gated by `cf-access-jwt` like every tunneled host.
  The origin half is in this repo; the Access application, its **Managed OAuth**, and the
  tunnel hostname are dashboard-only (SERV-100) and are what the AUD comes from. Until
  that AUD is real the container cannot boot and `check-edge-auth.sh` fails, so the two
  tickets interleave rather than running in the order their link implies — step 4 of the
  bring-up runbook below is the whole of it.
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

**One exemption: `switchyard-github-webhook`.** GitHub cannot authenticate to
Access, so Access has a Bypass policy on `/v1/external/github` and injects no
assertion — the request arrives with nothing to validate. Found the hard way: the
first push after enforcing returned 403 on that path, which would have stopped
external-ref updates and PR-merge auto-close (SERV-45) with no other symptom. The
exempt router is one host and one **exact** `Path()`; the endpoint is HMAC-gated by
`GITHUB_WEBHOOK_SECRET`, so it authenticates with something Access cannot express
rather than not at all. `check-edge-auth.sh` holds the allowlist, prints it on every
run, refuses a `PathPrefix()` as too broad to verify, and fails on any internal
router that is neither gated nor listed.

## The dev edge is a second, separate one (SERV-93)

Dev has its own Traefik, its own `cf-access-guard`, its own tunnel and its own Access
applications, in the `construct-server-dev` compose project — **not** a leg of this
Traefik. The alternative (attaching this Traefik to `construct_dev_net` so it could
route `<svc>-dev.` hostnames) was cheap and, after SERV-106/107, no longer dangerous;
it was rejected because it needs a carve-out in the "nothing crosses between dev and
prod" assertion, and that exception is what preceded the original SERV-77 regression.

Everything in this document is about the **prod** edge. The dev one mirrors it one
tier down — one address bound on `construct_dev_edge_net`, per-host AUDs, no
exemptions at all — and is documented in `docs/dev-environment.md`. The two share
`services/cf-access-guard/` (built twice, once per project) and
`scripts/check-edge-auth.sh` (`--dev` points it at the dev edge), and nothing else.

## Files

| Path | Purpose |
|------|---------|
| `config/traefik/traefik.yml` | Static config: entrypoints, providers, ACME resolver |
| `config/traefik/dynamic/routers.yml` | Routers, services, header-strip + deny-all + `cf-access-jwt` middlewares |
| `config/traefik-dev/` | The **dev** edge's static + dynamic config (SERV-93) |
| `services/cf-access-guard/` | Origin-side Access JWT validation (SERV-106); the only stack image built on the box, and built for both projects |
| `scripts/check-edge-auth.sh` | Asserts the origin rejects a spoofed Host — config *and* a live probe. `--dev` for the dev edge |
| `docker-compose.yml` | `traefik`, `cf-access-guard`, `cloudflared`, `switchyard-mcp`, `authentik-server`, `authentik-worker`, `authentik-redis` |
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

# 3. In the Zero Trust dashboard (SERV-24), point each tunnel route at the
#    in-network origin:  http://traefik:9080   (NOT https, NOT a host port)
#    Add the Access policy (SERV-25) BEFORE mapping — else the app is open.
#
#    NAMING: Cloudflare has renamed this list. Older dashboards (and older text
#    in this file) call these "public hostnames"; the current UI calls them
#    "published application routes". Same object — a tunnel ingress rule. It is
#    NOT the Access application, which is a separate object under Access >
#    Applications and is what carries the policy and the AUD. A tunneled app
#    needs BOTH, in that order.
```

**Adding a tunneled app now takes a fourth step.** Copy the new Access application's
AUD tag out of the Zero Trust dashboard and add `host=aud` to `CF_ACCESS_AUD_MAP` on
the `cf-access-guard` service, alongside the router in `dynamic/routers.yml` and its
`cf-access-jwt` middleware. Forgetting it does not open the app — the guard refuses a
host it has no audience for — so the failure is a 403 on a route that should work, not
a silent exposure. `make edge-auth-check config_only=1` names exactly which half is
missing.

### 4. The remote MCP endpoint (SERV-99 / SERV-100)

`mcp.zerogravity.industries` puts Switchyard's MCP tool surface where a **hosted**
Claude surface can reach it — Claude.ai, Desktop, mobile and Cowork all connect from
Anthropic's cloud, not from your device, so the local stdio MCP is unreachable to them
by construction. The origin half (the `switchyard-mcp` container, its `internal`-only
router, the AUD map entry) is SERV-99 and lives in this repo. The Zero Trust half is
SERV-100 and cannot be made from a file here.

**Do the dashboard work in this order.** The Access policy goes on before the hostname
is mapped, or the MCP is briefly open to anyone who finds the name:

```
1. Confirm Managed OAuth and the MCP application type are on the current plan.
   Every step below assumes them, and finding out afterwards means the origin work
   has nowhere to land.
2. Create the Access application for mcp.zerogravity.industries.
   Allow-by-email against the built-in one-time-PIN IdP, same as SERV-24/25.
3. Enable Managed OAuth on it, and allow the redirect URI
   https://claude.ai/api/mcp/auth_callback  (covers web, Desktop, mobile and Cowork —
   they share the hosted-surface callback). Without Managed OAuth an unauthenticated
   request gets a 302 to the Access login page; Claude needs a 401 carrying
   WWW-Authenticate: Bearer resource_metadata="…" to discover the authorization
   server, and a redirect-to-HTML surfaces as "Couldn't reach the MCP server". That
   is the specific reason the earlier attempts failed.
4. Copy the application's AUD tag into all THREE places it is read:
     - MCP_CF_ACCESS_AUD on the switchyard-mcp service
     - the mcp.zerogravity.industries entry in CF_ACCESS_AUD_MAP on cf-access-guard
     - CF_ACCESS_MCP_AUD on the SWITCHYARD service (SERV-99) — this is the one that
       is easy to miss and fails silently. switchyard-mcp forwards each caller's
       assertion to switchyard to exchange for that person's token, and those JWTs
       carry the MCP application's audience, so without it every remote tool call
       401s on POST /v1/auth/sso/cloudflare while Access, the guard, the container
       and the container all stay green. All three are cross-checked by
       check-edge-auth.sh, so on a rotation run `make edge-auth-check` (or
       `config_only=1` from a checkout) rather than eyeballing them — the third
       needed a check of its own, because the sweep that covers the first two
       matches names ENDING in CF_ACCESS_AUD and structurally cannot see it
       (SERV-161).
   The tag is per-application and is NOT switchyard's d3404fc3…; sharing that one
   would let a Switchyard session token drive the MCP.
5. Only now add the tunnel route — Networks > Tunnels > the PROD tunnel (not the
   dev one, SERV-93) > "published application routes" in the current UI, "public
   hostnames" in older ones. Type HTTP, URL traefik:9080, no path. Same as every
   other tunneled app. This is a different object from the Access application in
   step 2; both are required.
6. Connect it in Cowork: Customize → Connectors → Add custom connector →
   https://mcp.zerogravity.industries/mcp
7. Register it in the delivery inventory — BLOCKED UPSTREAM on SWY-399, see below:
   ./scripts/register-delivery-service.sh switchyard-mcp 4080
```

**Step 7 does not work yet, and forcing it would be worse than leaving it undone.**
Verified against the deployed 4.29 container: `switchyard-mcp`'s `/healthz` answers
`{"status":"ok"}` — no `version`, no `sha` — where switchyard's answers
`{"status":"ok","version":"4.29.3","sha":"…"}`. So `register-delivery-service.sh`
refuses, correctly. The data is not missing, only unexposed: the image carries
`org.opencontainers.image.version=4.29.3` and the matching revision label. That makes it
an upstream fix in switchyard's repo — the PRINCIPLES.md §4 / SWY-192 reporting contract,
which §4 says new services adopt on day one — and nothing this repo can do. **Tracked as
SWY-399**, which is how to answer "has it shipped yet?": nothing here reddens to prompt
the question, so the ticket is the only handle on it.

**Do NOT reach for `--allow-no-version` to get past it.** That flag is the one move that
converts a visible gap into an invisible one. A `no_version` probe updates the pair's
probe state but writes NO observation row, so the next deploy that recreates the
container reports it with nothing to corroborate the claim: `claimed_not_confirmed`,
permanently. Left unregistered the service is merely *absent* from the matrix —
`delivery-reportable.sh` filters reports to services Switchyard already tracks, so
nothing reddens and nothing lies. Absent is recoverable in one command; a permanently red
row that everyone learns to scroll past is not.

Ship the contract upstream, release, deploy, then run the command above. It checks the
inventory first and is a no-op on re-run, so it is safe to retry and safe to leave in a
runbook someone follows twice.

**The AUD is what gates the merge, not a nice-to-have.** `MCP_CF_ACCESS_AUD` is
required by the image — the process throws at boot rather than starting up unable to
fail closed — so without a real value the container crash-loops and `assert-healthy.sh`
fails the deploy. And a gated router whose host has no `CF_ACCESS_AUD_MAP` entry fails
`check-edge-auth.sh`, which `deploy.yml` runs as a post-deploy gate. Both are the
loud-failure direction, but they mean steps 1–4 above genuinely precede merging the
SERV-99 diff, even though the ticket link reads SERV-99 → blocks → SERV-100.

**Two checks are doing different jobs here, and neither is redundant.** `cf-access-jwt`
on the router decides whether the request is served at all; the MCP server re-verifies
the same assertion against its own AUD and exchanges it at `POST /v1/auth/sso/cloudflare`
to decide *who* it is served as. That exchange is why there is no Switchyard token on
the container: a tool call from Cowork lands in Switchyard attributed to the signed-in
person, not to a shared service identity.

**Not behind CrowdSec, deliberately.** Anthropic's egress is one narrow range
(`160.79.104.0/21`) hitting one endpoint repeatedly — the exact shape a bouncer
scenario reads as abuse — and a single decision against it would break every remote
tool call at once. This needs no action to stay true: the bouncer is attached
per-router on the `public` entrypoint only, and nothing tunneled carries it.

**Verification is a request through the public path, and only that.** Internal
container-to-container success proves nothing about Access:

```bash
# 401 with a resource_metadata pointer — NOT a 302, and not HTML.
curl -si -X POST -H 'Content-Type: application/json' -d '{}' \
  https://mcp.zerogravity.industries/mcp | head -20

# The origin still refuses a spoofed Host, MCP host included.
./scripts/check-edge-auth.sh
```

**What a working endpoint actually looks like** (measured 2026-09-02, once the tunnel
route was live). The 401 comes from **Cloudflare**, not from the container, and it
points at Cloudflare's own discovery path rather than the origin's RFC 9728 one:

```
HTTP/2 401
www-authenticate: Bearer realm="OAuth", error="invalid_token", …
  resource_metadata="https://mcp.zerogravity.industries/.well-known/cloudflare-access-protected-resource/mcp"
server: cloudflare
```

That is Managed OAuth working. Two consequences worth knowing before troubleshooting
anything here:

- **Discovery never reaches the origin.** Cloudflare answers *both* its own path and
  the origin's `/.well-known/oauth-protected-resource/mcp` with a 200 (`server:
  cloudflare`, `cf-version` header, a body that differs from the container's), while
  the same two paths at the internal entrypoint with a spoofed `Host` both answer
  **403**. The edge satisfies discovery and the origin still fails closed, so the
  `Path()` exemption the router comment describes is not needed. Do not add one.
- **A `302` to a login page is the failure that matters**, and it is an Access
  application problem rather than an origin one: Managed OAuth is not applying. The
  origin's own 401 is already correct and is not what a client sees — confirm that
  before touching anything at the edge:

  ```bash
  docker exec switchyard-mcp sh -c \
    'wget -qS -O- --post-data="{}" --header="Content-Type: application/json" \
     http://localhost:4080/mcp 2>&1 | head -3'
  ```

### Verification (subset of SERV-30, run once the relay + tunnel exist)

- `curl --resolve switchyard.zerogravity.industries:443:<WAN_IP> https://switchyard.zerogravity.industries`
  must be refused on the public entrypoint (proves no tunnel bypass).
- A request with a forged `X-Authentik-Username` header must not be trusted (proves stripping).
- `./scripts/check-edge-auth.sh` — a spoofed `Host` against the internal entrypoint,
  **from the host**, must return 403 (SERV-106). Runs today, no relay required. The
  host angle is the one a container-side probe misses: an unpublished container port
  is still routable from the host on Linux, so "unreachable from `construct_net`" was
  never the same claim as "rejected".
