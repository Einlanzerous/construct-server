# Shared Cloudflare Access test vectors

`vectors.json` is a set of signed tokens, JWKS documents and expected verdicts,
run by **both** `pkg/cfaccess`'s Go tests and Switchyard's TypeScript suite
against `jose` (SERV-131). It is the only mechanism in that design that spans the
language boundary — code sharing cannot reach a TypeScript service.

Regenerate with:

```sh
cd pkg/cfaccess && go test ./... -run TestUpdateVectors -update
```

## About `keys/`

**These two RSA private keys are not secrets, and they are checked in on
purpose.**

They were generated for this fixture, they are used for nothing else, and they
sign tokens for a team domain that does not exist
(`vectors.cloudflareaccess.test`). Publishing private keys in a test vector set
is normal — RFC 7515 Appendix A does the same thing, for the same reason.

The reason they are *checked in* rather than generated per run is the whole point
of the ticket. RSASSA-PKCS1-v1_5 signing is deterministic, so fixed keys make
regeneration byte-stable: `-update` after an unrelated edit produces **no diff**,
and a diff therefore means the vectors really changed. Generated keys would
rewrite every token on every run, which makes the diff worthless and — worse —
lets a failing vector be "fixed" by regenerating it. Two suites, in two
languages, in two repositories, each regenerating their own fixtures is precisely
how both stay green while drifting apart.

`weak-1024.pem` is 1024-bit deliberately: the `weak-modulus` vector needs a token
**genuinely signed** by an undersized key, so that rejecting it demonstrates the
modulus floor rather than a signature mismatch.

GitGuardian flags both files as `RSA Private Key`, correctly as a pattern match.
`.gitguardian.yaml` at the repo root excludes this one directory and explains
why; the GitHub App reads its own dashboard config rather than that file, so its
incidents on this path are triaged there once as test fixtures.

## Vector classes

Each vector carries a `class`:

- **`protocol`** — a rule any conforming verifier must apply (`alg: none`, an RSA
  public key replayed as an HMAC secret, cross-application audience, wrong
  issuer, expiry, `nbf`, unknown `kid`, tampered payload). Both suites must
  agree.
- **`keypolicy`** — estate hardening about key material that a general JWT
  library does not necessarily enforce (nine-byte exponent, 2048-bit modulus
  floor, `use: "enc"`, one bad key among good ones). Where an implementation
  legitimately differs, the vector records it in `expectBy` rather than the
  difference being silently skipped.
