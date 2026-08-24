# The shared Cloudflare Access verifier

One implementation of one trust decision — *is this JWT a valid Cloudflare
Access assertion for one of these audiences* — imported by every Go service on
the estate that needs to ask it (SERV-131).

It lives at
[`pkg/cfaccess`](../pkg/cfaccess), and the reference consumer is
[`services/cf-access-guard`](../services/cf-access-guard).

## Why this was worth sharing

The usual objection to premature sharing does not apply. This is not
similar-*looking* code: it is one protocol, one issuer, one team domain, one
decision. There is no per-service variation in the answer, only in what each
service does afterwards.

And the failure mode of duplication here is unusually bad. Every copy is a
security boundary, its inputs are remote, and a regression is invisible until
someone happens to read the file next to a better version of itself. That is not
hypothetical:

| | cf-access-guard | Lyceum | Chronicle |
|---|---|---|---|
| `len(e) > 8` exponent bound | yes | **no — panics** | yes |
| 2048-bit modulus floor | yes | no | yes |
| skips `use != "sig"` | yes | no | yes |
| bounded body read | yes | no | yes |
| refresh cooldown actually applies | yes | no | yes |
| audience | per-host map | single string | list |
| background refresh + health | yes | no | no |
| zero-key fetch treated as failure | yes | no | yes |

Lyceum's missing exponent bound is **LYCM-122**: a JWKS key with a nine-byte RSA
exponent left-pads into a fixed eight-byte buffer, slices it at index `-1`, and
panics the process — remote input, security path, no `recover`. The guard had
fixed that bound; Lyceum never got it. Nobody was wrong at any point, which is
the whole problem: the copy was correct when it was made and stopped being
correct without anything happening to it.

Chronicle's column is green only because CHRN-71's review caught it mid-flight
and it was re-ported from here. Left alone it would have shipped Lyceum's
version and become a second panicking copy.

## The packaging decision

### Module path: `github.com/Einlanzerous/construct-server/pkg/cfaccess`

A nested module in this repo, and not a new `Einlanzerous/estate-go`.

- **construct-server is public**, so `go get` works from the private consumer
  repos with no `GOPRIVATE`, no netrc, and no Actions-access configuration. This
  is the same argument that put SERV-92's reusable PR-review workflow here, and
  it is recorded in [`pr-reviewer.md`](pr-reviewer.md) — a decision that already
  resolved by checking rather than assuming, so it was reused rather than
  re-litigated.
- **The repo already runs multiple nested modules** — `services/cf-access-guard`
  and `tools/software-page` — with no root `go.mod`. This is the established
  shape here, not a new one.
- **The reference implementation was already here**, so the first commit is a
  move rather than a rewrite.

A dedicated `estate-go` repo was considered and rejected. It buys simpler tags
(`v0.1.0` instead of `pkg/cfaccess/v0.1.0`) and nothing else, against a new repo
to provision and Access-configure, and it splits the "shared thing" story that
construct-server currently owns end to end. If a *second* unrelated shared
package ever wants a home, that is the moment to revisit it — one package is not
a library.

### Tagging: release-please, in manifest mode

Hand-managed tags were the alternative and were rejected. A shared module nobody
can reliably pin a version of is a shared module everyone eventually vendors a
copy of, which is where this started.

So `.github/workflows/release.yml` moved from inline `release-type: simple` to
**manifest mode**, with two packages in
[`release-please-config.json`](../release-please-config.json):

| package | tag | release type |
|---|---|---|
| `.` (the stack) | `v4.24.0` | `simple` |
| `pkg/cfaccess` | `pkg/cfaccess/v0.1.0` | `go` |

Two details in that config are load-bearing:

- **`"tag-separator": "/"`.** Go resolves a nested module only at
  `<path>/vX.Y.Z`. release-please's default component tag is
  `pkg/cfaccess-v0.1.0`, which `go get` cannot see at all. This is the single
  line that makes the module pinnable.
- **`"separate-pull-requests": true`**, so a verifier release does not wait
  behind a stack release or vice versa.

Two consequences to expect rather than be surprised by:

- Commits are assigned to the **deepest** matching package path, so a commit
  touching `pkg/cfaccess` lands in that module's changelog and no longer in the
  root's. That is standard monorepo behaviour, but it does mean the stack's
  release notes stop mentioning verifier changes.
- `pkg/cfaccess` starts at `0.0.0` in the manifest, so the first release-please
  run after this merges cuts **`pkg/cfaccess/v0.1.0`** with a changelog of its
  own. Downstream repos cannot pin until that release PR is merged. Bootstrapping
  by hand-tagging was possible and was not done: cutting the first tag through the
  same path every later tag will use is how we find out now, rather than at the
  third consumer, whether the tagging works.

## The API, and what is deliberately outside it

```go
v, err := cfaccess.New(cfaccess.Config{TeamDomain: team, Audience: auds})
claims, err := v.Verify(ctx, jwt)   // (*Claims, error)
err  = v.Refresh(ctx)               // explicit, never throttled
go v.Run(ctx)                       // optional background ticker
h   := v.Health()                   // can actually fail
```

The module serves two consumer shapes that both exist today, because an API that
served only one would not be adopted by the other:

- **A long-lived daemon** (cf-access-guard) wants the ticker and a health answer
  it can fail a container on.
- **A library inside an app** (Lyceum, Chronicle) wants lazy refresh and no
  goroutine to own. It simply never calls `Run`.

`HTTPClient` and `Now` are injectable so tests neither reach Cloudflare nor
sleep. The certs URL is **not** configurable — "verified by Cloudflare Access"
should not be something a deployment can repoint; a `Transport` on the injected
client is the test seam instead.

Deliberately **out of scope**, because folding per-service policy in is how a
shared module becomes unadoptable: the guard's per-host AUD map, session minting,
cookie handling, and account lookup. The one concession to the guard is
`VerifyAudience(ctx, jwt, aud...)`, which takes the required audience per call —
the *map* stays in the guard, but the audience **comparison** stays inside the
module, because an API that returned claims and left the caller to compare
audiences would be one forgotten line away from accepting everything.

## Shared test vectors

[`pkg/cfaccess/testdata/vectors.json`](../pkg/cfaccess/testdata/vectors.json) is
a set of signed tokens, key sets, and expected verdicts, run by **both** the Go
module's tests and Switchyard's TypeScript suite.

That cross-language run is the only mechanism in this design that reaches
Switchyard at all. Switchyard keeps `jose` — replacing a maintained library with
estate code would be the wrong direction — so code sharing cannot help there, and
the vectors are what give the fourth implementation a cross-check.

Each vector carries a `class`:

- **`protocol`** — a rule any conforming verifier must apply: `alg: none`, an RSA
  public key replayed as an HMAC secret, a cross-application audience, a wrong
  issuer, expiry, `nbf`, an unknown `kid`, a tampered payload. Both suites must
  agree, and these are exactly the cases a hand-rolled verifier gets wrong
  *quietly*.
- **`keypolicy`** — estate hardening about key material that a general JWT
  library does not necessarily enforce: the nine-byte exponent, the 2048-bit
  modulus floor (twice — bare, and the same weak key zero-padded to a longer
  encoding, which is what a `len(n)*8` check misses), `use: "enc"`, one bad key
  in an otherwise good set. Where an
  implementation legitimately differs, the vector records it in `expectBy` rather
  than the difference being silently skipped.

Regenerate with:

```sh
cd pkg/cfaccess && go test ./... -run TestUpdateVectors -update
```

The RSA keys are checked in under `testdata/keys/`, and RSASSA-PKCS1-v1_5 signing
is deterministic, so regeneration is byte-stable: a diff means the vectors really
changed. Minting new keys needs a separate `-regenerate-keys` flag — an ordinary
`-update` refuses rather than silently rewriting every token and leaving every
pinned consumer copy matching nothing.

Those keys are **not secrets** (throwaway, fictional team domain, published on
purpose — the same reason RFC 7515 Appendix A publishes private keys), so
`.gitguardian.yaml` excludes that one directory and each file carries the
disclaimer above its `BEGIN` line. See
[`pkg/cfaccess/testdata/README.md`](../pkg/cfaccess/testdata/README.md). The vectors are checked in rather than generated per-suite precisely
because two suites in two languages in two repositories regenerating their own
would let both stay green while drifting apart — the failure this ticket exists
to stop.

## Adopting it in a service

```sh
go get github.com/Einlanzerous/construct-server/pkg/cfaccess@v0.1.0
```

```go
verifier, err := cfaccess.New(cfaccess.Config{
    TeamDomain:   cfg.TeamDomain,
    Audience:     cfg.AUDs,   // a list; AUD tags are per Access application
    RequireEmail: true,       // you are minting a session from the identity
})
...
claims, err := verifier.Verify(r.Context(), r.Header.Get("Cf-Access-Jwt-Assertion"))
if err != nil {
    // One generic 401. Telling a caller *which* check failed is a probing
    // oracle; the reason belongs in your log, and the wrapped sentinel errors
    // (ErrAudience, ErrExpired, …) are there for that.
}
```

## Where the guard is different, and why

`services/cf-access-guard` is the only consumer that tracks the module at **HEAD**
rather than at a tag, through a path `replace` in its `go.mod`.

- It lives in the same repo. A tag would let the reference implementation and its
  own reference consumer disagree for as long as it took to cut one, and the
  guard is where a breaking change should be noticed *before* Lyceum and
  Chronicle inherit it.
- It keeps the build **hermetic**. The guard is rebuilt on every deploy on the
  box, and a `require` on the published tag would put proxy.golang.org between
  every deploy and the service that decides whether requests to the estate are
  authenticated. The module is stdlib-only, so with the path replace there is
  still no `go.sum` and nothing to download.

`pkg/cfaccess` therefore reaches the guard's Docker build as a **named build
context** (`--build-context cfaccess=./pkg/cfaccess`, `additional_contexts:` in
compose), not by widening the build context to the repo root. On the box that
root is `/opt/construct-server`, which holds the rendered `.env` — making it a
docker build context would put every credential in the stack one `.dockerignore`
mistake away from an image layer. A second, named context is bounded by
construction.

Two consequences that are easy to miss and are wired up:

- `deploy.yml` rsyncs `pkg/cfaccess/` to the deploy root alongside the guard's
  own source, because it is now a stack file for the same reason.
- `GUARD_REVISION` is resolved from **both** paths
  (`git log -1 -- services/cf-access-guard pkg/cfaccess`). Taken from the service
  directory alone, a module-only change would leave the revision unchanged, and a
  scoped deploy (SERV-109) would prove the running guard "current" while it ran
  the old verifier — the exact staleness that label exists to make impossible.
