package cfaccess

import "errors"

// The verification failures a caller might reasonably want to distinguish.
//
// Every error returned by Verify wraps exactly one of these, so a consumer can
// branch with errors.Is without parsing a message — and the wrapped text carries
// the detail an operator needs in a log line.
//
// Distinguishing them is for the SERVER's benefit, never the client's: "wrong
// audience" versus "expired" versus "unknown kid" told apart by a caller is a
// probing oracle. Consumers on this estate map any non-nil error to one generic
// 401/403 and log the reason.
var (
	// ErrMalformed is a token that is not three base64url JOSE segments of JSON.
	ErrMalformed = errors.New("cfaccess: malformed assertion")

	// ErrUnsupportedAlgorithm is the one that matters most. `alg` is
	// attacker-controlled, so a verifier that DISPATCHES on it accepts "none"
	// (no signature at all) and accepts HS256 with the RSA public key — which is
	// public — used as the HMAC secret. Nothing but RS256 reaches a key lookup
	// here, so neither is representable rather than merely rejected.
	ErrUnsupportedAlgorithm = errors.New("cfaccess: unsupported signing algorithm")

	// ErrUnknownKey is a kid that is not in the key set, after a refresh.
	ErrUnknownKey = errors.New("cfaccess: no such signing key")

	// ErrNoKeys is the cold/failed state: nothing to verify against at all. Kept
	// distinct from ErrUnknownKey because "we hold no keys" and "we hold keys and
	// yours is not one" are different operational problems, and the log line is
	// the only place anyone will ever see which one happened.
	ErrNoKeys = errors.New("cfaccess: no signing keys are loaded")

	// ErrSignature is a signature that does not verify against the named key.
	ErrSignature = errors.New("cfaccess: signature does not verify")

	// ErrIssuer is a token minted by a different Cloudflare team.
	ErrIssuer = errors.New("cfaccess: wrong issuer")

	// ErrAudience is what makes verification per-application rather than
	// per-team. Every app on a team domain is signed by the SAME key, so without
	// this check a token minted for the wiki opens Switchyard.
	ErrAudience = errors.New("cfaccess: audience does not match")

	// ErrExpired is exp in the past (beyond Leeway), or absent. An absent exp is
	// an error and never "never expires".
	ErrExpired = errors.New("cfaccess: assertion has expired")

	// ErrNotYetValid is nbf or iat in the future (beyond Leeway).
	ErrNotYetValid = errors.New("cfaccess: assertion is not yet valid")

	// ErrNoEmail is an assertion with no email claim, returned only when
	// Config.RequireEmail is set. Services that mint a session from the verified
	// identity need it; the guard, which only decides pass/fail, does not.
	ErrNoEmail = errors.New("cfaccess: assertion carries no email claim")

	// ErrNoAudienceConfigured is a programming error surfaced as a verification
	// failure: Verify was called on a Verifier built with no audience, or
	// VerifyAudience was called with none. It fails CLOSED — "no audience
	// configured" must never read as "any audience will do".
	ErrNoAudienceConfigured = errors.New("cfaccess: no audience configured, so nothing could be accepted")
)
