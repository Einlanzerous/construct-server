# Origin auth: the Access JWT and the remote MCP AUD

Rationale moved out of the root `CLAUDE.md` (SERV-317). Verifier library decision:
`docs/cf-access-verifier.md`. Edge bring-up and the MCP runbook: `docs/zerogravity-edge.md`.

## The origin validates the Access JWT

**The origin validates the Access JWT — reaching the entrypoint is not enough**
(SERV-106). Cloudflare Access is enforced at Cloudflare's **edge**. The origin
used to re-check nothing, so anything that could connect to Traefik's `internal`
entrypoint got the tunneled apps by naming one in a `Host` header; that was
demonstrated, not theorised, and returned unauthenticated prod Switchyard. Every
router on that entrypoint now carries the `cf-access-jwt` forwardAuth middleware,
pointed at `cf-access-guard` (`services/cf-access-guard/`), which verifies the
token against the team's published signing keys and **the AUD registered for that
exact host**. Per-host matters: every app on the team domain is signed by the same
key, so a single static audience would let a wiki token open Switchyard.
**SERV-107 did not close this and neither closes the other.** The bind decides who
can *connect*; the middleware decides who is *served*. "Unroutable" is not
"rejected" — conflating them is how SERV-25's deferral stayed invisible for six
weeks. A host with no AUD entry is refused, so a new tunneled router that nobody
mapped is unreachable (loud) rather than unauthenticated (silent), and
`scripts/check-edge-auth.sh` fails if a router lacks the middleware or the map and
the routers disagree. **Exemptions are an allowlist, not a pattern, and there are
exactly two, of two different shapes.** `switchyard-github-webhook` is one host and
one **exact** `Path()`, because GitHub cannot authenticate to Access — Access
carries a Bypass policy on that path and injects no assertion at all, so without
an exempt router the webhook 403s and external-ref updates and PR-merge auto-close
stop silently (SERV-45). It is not unauthenticated; it is HMAC-gated by
`GITHUB_WEBHOOK_SECRET`, which is authentication Access cannot express. `placard`
is one bare `Host()` — **whole-host, public by design** (IDEA-22 / PCAD-5): every
surface it serves is contractually fetchable with no session, its content mirrors
a public GitHub repo, and its one write path is token-gated in the app. The
checker verifies each shape differently: an exact-path exemption must bypass the
guard on that path while the rest of the host still 403s; a whole-host exemption
is asserted **inverted** — a sessionless request must get a 200 with the guard
uninvolved, and the host must carry **no AUD** (an Access application on a host
the origin serves openly is the edge and origin disagreeing). Anything broader
than those two shapes — a `PathPrefix()`, multiple hosts, an OR — is refused as
too broad to verify, and an internal router that is neither gated nor on the
allowlist fails the check. It also runs the exploit itself against the live edge, from
the **host** — an unpublished container port is still routable from there, which no
container-side probe sees. `--dev` points the same script at the dev edge (SERV-93)
rather than there being a second copy of it — one question, one implementation, and
the only difference in substance is that dev's exemption allowlist is empty.
**"The origin authenticates" and "the host is Access-gated" are different claims, and
only the second needs Cloudflare** (SERV-171). Whether an Access *application* covers a
hostname is dashboard state no file here holds: catenary went live with its router,
middleware and AUD entry all correct and its application on a typo'd hostname, and this
script was green throughout. The guard 403'd everything, so nothing was exposed — but the
host was gated *shut* (no assertion obtainable, legitimate callers refused for ever) and
the estate had one layer where it believed it had two. So the live half also requests
each gated host through the public path, unauthenticated, and asserts a redirect to the
guard's team domain at **that host's** login whose `kid=` equals its `CF_ACCESS_AUD_MAP`
entry; the origin guard answering instead is the failure, and an unreachable edge is a
failure, not a skip. It asks **as a browser** (`Accept: text/html`) because `mcp.` has
Managed OAuth and answers a bare request `401` rather than redirecting. The closing
summary states the two claims separately. `make edge-auth-test` proves the check can still
go red, against stubbed `docker`/`curl` — a host with no application cannot be made on the
real edge without breaking prod. `deploy.yml` runs it as a post-deploy gate; locally it is
`make edge-auth-check`. The guard is the one first-party image **built on the box**
rather than pinned (stdlib-only Go, no deps), so `deploy.yml` builds it explicitly —
`up -d` alone would keep running a stale image without complaint. Its image carries
`org.opencontainers.image.revision`, stamped at build time from
`git log -1 -- services/cf-access-guard pkg/cfaccess` (SERV-109, widened by SERV-131 —
the guard's behaviour is partly in the shared module now, so a revision taken from the
service directory alone would call a stale guard current after a module-only change). That label is the guard's **only** identity: it has no pin, and
its image ID is useless for comparison because BuildKit re-exports the config on every
build, so a full cache hit still yields a new ID. Recreating on an ID difference would
bounce the auth path on every deploy; recreating on a revision difference bounces it
exactly when the source moved.

## The remote MCP endpoint and its AUD

**The remote MCP endpoint is a tunneled host like any other, and its AUD variable is
deliberately not `CF_ACCESS_AUD`** (SERV-99 / SWY-260). `switchyard-mcp` serves
Switchyard's MCP tool surface over Streamable HTTP at `mcp.zerogravity.industries`, so
a **hosted** Claude surface can reach it — those connect from Anthropic's cloud, not
from the user's device, which is why the local stdio MCP cannot serve them. It reads
`MCP_CF_ACCESS_AUD`, because Access audiences are per-application and this endpoint is
its own application; a `CF_ACCESS_AUD` sitting beside it in the same env file is
ignored on purpose, and reusing switchyard's would let a Switchyard session drive the
MCP. **It holds no Switchyard token at all** — every session exchanges its own Access
assertion at `POST /v1/auth/sso/cloudflare` for the real person's token, so a tool call
lands attributed to them rather than to a shared identity, and the image refuses to
read a process-wide token. Two consequences that are easy to miss: it ships on
switchyard's release train, so `SWITCHYARD_TAG` now covers **three** services and
carries a **rollback floor of 4.18** (the mcp image's first release — `verify-tag.sh`
refuses anything below it rather than half-deploying); and it must never go behind
`crowdsec-bouncer`, since Anthropic's egress is one narrow range hitting one endpoint
repeatedly and a single decision against it breaks every remote tool call at once.
That last one needs no guarding — the bouncer is attached per-router on `public` only.
The Zero Trust half (the Access application, its **Managed OAuth**, the tunnel
hostname) is SERV-100 and no file here can make it; without Managed OAuth an
unauthenticated request gets a `302` to a login page where Claude needs a `401` with
`WWW-Authenticate: … resource_metadata="…"`, which is why the earlier attempts failed.
Runbook: `docs/zerogravity-edge.md` §4.
**That one AUD tag lives in THREE places and the third is the one that fails silently.**
`MCP_CF_ACCESS_AUD` on `switchyard-mcp`, the `mcp.zerogravity.industries` entry in
`CF_ACCESS_AUD_MAP` on `cf-access-guard`, and `CF_ACCESS_MCP_AUD` on **switchyard** —
which is what lets the SSO exchange accept an assertion minted for the MCP application,
since the MCP holds no token and forwards each caller's JWT to
`POST /v1/auth/sso/cloudflare` verbatim. Miss the third and Access authenticates, the
guard passes, the container is healthy, `check-edge-auth` passes and `assert-healthy`
is green while **every remote tool call 401s** — the only evidence being a line in
switchyard's own request log. That was SERV-99's actual bug. All three are now
cross-checked by `check-edge-auth.sh` (SERV-161); note the first two are compared by a
regex sweep over names *ending* in `CF_ACCESS_AUD`, which structurally cannot see the
third, so it is asserted by name and widening that pattern is not the fix — it would
also swallow `CF_ACCESS_AUD_MAP` and compare the map against itself.
