package cfaccess

// Generator for the shared test vectors.
//
//	go test ./... -run TestUpdateVectors -update
//
// The vectors are checked in, not generated at test time, because they are run
// by TWO suites in two languages and two repositories — this package's tests and
// Switchyard's TypeScript suite (SERV-131). A fixture that each side regenerated
// would let the two drift apart while both stayed green, which is the exact
// failure this whole ticket exists to stop.
//
// Regeneration is byte-stable: the RSA keys are checked in as PEM under
// testdata/keys, RSASSA-PKCS1-v1_5 signing is deterministic (no random padding),
// and every timestamp is derived from a fixed epoch. So `-update` after an
// unrelated edit produces no diff, and a diff means the vectors really changed.

import (
	"crypto"
	"crypto/hmac"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"flag"
	"math/big"
	"os"
	"path/filepath"
	"testing"
	"time"
)

var update = flag.Bool("update", false, "regenerate testdata/vectors.json")

const (
	vectorTeamDomain = "vectors.cloudflareaccess.test"
	vectorIssuer     = "https://" + vectorTeamDomain
	// Two audiences, because one is not enough to prove the cross-application
	// check does anything: "accepts audA" and "accepts everything" look the same
	// with a single tag.
	audWeb  = "8f0e3c6b1d2a4f5e9c7b0a1d3e5f7091a2b3c4d5e6f708192a3b4c5d6e7f8091"
	audMCP  = "1a2b3c4d5e6f708192a3b4c5d6e7f8091f0e3c6b1d2a4f5e9c7b0a1d3e5f7092"
	kidGood = "sig-2048-a"
	kidWeak = "sig-1024"
)

// vectorEpoch is the fixed "now" every vector is written against.
var vectorEpoch = time.Date(2026, 8, 23, 12, 0, 0, 0, time.UTC)

type vectorFile struct {
	Spec       string             `json:"spec"`
	Comment    string             `json:"$comment"`
	TeamDomain string             `json:"teamDomain"`
	Issuer     string             `json:"issuer"`
	KeySets    map[string]jwksDoc `json:"keySets"`
	Vectors    []vector           `json:"vectors"`
}

type jwksDoc struct {
	Keys []map[string]any `json:"keys"`
}

type vector struct {
	Name        string            `json:"name"`
	Description string            `json:"description"`
	Class       string            `json:"class"` // "protocol" | "keypolicy"
	KeySet      string            `json:"keySet"`
	Audience    []string          `json:"audience"`
	Now         string            `json:"now"`
	Token       string            `json:"token"`
	Expect      string            `json:"expect"` // "accept" | "reject"
	Because     string            `json:"because"`
	Claims      *expectedClaims   `json:"claims,omitempty"`
	ExpectBy    map[string]string `json:"expectBy,omitempty"`
	ExpectByWhy string            `json:"expectByWhy,omitempty"`
}

type expectedClaims struct {
	Email   string `json:"email"`
	Subject string `json:"sub"`
}

func b64(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

// loadOrCreateKey keeps the RSA material stable across regenerations. Checked in
// as PEM so a new machine produces identical vectors.
func loadOrCreateKey(t *testing.T, name string, bits int) *rsa.PrivateKey {
	t.Helper()
	path := filepath.Join("testdata", "keys", name+".pem")
	if raw, err := os.ReadFile(path); err == nil {
		block, _ := pem.Decode(raw)
		if block == nil {
			t.Fatalf("%s is not PEM", path)
		}
		k, err := x509.ParsePKCS1PrivateKey(block.Bytes)
		if err != nil {
			t.Fatalf("%s: %v", path, err)
		}
		return k
	}
	if !*update {
		t.Fatalf("%s is missing; run: go test ./... -run TestUpdateVectors -update", path)
	}
	k, err := rsa.GenerateKey(rand.Reader, bits)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	out := pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(k)})
	if err := os.WriteFile(path, out, 0o644); err != nil {
		t.Fatal(err)
	}
	return k
}

func jwkFor(pub *rsa.PublicKey, kid, use string) map[string]any {
	k := map[string]any{
		"kid": kid,
		"kty": "RSA",
		"alg": "RS256",
		"n":   b64(pub.N.Bytes()),
		"e":   b64(big.NewInt(int64(pub.E)).Bytes()),
	}
	if use != "" {
		k["use"] = use
	}
	return k
}

// signRS256 builds a JWT from raw maps rather than typed structs on purpose: the
// interesting vectors are the malformed ones, and a struct makes several of them
// unrepresentable.
func signRS256(t *testing.T, key *rsa.PrivateKey, header, claims map[string]any) string {
	t.Helper()
	signing := encodeSegments(t, header, claims)
	digest := sha256.Sum256([]byte(signing))
	sig, err := rsa.SignPKCS1v15(rand.Reader, key, crypto.SHA256, digest[:])
	if err != nil {
		t.Fatal(err)
	}
	return signing + "." + b64(sig)
}

func encodeSegments(t *testing.T, header, claims map[string]any) string {
	t.Helper()
	h, err := json.Marshal(header)
	if err != nil {
		t.Fatal(err)
	}
	c, err := json.Marshal(claims)
	if err != nil {
		t.Fatal(err)
	}
	return b64(h) + "." + b64(c)
}

func baseClaims() map[string]any {
	return map[string]any{
		"iss":   vectorIssuer,
		"aud":   []string{audWeb},
		"exp":   vectorEpoch.Add(time.Hour).Unix(),
		"iat":   vectorEpoch.Add(-time.Minute).Unix(),
		"nbf":   vectorEpoch.Add(-time.Minute).Unix(),
		"sub":   "0123456789abcdef0123456789abcdef",
		"email": "operator@example.test",
	}
}

func with(base map[string]any, over map[string]any) map[string]any {
	out := make(map[string]any, len(base)+len(over))
	for k, v := range base {
		out[k] = v
	}
	for k, v := range over {
		if v == nil {
			delete(out, k)
			continue
		}
		out[k] = v
	}
	return out
}

func rs256Header(kid string) map[string]any {
	return map[string]any{"alg": "RS256", "kid": kid, "typ": "JWT"}
}

func TestUpdateVectors(t *testing.T) {
	if !*update {
		t.Skip("run with -update to regenerate testdata/vectors.json")
	}

	good := loadOrCreateKey(t, "good-2048", 2048)
	weak := loadOrCreateKey(t, "weak-1024", 1024)

	goodJWK := jwkFor(&good.PublicKey, kidGood, "sig")
	// A 9-byte exponent: the LYCM-122 panic. Not a key anything can verify with;
	// the point is that parsing it must not slice a fixed 8-byte buffer at -1.
	bigExp := jwkFor(&good.PublicKey, kidGood, "sig")
	bigExp["e"] = b64([]byte{0x01, 0, 0, 0, 0, 0, 0, 0, 0x01})

	keySets := map[string]jwksDoc{
		"standard":      {Keys: []map[string]any{goodJWK}},
		"empty":         {Keys: []map[string]any{}},
		"encryptionUse": {Keys: []map[string]any{jwkFor(&good.PublicKey, kidGood, "enc")}},
		"weakModulus":   {Keys: []map[string]any{jwkFor(&weak.PublicKey, kidWeak, "sig")}},
		"bigExponent":   {Keys: []map[string]any{bigExp}},
		// One usable key beside one that is not: the whole set must not be
		// condemned by the bad one.
		"mixed": {Keys: []map[string]any{jwkFor(&weak.PublicKey, kidWeak, "sig"), goodJWK}},
	}

	nowStr := vectorEpoch.Format(time.RFC3339)
	goodToken := signRS256(t, good, rs256Header(kidGood), baseClaims())
	acceptedClaims := &expectedClaims{Email: "operator@example.test", Subject: "0123456789abcdef0123456789abcdef"}

	// alg:none — no signature at all. The empty third segment is what a verifier
	// that dispatches on `alg` happily accepts.
	algNone := encodeSegments(t, map[string]any{"alg": "none", "kid": kidGood, "typ": "JWT"}, baseClaims()) + "."

	// The RSA public key replayed as an HMAC secret. The public key is PUBLIC, so
	// a verifier that lets `alg` choose the algorithm lets anyone mint tokens.
	spki, err := x509.MarshalPKIXPublicKey(&good.PublicKey)
	if err != nil {
		t.Fatal(err)
	}
	pubPEM := pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: spki})
	hs := encodeSegments(t, map[string]any{"alg": "HS256", "kid": kidGood, "typ": "JWT"}, baseClaims())
	mac := hmac.New(sha256.New, pubPEM)
	mac.Write([]byte(hs))
	hmacReplay := hs + "." + b64(mac.Sum(nil))

	// A genuine token whose payload has been swapped for another genuine token's.
	other := signRS256(t, good, rs256Header(kidGood), with(baseClaims(), map[string]any{"email": "attacker@example.test"}))
	tamperedParts := splitJWT(t, goodToken)
	otherParts := splitJWT(t, other)
	tampered := tamperedParts[0] + "." + otherParts[1] + "." + tamperedParts[2]

	vs := []vector{
		{
			Name: "good-token", Class: "protocol", KeySet: "standard",
			Description: "a genuine Access assertion for the configured application",
			Audience:    []string{audWeb}, Now: nowStr, Token: goodToken,
			Expect: "accept", Because: "signature, issuer, audience and expiry all check out",
			Claims: acceptedClaims,
		},
		{
			Name: "scalar-audience", Class: "protocol", KeySet: "standard",
			Description: "aud as a bare string rather than an array (RFC 7519 allows both)",
			Audience:    []string{audWeb}, Now: nowStr,
			Token:  signRS256(t, good, rs256Header(kidGood), with(baseClaims(), map[string]any{"aud": audWeb})),
			Expect: "accept", Because: "a scalar aud is a one-element audience, not a malformed one",
			Claims: acceptedClaims,
		},
		{
			Name: "second-application-audience", Class: "protocol", KeySet: "standard",
			Description: "a token for the MCP application, verified by a service configured for both",
			Audience:    []string{audWeb, audMCP}, Now: nowStr,
			Token:  signRS256(t, good, rs256Header(kidGood), with(baseClaims(), map[string]any{"aud": []string{audMCP}})),
			Expect: "accept", Because: "AUD tags are per-application and a service may accept more than one",
			Claims: acceptedClaims,
		},
		{
			Name: "wrong-audience", Class: "protocol", KeySet: "standard",
			Description: "a valid token for a DIFFERENT Access application on the same team",
			Audience:    []string{audWeb}, Now: nowStr,
			Token:  signRS256(t, good, rs256Header(kidGood), with(baseClaims(), map[string]any{"aud": []string{audMCP}})),
			Expect: "reject", Because: "every app on a team domain is signed by the same key, so only aud separates them",
		},
		{
			Name: "wrong-issuer", Class: "protocol", KeySet: "standard",
			Description: "a token minted by a different Cloudflare team",
			Audience:    []string{audWeb}, Now: nowStr,
			Token:  signRS256(t, good, rs256Header(kidGood), with(baseClaims(), map[string]any{"iss": "https://other.cloudflareaccess.test"})),
			Expect: "reject", Because: "the issuer is pinned to this team domain",
		},
		{
			Name: "expired", Class: "protocol", KeySet: "standard",
			Description: "exp an hour in the past — well beyond any sane clock-skew leeway",
			Audience:    []string{audWeb}, Now: nowStr,
			Token: signRS256(t, good, rs256Header(kidGood), with(baseClaims(), map[string]any{
				"exp": vectorEpoch.Add(-time.Hour).Unix(),
				"iat": vectorEpoch.Add(-2 * time.Hour).Unix(),
				"nbf": vectorEpoch.Add(-2 * time.Hour).Unix(),
			})),
			Expect: "reject", Because: "an expired assertion is not an assertion",
		},
		{
			Name: "no-exp", Class: "protocol", KeySet: "standard",
			Description: "no exp claim at all",
			Audience:    []string{audWeb}, Now: nowStr,
			Token:  signRS256(t, good, rs256Header(kidGood), with(baseClaims(), map[string]any{"exp": nil})),
			Expect: "reject", Because: "an absent exp must never read as 'never expires'",
		},
		{
			Name: "not-yet-valid", Class: "protocol", KeySet: "standard",
			Description: "nbf an hour in the future",
			Audience:    []string{audWeb}, Now: nowStr,
			Token: signRS256(t, good, rs256Header(kidGood), with(baseClaims(), map[string]any{
				"nbf": vectorEpoch.Add(time.Hour).Unix(),
				"exp": vectorEpoch.Add(2 * time.Hour).Unix(),
			})),
			Expect: "reject", Because: "nbf is a validity window, not a hint",
		},
		{
			Name: "alg-none", Class: "protocol", KeySet: "standard",
			Description: "alg:none with an empty signature segment",
			Audience:    []string{audWeb}, Now: nowStr, Token: algNone,
			Expect: "reject", Because: "alg is attacker-controlled; a verifier that dispatches on it accepts unsigned tokens",
		},
		{
			Name: "hmac-replay", Class: "protocol", KeySet: "standard",
			Description: "HS256 with the RSA PUBLIC key as the HMAC secret — the classic algorithm-confusion forgery",
			Audience:    []string{audWeb}, Now: nowStr, Token: hmacReplay,
			Expect: "reject", Because: "the verification algorithm must be pinned, never taken from the token",
		},
		{
			Name: "unknown-kid", Class: "protocol", KeySet: "standard",
			Description: "a well-formed token naming a key the JWKS does not publish",
			Audience:    []string{audWeb}, Now: nowStr,
			Token:  signRS256(t, good, rs256Header("no-such-key"), baseClaims()),
			Expect: "reject", Because: "an unknown kid must not fall back to 'try every key'",
		},
		{
			Name: "tampered-payload", Class: "protocol", KeySet: "standard",
			Description: "a genuine header and signature with another token's payload spliced in",
			Audience:    []string{audWeb}, Now: nowStr, Token: tampered,
			Expect: "reject", Because: "the signature covers header.payload, so any payload edit breaks it",
		},
		{
			Name: "malformed-two-segments", Class: "protocol", KeySet: "standard",
			Description: "a JWS with the signature segment missing entirely",
			Audience:    []string{audWeb}, Now: nowStr, Token: encodeSegments(t, rs256Header(kidGood), baseClaims()),
			Expect: "reject", Because: "a compact JWS is exactly three segments",
		},
		{
			Name: "empty-key-set", Class: "protocol", KeySet: "empty",
			Description: "the certs endpoint published no keys",
			Audience:    []string{audWeb}, Now: nowStr, Token: goodToken,
			Expect: "reject", Because: "no keys means nothing can be verified; it is never an empty success",
		},
		{
			Name: "encryption-key", Class: "protocol", KeySet: "encryptionUse",
			Description: `the only published key is use:"enc"`,
			Audience:    []string{audWeb}, Now: nowStr, Token: goodToken,
			Expect: "reject", Because: "verifying a signature with an encryption key is a category error, not a near miss",
		},
		{
			Name: "nine-byte-exponent", Class: "keypolicy", KeySet: "bigExponent",
			Description: "a JWKS key with a 9-byte RSA exponent — LYCM-122, which sliced a fixed 8-byte buffer at index -1 and panicked the process",
			Audience:    []string{audWeb}, Now: nowStr, Token: goodToken,
			Expect: "reject", Because: "an oversized exponent is unusable key material and must be refused, not reconstructed",
		},
		{
			Name: "weak-modulus", Class: "keypolicy", KeySet: "weakModulus",
			Description: "a 1024-bit signing key, with a token genuinely signed by it",
			Audience:    []string{audWeb}, Now: nowStr,
			Token:  signRS256(t, weak, rs256Header(kidWeak), baseClaims()),
			Expect: "reject", Because: "Cloudflare publishes 2048-bit keys; a shorter one is a downgrade, not a small key",
		},
		{
			Name: "mixed-key-set", Class: "keypolicy", KeySet: "mixed",
			Description: "one unusable key published alongside a good one",
			Audience:    []string{audWeb}, Now: nowStr, Token: goodToken,
			Expect: "accept", Because: "one bad key must not condemn the set — that would make an upstream slip an estate-wide outage",
			Claims: acceptedClaims,
		},
	}

	out := vectorFile{
		Spec: "cfaccess-vectors/1",
		Comment: "Shared Cloudflare Access verification vectors (SERV-131). Generated by " +
			"pkg/cfaccess/mkvectors_test.go -update; run by this module's tests AND by " +
			"Switchyard's TypeScript suite. class=protocol must hold in any conforming " +
			"verifier; class=keypolicy is estate hardening about key material that a " +
			"general JWT library does not necessarily enforce — expectBy records where " +
			"a given implementation legitimately differs.",
		TeamDomain: vectorTeamDomain,
		Issuer:     vectorIssuer,
		KeySets:    keySets,
		Vectors:    vs,
	}

	buf, err := json.MarshalIndent(out, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join("testdata", "vectors.json"), append(buf, '\n'), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Logf("wrote testdata/vectors.json with %d vectors", len(vs))
}

func splitJWT(t *testing.T, tok string) [3]string {
	t.Helper()
	var out [3]string
	n := 0
	start := 0
	for i := 0; i < len(tok); i++ {
		if tok[i] == '.' {
			if n > 1 {
				t.Fatalf("token has more than three segments")
			}
			out[n] = tok[start:i]
			n++
			start = i + 1
		}
	}
	if n != 2 {
		t.Fatalf("token has %d separators, want 2", n)
	}
	out[2] = tok[start:]
	return out
}
