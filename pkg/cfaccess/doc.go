// Package cfaccess verifies Cloudflare Access JWT assertions.
//
// # Why this is shared
//
// Cloudflare Access is enforced at Cloudflare's EDGE. Any origin that wants to
// know whether a request really came through that edge — rather than from
// anything that could open a socket to it — has to verify the assertion itself.
// Four services on this estate reached that conclusion independently and each
// hand-rolled the same check: construct-server's cf-access-guard, Lyceum,
// Chronicle, and Switchyard (the last in TypeScript, on jose).
//
// The three Go copies were made by copying, and they drifted. LYCM-122 is what
// that cost: a JWKS key with a >8-byte RSA exponent sliced a fixed 8-byte buffer
// at a negative index and panicked the process, on a path reachable from a
// remote document, with no recover. construct-server had fixed that bound;
// Lyceum never got it. Nobody was wrong at any point — the copy was correct when
// it was made, and stopped being correct without anything happening to it.
//
// This package exists because that failure mode is unusually bad here and the
// usual objection to premature sharing does not apply. It is not "similar-looking
// code": it is one protocol, one issuer, one team domain, one decision — is this
// JWT a valid Cloudflare Access assertion for one of these audiences. There is
// no per-service variation in the answer, only in what each service does with it.
//
// # What is deliberately NOT here
//
// Everything downstream of the decision, because folding per-service policy into
// a shared module is how it becomes unadoptable: the guard's per-host AUD map,
// session minting, cookie handling, and account lookup all stay with their
// service. This package answers one question and returns claims.
//
// # Two consumer shapes
//
// A long-lived daemon (cf-access-guard) wants a background refresh ticker and a
// health answer it can fail a container on:
//
//	v, err := cfaccess.New(cfaccess.Config{TeamDomain: team, Audience: auds})
//	if err := v.Refresh(ctx); err != nil { log.Error(...) } // not fatal; fails closed
//	go v.Run(ctx)
//	...
//	if ok := v.Health().OK; !ok { /* 503 */ }
//
// A library inside an app (Lyceum, Chronicle) wants lazy refresh and no
// goroutine to own — construct the same way and simply never call Run. Keys are
// fetched on first use.
//
// # Failure posture
//
// Every path that is not a fully verified token returns an error. There is no
// partial success, no "valid but", and no allow-on-doubt branch. Errors are
// descriptive so an operator can read them in a log; callers that must not leak
// which check failed (a probing oracle) map any non-nil error to one generic
// response, which is what every consumer here does.
//
// Shared test vectors in testdata/vectors.json are run by this package's tests
// AND by Switchyard's TypeScript suite. They are the only mechanism in this
// design that spans the language boundary, and they cover the cases a
// hand-rolled verifier gets wrong quietly: alg=none, an RSA public key replayed
// as an HMAC secret, cross-application audiences, and malformed key material.
//
// SERV-131.
package cfaccess
