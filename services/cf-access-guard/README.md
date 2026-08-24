# cf-access-guard

Origin-side validation of `Cf-Access-Jwt-Assertion` for Traefik's `internal`
entrypoint (SERV-106). A `forwardAuth` target: Traefik asks it about every
request on that entrypoint, and a request without a valid, correctly-audienced
Cloudflare Access token never reaches a backend.

## Why it exists

Cloudflare Access is enforced at Cloudflare's **edge**. Until this shipped, the
origin checked nothing, so anything that could open a connection to Traefik's
internal entrypoint got the tunneled apps by setting a `Host` header:

```
curl -H "Host: switchyard.zerogravity.industries" http://traefik:9080/   ->  200
```

— unauthenticated production Switchyard. SERV-107 made that connection harder to
obtain (the entrypoint binds one address on `construct_edge_net`, which only
cloudflared shares), but it authenticates nothing: the request became unroutable
from `construct_net`, not rejected, and anything with host access or the docker
socket still reaches the port. This is the half that rejects.

## Configuration

All environment, no flags. Missing or malformed configuration is a **startup
failure**, never a permissive default.

| Variable | Required | Meaning |
|---|---|---|
| `CF_ACCESS_TEAM_DOMAIN` | yes | e.g. `zero-gravity-industries.cloudflareaccess.com`. Becomes the expected `iss` and the JWKS origin. |
| `CF_ACCESS_AUD_MAP` | yes | `host=aud` pairs, comma- or whitespace-separated. A host absent from this map is refused. |
| `CF_ACCESS_GUARD_ADDR` | no | Listen address, default `:4020`. |
| `CF_ACCESS_JWKS_REFRESH` | no | Key refresh interval, default `1h`, floor `1m`. |
| `CF_ACCESS_GUARD_MODE` | no | `enforce` (default) or `audit`. |

Each app on a team domain has its **own AUD**, and every app's token is signed by
the same team key — so the per-host map is what makes this per-application. Without
it a token minted for the wiki would open Switchyard.

`audit` logs the decision it would have made and allows the request anyway. It
exists so the cutover could be rehearsed against real traffic before three live
routers went fail-closed at once. It is not a steady state:
`scripts/check-edge-auth.sh` fails while it is set.

## Endpoints

- `GET /verify` — the forwardAuth target. 200 allows, 403 denies. Reads the host
  from `X-Forwarded-Host` (which Traefik sets itself, because the middleware
  leaves `trustForwardHeader` false) and the token from `Cf-Access-Jwt-Assertion`.
- `GET /healthz` — 200 while a usable key set is loaded and fresh; 503 when none
  has ever loaded or refreshes have been failing for `3 × CF_ACCESS_JWKS_REFRESH`.
  That second case is the one that matters: stale keys mean every request is about
  to start failing, and this is what makes it visible before a user finds it.

## What it deliberately does not do

- **Adds no headers to requests it approves.** Switchyard and Lyceum validate the
  same assertion themselves for SSO (SWY-161, LYCM-803). A guard-asserted identity
  header would be a second, weaker path to the same trust decision — the spoofable
  identity header shape that `strip-identity-headers` exists to prevent.
- **Reads the header only, not the `CF_Authorization` cookie.** Cloudflare injects
  the header on every proxied request to an Access-protected app.
- **Returns no reason to the caller.** Distinguishing "wrong audience" from
  "expired" from "unknown host" is a probing oracle; the operator gets all three in
  the container log.

## Where the verification lives

Not in this directory. JWT parsing, the JWKS cache and every claim check are in
[`pkg/cfaccess`](../../pkg/cfaccess), the estate's one Cloudflare Access verifier
(SERV-131) — Lyceum and Chronicle import the same module. Three hand-rolled
copies of this code had already drifted far enough apart that one of them
panicked on a malformed key (LYCM-122) while this one did not.

What stays here is what the module deliberately refuses to know: the per-host AUD
map, audit mode, the forwardAuth contract with Traefik, and the healthcheck. The
audience is passed **per request** rather than configured once, so every tunneled
host is held to its own Access application — a wiki token is a perfectly valid
Cloudflare assertion and must still not open Switchyard.

The guard is the only consumer that tracks the module at HEAD, through a path
`replace`, which is what keeps this build hermetic: no `go.sum`, no proxy fetch on
any deploy. `pkg/cfaccess` therefore arrives as a **named build context**, so a
build here is:

```bash
docker build --build-context cfaccess=../../pkg/cfaccess \
  --target test -f Dockerfile .
```

Reasoning in full: [`docs/cf-access-verifier.md`](../../docs/cf-access-verifier.md).

## Working on it

```bash
go test ./...                  # this service's own decisions
(cd ../../pkg/cfaccess && go test ./...)   # the verification, incl. shared vectors
gofmt -l . && go vet ./...
make edge-auth-check           # assert the LIVE stack rejects a spoofed Host
```

The tests sign their own tokens with a throwaway RSA key and serve their own JWKS
through an injected `Transport`, so they need no network and no Cloudflare.

`TestATokenIsOnlyGoodForItsOwnHost` is this service's security surface — the one
property the shared module cannot test, because the per-host map is deliberately
the guard's. The bypass table it used to own (alg=none, HMAC replay, expired,
unknown kid, tampered payload) is now shared vectors in `pkg/cfaccess`, run by
this repo's Go tests **and** by Switchyard's TypeScript suite against `jose`.
