package cfaccess

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"time"
)

// signingAlg is PINNED rather than read from the token. See
// ErrUnsupportedAlgorithm for why that is the single most important line in this
// package.
const signingAlg = "RS256"

// Claims is a verified Cloudflare Access assertion.
//
// Only the fields a consumer on this estate has a use for. Everything else in
// the payload is ignored rather than echoed onward: a shared verifier that hands
// back the whole claim set invites a caller to trust a field nothing checked.
type Claims struct {
	// Email is the identity Cloudflare authenticated. Services that mint a
	// session key off this; require it with Config.RequireEmail.
	Email string
	// Subject is the Access `sub`, stable per user per application.
	Subject string
	// Issuer is the verified issuer, always https://<team domain>.
	Issuer string
	// Audience is every AUD tag the token carries, not just the one that
	// matched. A consumer with several Access applications can tell which.
	Audience []string
	// Expires, NotBefore and IssuedAt are zero when the claim was absent —
	// except Expires, which is never zero because an absent exp is an error.
	Expires   time.Time
	NotBefore time.Time
	IssuedAt  time.Time
}

// audience is a JWT `aud`, which RFC 7519 allows to be either a single string or
// an array of strings. Cloudflare emits an array today; accepting both is two
// lines and removes a class of "worked until it didn't".
type audience []string

func (a *audience) UnmarshalJSON(b []byte) error {
	var one string
	if err := json.Unmarshal(b, &one); err == nil {
		*a = audience{one}
		return nil
	}
	var many []string
	if err := json.Unmarshal(b, &many); err != nil {
		return fmt.Errorf("aud is neither a string nor an array of strings")
	}
	*a = many
	return nil
}

// intersects reports whether the token's audiences include any of want.
//
// An EMPTY want matches nothing, and that is load-bearing: it is the difference
// between "this service accepts no application" and "this service accepts every
// application". Callers must reject an empty want before getting here
// (ErrNoAudienceConfigured); this is the second line of defence.
func (a audience) intersects(want []string) bool {
	for _, w := range want {
		if w == "" {
			continue
		}
		for _, got := range a {
			if got == w {
				return true
			}
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
