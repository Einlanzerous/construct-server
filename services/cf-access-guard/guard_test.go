package main

import (
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"math/big"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

const (
	testIssuer = "https://zero-gravity-industries.cloudflareaccess.com"
	testAud    = "d3404fc362067f48ff1fd6c9a7fc9a1fd723510c2681feed15e35159649963de"
	testKid    = "kid-under-test"
)

var testKey = mustKey()

func mustKey() *rsa.PrivateKey {
	k, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		panic(err)
	}
	return k
}

// staticKeys is the key lookup the signature tests run against, so they exercise
// verify() without a JWKS endpoint in the way.
type staticKeys map[string]*rsa.PublicKey

func (s staticKeys) key(kid string) (*rsa.PublicKey, error) {
	if pub, ok := s[kid]; ok {
		return pub, nil
	}
	return nil, fmt.Errorf("unknown kid")
}

func b64(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

// signToken builds a JWT from raw maps rather than a typed struct on purpose:
// the interesting tests are the malformed ones, and a struct would make several
// of them unrepresentable.
func signToken(t *testing.T, key *rsa.PrivateKey, header, claims map[string]any) string {
	t.Helper()
	h, err := json.Marshal(header)
	if err != nil {
		t.Fatal(err)
	}
	c, err := json.Marshal(claims)
	if err != nil {
		t.Fatal(err)
	}
	signing := b64(h) + "." + b64(c)
	digest := sha256.Sum256([]byte(signing))
	sig, err := rsa.SignPKCS1v15(rand.Reader, key, crypto.SHA256, digest[:])
	if err != nil {
		t.Fatal(err)
	}
	return signing + "." + b64(sig)
}

func validHeader() map[string]any {
	return map[string]any{"alg": "RS256", "kid": testKid, "typ": "JWT"}
}

func validClaims(now time.Time) map[string]any {
	return map[string]any{
		"iss":   testIssuer,
		"aud":   []string{testAud},
		"exp":   now.Add(time.Hour).Unix(),
		"iat":   now.Unix(),
		"nbf":   now.Unix(),
		"sub":   "abc123",
		"email": "operator@example.com",
	}
}

func TestVerifyAcceptsAGenuineToken(t *testing.T) {
	now := time.Now()
	keys := staticKeys{testKid: &testKey.PublicKey}
	tok := signToken(t, testKey, validHeader(), validClaims(now))

	claims, err := verify(tok, keys, testIssuer, testAud, now)
	if err != nil {
		t.Fatalf("a genuine token was rejected: %v", err)
	}
	if claims.Email != "operator@example.com" {
		t.Fatalf("email = %q, want operator@example.com", claims.Email)
	}
}

// A single-string `aud` is legal per RFC 7519 and would be a silent outage if
// Cloudflare ever emitted one.
func TestVerifyAcceptsAScalarAudience(t *testing.T) {
	now := time.Now()
	claims := validClaims(now)
	claims["aud"] = testAud
	tok := signToken(t, testKey, validHeader(), claims)

	if _, err := verify(tok, staticKeys{testKid: &testKey.PublicKey}, testIssuer, testAud, now); err != nil {
		t.Fatalf("scalar aud was rejected: %v", err)
	}
}

// The table below is the substance of this service. Each case is a way a request
// can arrive without a legitimate Access assertion; every one of them must be an
// error, because the caller turns any error into a 403 and nothing else does.
func TestVerifyRejects(t *testing.T) {
	now := time.Now()
	otherKey := mustKey()

	cases := []struct {
		name  string
		token func() string
	}{
		{
			name: "a token for another application's audience",
			token: func() string {
				c := validClaims(now)
				c["aud"] = []string{"a0d75d29e6b849c4d1557e045c92cd830f060f1ae4370a7ea215fc3e68bce3a2"}
				return signToken(t, testKey, validHeader(), c)
			},
		},
		{
			name: "a token from another team domain",
			token: func() string {
				c := validClaims(now)
				c["iss"] = "https://someone-else.cloudflareaccess.com"
				return signToken(t, testKey, validHeader(), c)
			},
		},
		{
			name: "an expired token",
			token: func() string {
				c := validClaims(now)
				c["exp"] = now.Add(-2 * time.Hour).Unix()
				return signToken(t, testKey, validHeader(), c)
			},
		},
		{
			name: "a token with no exp at all",
			token: func() string {
				c := validClaims(now)
				delete(c, "exp")
				return signToken(t, testKey, validHeader(), c)
			},
		},
		{
			name: "a token that is not valid yet",
			token: func() string {
				c := validClaims(now)
				c["nbf"] = now.Add(time.Hour).Unix()
				return signToken(t, testKey, validHeader(), c)
			},
		},
		{
			name: "a token issued in the future",
			token: func() string {
				c := validClaims(now)
				c["iat"] = now.Add(time.Hour).Unix()
				return signToken(t, testKey, validHeader(), c)
			},
		},
		{
			name: "a token signed by a key we do not trust",
			token: func() string {
				return signToken(t, otherKey, validHeader(), validClaims(now))
			},
		},
		{
			name: "a token naming a kid we have never seen",
			token: func() string {
				h := validHeader()
				h["kid"] = "rotated-away"
				return signToken(t, testKey, h, validClaims(now))
			},
		},
		{
			name: "a token with no kid to select a key with",
			token: func() string {
				h := validHeader()
				delete(h, "kid")
				return signToken(t, testKey, h, validClaims(now))
			},
		},
		{
			// The classic: strip the signature and claim there never was one.
			name: "an unsigned token claiming alg=none",
			token: func() string {
				h, _ := json.Marshal(map[string]any{"alg": "none", "kid": testKid})
				c, _ := json.Marshal(validClaims(now))
				return b64(h) + "." + b64(c) + "."
			},
		},
		{
			// The other classic: algorithm confusion. A verifier that dispatches
			// on the header's alg would treat the PUBLIC key as an HMAC secret.
			name: "a token claiming HS256 to force symmetric verification",
			token: func() string {
				h := validHeader()
				h["alg"] = "HS256"
				return signToken(t, testKey, h, validClaims(now))
			},
		},
		{
			name: "a token whose payload was edited after signing",
			token: func() string {
				parts := splitThree(signToken(t, testKey, validHeader(), validClaims(now)))
				forged, _ := json.Marshal(map[string]any{
					"iss": testIssuer, "aud": []string{testAud},
					"exp": now.Add(time.Hour).Unix(), "email": "attacker@example.com",
				})
				return parts[0] + "." + b64(forged) + "." + parts[2]
			},
		},
		{
			name:  "something that is not a JWT at all",
			token: func() string { return "not-a-token" },
		},
		{
			name:  "an empty string",
			token: func() string { return "" },
		},
		{
			name: "a token with base64 padding, which RFC 7515 forbids",
			token: func() string {
				h, _ := json.Marshal(validHeader())
				c, _ := json.Marshal(validClaims(now))
				return base64.URLEncoding.EncodeToString(h) + "." + base64.URLEncoding.EncodeToString(c) + ".AAAA"
			},
		},
	}

	keys := staticKeys{testKid: &testKey.PublicKey}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, err := verify(tc.token(), keys, testIssuer, testAud, now)
			if err == nil {
				t.Fatal("accepted — this is a bypass")
			}
			// Logged so `go test -v` shows WHY each case was refused. A table of
			// rejections all failing for the same shallow reason ("not a JWT")
			// would pass while testing almost nothing.
			t.Logf("rejected: %v", err)
		})
	}
}

func splitThree(tok string) [3]string {
	var out [3]string
	i, start := 0, 0
	for j := 0; j < len(tok) && i < 3; j++ {
		if tok[j] == '.' {
			out[i] = tok[start:j]
			i++
			start = j + 1
		}
	}
	if i < 3 {
		out[i] = tok[start:]
	}
	return out
}

// A token that is minutes past expiry must fail even though a small leeway
// exists — the leeway is for clock skew, not for grace.
func TestVerifyLeewayIsNarrow(t *testing.T) {
	now := time.Now()
	keys := staticKeys{testKid: &testKey.PublicKey}

	c := validClaims(now)
	c["exp"] = now.Add(-30 * time.Second).Unix()
	if _, err := verify(signToken(t, testKey, validHeader(), c), keys, testIssuer, testAud, now); err != nil {
		t.Fatalf("a token 30s past expiry should still pass within the %s leeway: %v", leeway, err)
	}

	c["exp"] = now.Add(-5 * time.Minute).Unix()
	if _, err := verify(signToken(t, testKey, validHeader(), c), keys, testIssuer, testAud, now); err == nil {
		t.Fatal("a token 5 minutes past expiry was accepted")
	}
}

// ---------------------------------------------------------------------------
// The guard's own decisions: host mapping and the missing-header case, which
// never reach verify() at all.
// ---------------------------------------------------------------------------

func testGuard(t *testing.T, m mode) *guard {
	t.Helper()
	return &guard{
		cfg: &config{
			issuer:    testIssuer,
			audByHost: map[string]string{"switchyard.zerogravity.industries": testAud},
			mode:      m,
		},
		keys: nil, // set by callers that get as far as signature checking
		log:  slog.New(slog.NewTextHandler(io.Discard, nil)),
	}
}

func TestValidateRejectsBeforeItEverLooksAtAToken(t *testing.T) {
	g := testGuard(t, modeEnforce)
	tok := signToken(t, testKey, validHeader(), validClaims(time.Now()))

	cases := []struct{ name, host, assertion string }{
		{"no forwarded host, i.e. /verify called directly", "", tok},
		{"a host with no AUD registered for it", "wiki.zerogravity.industries", tok},
		{"a mapped host but no assertion header", "switchyard.zerogravity.industries", ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := g.validate(canonicalHost(tc.host), tc.assertion); err == nil {
				t.Fatal("accepted — this is a bypass")
			}
		})
	}
}

func TestCanonicalHost(t *testing.T) {
	cases := map[string]string{
		"switchyard.zerogravity.industries":     "switchyard.zerogravity.industries",
		"Switchyard.ZeroGravity.Industries":     "switchyard.zerogravity.industries",
		"switchyard.zerogravity.industries:443": "switchyard.zerogravity.industries",
		"  switchyard.zerogravity.industries ":  "switchyard.zerogravity.industries",
		"":                                      "",
	}
	for in, want := range cases {
		if got := canonicalHost(in); got != want {
			t.Errorf("canonicalHost(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestParseAudMap(t *testing.T) {
	good, err := parseAudMap(" a.example=aud1,\n b.example=aud2 ")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if good["a.example"] != "aud1" || good["b.example"] != "aud2" {
		t.Fatalf("parsed %v", good)
	}

	// Every one of these must refuse to produce a map. An empty or malformed map
	// that parsed to "no hosts" would start a guard that authorises nothing,
	// which is safe, or — worse, if it ever grew a default — one that authorises
	// everything. Failing at startup is the only unambiguous outcome.
	for _, bad := range []string{"", "   ", "no-equals-sign", "=aud", "host=", "a.example=x,a.example=y"} {
		if _, err := parseAudMap(bad); err == nil {
			t.Errorf("parseAudMap(%q) was accepted", bad)
		}
	}
}

func TestAuditModeAllowsButEnforceDenies(t *testing.T) {
	for _, tc := range []struct {
		m    mode
		want int
	}{{modeEnforce, http.StatusForbidden}, {modeAudit, http.StatusOK}} {
		t.Run(string(tc.m), func(t *testing.T) {
			g := testGuard(t, tc.m)
			req := httptest.NewRequest(http.MethodGet, "/verify", nil)
			req.Header.Set("X-Forwarded-Host", "switchyard.zerogravity.industries")
			rec := httptest.NewRecorder()

			g.handleVerify(rec, req) // no assertion header at all

			if rec.Code != tc.want {
				t.Fatalf("status = %d, want %d", rec.Code, tc.want)
			}
		})
	}
}

// ---------------------------------------------------------------------------
// The JWKS cache, against a fake certs endpoint. This is the seam where a real
// deployment fails first — a key set that parses wrong is indistinguishable from
// a bad signature at the point of use.
// ---------------------------------------------------------------------------

func jwksBody(t *testing.T, pub *rsa.PublicKey, kid string) []byte {
	t.Helper()
	body, err := json.Marshal(map[string]any{"keys": []map[string]any{{
		"kid": kid, "kty": "RSA", "alg": "RS256", "use": "sig",
		"n": b64(pub.N.Bytes()),
		"e": b64(big.NewInt(int64(pub.E)).Bytes()),
	}}})
	if err != nil {
		t.Fatal(err)
	}
	return body
}

func TestJWKSCacheFetchesAndVerifies(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write(jwksBody(t, &testKey.PublicKey, testKid))
	}))
	defer srv.Close()

	c := newJWKSCache("ignored", time.Hour, slog.New(slog.NewTextHandler(io.Discard, nil)))
	c.url = srv.URL
	if err := c.refresh(); err != nil {
		t.Fatalf("refresh: %v", err)
	}

	// The round trip that matters: a key reconstructed from n/e must verify a
	// signature made by the private half.
	tok := signToken(t, testKey, validHeader(), validClaims(time.Now()))
	if _, err := verify(tok, c, testIssuer, testAud, time.Now()); err != nil {
		t.Fatalf("token did not verify against the fetched key: %v", err)
	}
}

func TestJWKSCacheFailsClosedAndVisibly(t *testing.T) {
	log := slog.New(slog.NewTextHandler(io.Discard, nil))

	t.Run("an empty cache authorises nothing and reports unhealthy", func(t *testing.T) {
		c := newJWKSCache("ignored", time.Hour, log)
		if _, err := c.key(testKid); err == nil {
			t.Fatal("an empty cache returned a key")
		}
		if ok, _ := c.health(); ok {
			t.Fatal("an empty cache reported healthy — the probe cannot fail")
		}
	})

	t.Run("a failing endpoint keeps the keys it already had", func(t *testing.T) {
		fail := false
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if fail {
				w.WriteHeader(http.StatusInternalServerError)
				return
			}
			w.Write(jwksBody(t, &testKey.PublicKey, testKid))
		}))
		defer srv.Close()

		c := newJWKSCache("ignored", time.Hour, log)
		c.url = srv.URL
		if err := c.refresh(); err != nil {
			t.Fatal(err)
		}
		fail = true
		if err := c.refresh(); err == nil {
			t.Fatal("a 500 from the certs endpoint was reported as success")
		}
		if c.count() != 1 {
			t.Fatal("a failed refresh discarded a working key set — a Cloudflare blip would black out the estate")
		}
	})

	t.Run("stale keys report unhealthy", func(t *testing.T) {
		c := newJWKSCache("ignored", time.Minute, log)
		c.keys = map[string]*rsa.PublicKey{testKid: &testKey.PublicKey}
		c.lastOK = time.Now().Add(-time.Hour)
		if ok, detail := c.health(); ok {
			t.Fatalf("an hour-stale key set reported healthy: %s", detail)
		}
	})

	t.Run("a response with no usable keys is a failure, not an empty success", func(t *testing.T) {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			io.WriteString(w, `{"keys":[]}`)
		}))
		defer srv.Close()
		c := newJWKSCache("ignored", time.Hour, log)
		c.url = srv.URL
		if err := c.refresh(); err == nil {
			t.Fatal("an empty key set was accepted")
		}
	})

	t.Run("an undersized modulus is refused", func(t *testing.T) {
		small, err := rsa.GenerateKey(rand.Reader, 1024)
		if err != nil {
			t.Fatal(err)
		}
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Write(jwksBody(t, &small.PublicKey, testKid))
		}))
		defer srv.Close()
		c := newJWKSCache("ignored", time.Hour, log)
		c.url = srv.URL
		if err := c.refresh(); err == nil {
			t.Fatal("a 1024-bit signing key was accepted")
		}
	})
}
