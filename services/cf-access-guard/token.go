package main

import (
	"crypto"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
)

// Clock skew tolerance. The origin and Cloudflare's edge are independently
// synced, and a token that is one second "not yet valid" is a clock problem,
// not an attack. Kept small on purpose: this is the window in which an expired
// token still passes, so it buys nothing to make it generous.
const leeway = 60 * time.Second

// Cloudflare Access signs with RS256 and publishes RSA keys at
// /cdn-cgi/access/certs. The algorithm is PINNED here rather than read from the
// token, which is the whole point: `alg` is attacker-controlled, so a verifier
// that dispatches on it accepts `none` (no signature at all) and accepts HS256
// with the RSA public key — which is public — used as the HMAC secret. Neither
// reaches a key lookup here, because nothing but RS256 gets past this constant.
const signingAlg = "RS256"

// verifiedClaims is what a caller gets back on success. Only the fields the
// guard has a use for; everything else in the token is ignored rather than
// echoed onward, since the guard deliberately adds no headers to the request it
// approves (the apps behind it read the same JWT themselves).
type verifiedClaims struct {
	Email   string
	Subject string
	Expires time.Time
}

// audience is a JWT `aud`, which RFC 7519 allows to be either a single string
// or an array of strings. Cloudflare emits an array today; accepting both is
// two lines and removes a class of "worked until it didn't".
type audience []string

func (a *audience) UnmarshalJSON(b []byte) error {
	var one string
	if err := json.Unmarshal(b, &one); err == nil {
		*a = audience{one}
		return nil
	}
	var many []string
	if err := json.Unmarshal(b, &many); err != nil {
		return errors.New("aud is neither a string nor an array of strings")
	}
	*a = many
	return nil
}

func (a audience) contains(want string) bool {
	for _, got := range a {
		if got == want {
			return true
		}
	}
	return false
}

type joseHeader struct {
	Alg string `json:"alg"`
	Kid string `json:"kid"`
}

type accessClaims struct {
	Iss   string   `json:"iss"`
	Aud   audience `json:"aud"`
	Exp   int64    `json:"exp"`
	Nbf   int64    `json:"nbf"`
	Iat   int64    `json:"iat"`
	Sub   string   `json:"sub"`
	Email string   `json:"email"`
}

// keyLookup is the JWKS side of verification, narrowed to the one thing
// verify() needs. An interface here is what lets the tests sign with their own
// key material and never touch the network.
type keyLookup interface {
	key(kid string) (*rsa.PublicKey, error)
}

// verify checks a Cf-Access-Jwt-Assertion end to end and returns its claims.
//
// Every failure is an error — there is no partial success and no "valid but".
// The caller turns any error into a 403, so a check that is accidentally
// skipped is a check that silently passes; that is why the order below runs
// signature first and claims second, and why each claim is required rather than
// validated-if-present. An absent `exp` must not read as "never expires".
func verify(raw string, keys keyLookup, wantIssuer, wantAudience string, now time.Time) (*verifiedClaims, error) {
	parts := strings.Split(raw, ".")
	if len(parts) != 3 {
		return nil, fmt.Errorf("malformed token: got %d segments, want 3", len(parts))
	}

	headerBytes, err := decodeSegment(parts[0])
	if err != nil {
		return nil, fmt.Errorf("header: %w", err)
	}
	var header joseHeader
	if err := json.Unmarshal(headerBytes, &header); err != nil {
		return nil, fmt.Errorf("header: not JSON: %w", err)
	}
	if header.Alg != signingAlg {
		return nil, fmt.Errorf("unsupported alg %q, only %s is accepted", header.Alg, signingAlg)
	}
	if header.Kid == "" {
		return nil, errors.New("header carries no kid, so no key can be selected")
	}

	pub, err := keys.key(header.Kid)
	if err != nil {
		return nil, fmt.Errorf("kid %q: %w", header.Kid, err)
	}

	sig, err := decodeSegment(parts[2])
	if err != nil {
		return nil, fmt.Errorf("signature: %w", err)
	}
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	if err := rsa.VerifyPKCS1v15(pub, crypto.SHA256, digest[:], sig); err != nil {
		return nil, fmt.Errorf("signature does not verify against kid %q", header.Kid)
	}

	// Only now are the claims worth reading: until the signature checks out they
	// are attacker-supplied text.
	payloadBytes, err := decodeSegment(parts[1])
	if err != nil {
		return nil, fmt.Errorf("payload: %w", err)
	}
	var claims accessClaims
	if err := json.Unmarshal(payloadBytes, &claims); err != nil {
		return nil, fmt.Errorf("payload: not JSON: %w", err)
	}

	if claims.Iss != wantIssuer {
		return nil, fmt.Errorf("issuer %q is not %q", claims.Iss, wantIssuer)
	}
	// The audience is what makes this per-application rather than per-team. Every
	// app on the team domain is signed by the same key, so without this check a
	// token minted for the wiki would open Switchyard.
	if !claims.Aud.contains(wantAudience) {
		return nil, fmt.Errorf("audience %v does not include the AUD registered for this host", []string(claims.Aud))
	}
	if claims.Exp == 0 {
		return nil, errors.New("no exp claim — a token with no expiry is not accepted")
	}
	exp := time.Unix(claims.Exp, 0)
	if now.After(exp.Add(leeway)) {
		return nil, fmt.Errorf("expired at %s", exp.UTC().Format(time.RFC3339))
	}
	if claims.Nbf != 0 {
		if nbf := time.Unix(claims.Nbf, 0); now.Add(leeway).Before(nbf) {
			return nil, fmt.Errorf("not valid before %s", nbf.UTC().Format(time.RFC3339))
		}
	}
	if claims.Iat != 0 {
		if iat := time.Unix(claims.Iat, 0); now.Add(leeway).Before(iat) {
			return nil, fmt.Errorf("issued in the future, at %s", iat.UTC().Format(time.RFC3339))
		}
	}

	return &verifiedClaims{Email: claims.Email, Subject: claims.Sub, Expires: exp}, nil
}

// decodeSegment decodes one JOSE segment. Base64URL WITHOUT padding is what the
// spec requires (RFC 7515 §2), and RawURLEncoding is the encoder that rejects
// padding rather than tolerating it — a token that only decodes under a laxer
// encoder is a malformed token.
func decodeSegment(s string) ([]byte, error) {
	b, err := base64.RawURLEncoding.DecodeString(s)
	if err != nil {
		return nil, fmt.Errorf("not base64url: %w", err)
	}
	return b, nil
}
