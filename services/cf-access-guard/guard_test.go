package main

// What is left here after SERV-131 is the guard's OWN decisions: the per-host
// AUD map, the forwardAuth contract with Traefik, audit mode, and the config
// that refuses to start permissive.
//
// The verification itself — the alg:none / HMAC-replay / expired / unknown-kid
// bypass table, the JWKS cache, the fail-closed key handling — moved to
// pkg/cfaccess and is tested there, against shared vectors that Switchyard's
// TypeScript suite runs too. Restating any of it here would recreate in the test
// suite exactly the duplication the ticket removed from the source.
//
// The one thing that MUST be tested here and cannot be tested there: that a
// token minted for one tunneled application does not open another. That is the
// whole of what this service adds on top of the module.

import (
	"bytes"
	"context"
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

	"github.com/Einlanzerous/construct-server/pkg/cfaccess"
)

const (
	testTeam       = "zero-gravity-industries.cloudflareaccess.com"
	testIssuer     = "https://" + testTeam
	switchyardHost = "switchyard.zerogravity.industries"
	wikiHost       = "wiki.zerogravity.industries"
	switchyardAud  = "d3404fc362067f48ff1fd6c9a7fc9a1fd723510c2681feed15e35159649963de"
	wikiAud        = "0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0"
	testKid        = "kid-under-test"
)

var testKey = func() *rsa.PrivateKey {
	k, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		panic(err)
	}
	return k
}()

func b64(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

func signToken(t *testing.T, aud string) string {
	t.Helper()
	now := time.Now()
	h, _ := json.Marshal(map[string]any{"alg": "RS256", "kid": testKid, "typ": "JWT"})
	c, err := json.Marshal(map[string]any{
		"iss": testIssuer, "aud": []string{aud},
		"exp": now.Add(time.Hour).Unix(), "iat": now.Unix(), "nbf": now.Unix(),
		"sub": "abc123", "email": "operator@example.com",
	})
	if err != nil {
		t.Fatal(err)
	}
	signing := b64(h) + "." + b64(c)
	d := sha256.Sum256([]byte(signing))
	sig, err := rsa.SignPKCS1v15(rand.Reader, testKey, crypto.SHA256, d[:])
	if err != nil {
		t.Fatal(err)
	}
	return signing + "." + b64(sig)
}

// certsClient stands in for Cloudflare's /cdn-cgi/access/certs.
//
// Injected as an http.Client rather than by pointing the verifier at a test URL:
// pkg/cfaccess deliberately keeps the endpoint unexported, because "verified by
// Cloudflare Access" is not something a deployment should be able to reconfigure.
// A Transport is the seam that costs the production API nothing.
func certsClient(t *testing.T, serve bool) *http.Client {
	t.Helper()
	body, err := json.Marshal(map[string]any{"keys": []map[string]any{{
		"kid": testKid, "kty": "RSA", "alg": "RS256", "use": "sig",
		"n": b64(testKey.PublicKey.N.Bytes()),
		"e": b64(big.NewInt(int64(testKey.PublicKey.E)).Bytes()),
	}}})
	if err != nil {
		t.Fatal(err)
	}
	return &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if !serve {
			return nil, fmt.Errorf("certs endpoint is unreachable")
		}
		return &http.Response{
			StatusCode: http.StatusOK,
			Body:       io.NopCloser(bytes.NewReader(body)),
			Header:     http.Header{"Content-Type": []string{"application/json"}},
			Request:    r,
		}, nil
	})}
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func testGuard(t *testing.T, m mode, withKeys bool) *guard {
	t.Helper()
	g := &guard{
		cfg: &config{
			teamDomain: testTeam,
			audByHost: map[string]string{
				switchyardHost: switchyardAud,
				wikiHost:       wikiAud,
			},
			mode: m,
		},
		log: slog.New(slog.NewTextHandler(io.Discard, nil)),
	}
	// withKeys=false gives a certs endpoint that always fails: the verifier holds
	// no keys, which is the state a guard is in before its first successful
	// refresh and the one it must fail closed from.
	v, err := cfaccess.New(cfaccess.Config{
		TeamDomain: testTeam,
		HTTPClient: certsClient(t, withKeys),
	})
	if err != nil {
		t.Fatal(err)
	}
	if withKeys {
		if err := v.Refresh(context.Background()); err != nil {
			t.Fatal(err)
		}
	}
	g.verifier = v
	return g
}

// The reason this service exists in the shape it does. Every Access application
// on the team domain is signed by the SAME key, so a token for the wiki is a
// perfectly valid Cloudflare assertion — and must still not open Switchyard.
// Nothing in pkg/cfaccess can test this: the per-host map is deliberately the
// guard's, and this is what having it buys.
func TestATokenIsOnlyGoodForItsOwnHost(t *testing.T) {
	g := testGuard(t, modeEnforce, true)
	ctx := context.Background()

	if _, err := g.validate(ctx, switchyardHost, signToken(t, switchyardAud)); err != nil {
		t.Fatalf("a genuine Switchyard token was refused at Switchyard: %v", err)
	}
	if _, err := g.validate(ctx, wikiHost, signToken(t, wikiAud)); err != nil {
		t.Fatalf("a genuine wiki token was refused at the wiki: %v", err)
	}

	// The bypass. Both tokens are real, both are signed by the team's live key,
	// and both are for hosts this guard serves.
	if _, err := g.validate(ctx, switchyardHost, signToken(t, wikiAud)); err == nil {
		t.Fatal("a wiki token opened Switchyard — this is the SERV-106 bypass")
	}
	if _, err := g.validate(ctx, wikiHost, signToken(t, switchyardAud)); err == nil {
		t.Fatal("a Switchyard token opened the wiki")
	}
}

func TestValidateRejectsBeforeItEverLooksAtAToken(t *testing.T) {
	g := testGuard(t, modeEnforce, true)
	tok := signToken(t, switchyardAud)

	cases := []struct{ name, host, assertion string }{
		{"no forwarded host, i.e. /verify called directly", "", tok},
		{"a host with no AUD registered for it", "grafana.zerogravity.industries", tok},
		{"a mapped host but no assertion header", switchyardHost, ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := g.validate(context.Background(), canonicalHost(tc.host), tc.assertion); err == nil {
				t.Fatal("accepted — this is a bypass")
			}
		})
	}
}

// A guard that has never reached Cloudflare must refuse everything rather than
// wave traffic through, and must say so through /healthz — the signal
// assert-healthy.sh reads.
func TestAGuardWithNoKeysFailsClosedAndReportsIt(t *testing.T) {
	g := testGuard(t, modeEnforce, false)

	if _, err := g.validate(context.Background(), switchyardHost, signToken(t, switchyardAud)); err == nil {
		t.Fatal("a guard holding no signing keys authorised a request")
	}

	rec := httptest.NewRecorder()
	g.handleHealth(rec, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("/healthz = %d, want 503 — a probe that cannot fail hides the failure", rec.Code)
	}
	if body := rec.Body.String(); body == "" {
		t.Fatal("/healthz returned an empty body, so an operator learns nothing from it")
	}
}

func TestHealthzIs200WhenKeysAreLoaded(t *testing.T) {
	g := testGuard(t, modeEnforce, true)
	rec := httptest.NewRecorder()
	g.handleHealth(rec, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("/healthz = %d, want 200: %s", rec.Code, rec.Body.String())
	}
}

func TestCanonicalHost(t *testing.T) {
	cases := map[string]string{
		switchyardHost:                          switchyardHost,
		"Switchyard.ZeroGravity.Industries":     switchyardHost,
		"switchyard.zerogravity.industries:443": switchyardHost,
		"  switchyard.zerogravity.industries ":  switchyardHost,
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
			g := testGuard(t, tc.m, true)
			req := httptest.NewRequest(http.MethodGet, "/verify", nil)
			req.Header.Set("X-Forwarded-Host", switchyardHost)
			rec := httptest.NewRecorder()

			g.handleVerify(rec, req) // no assertion header at all

			if rec.Code != tc.want {
				t.Fatalf("status = %d, want %d", rec.Code, tc.want)
			}
		})
	}
}

// loadConfig refuses to start rather than starting permissive. An empty
// environment variable is not a value (CLAUDE.md).
func TestLoadConfigRefusesAnUnusableEnvironment(t *testing.T) {
	cases := []struct {
		name string
		env  map[string]string
	}{
		{"no team domain", map[string]string{"CF_ACCESS_AUD_MAP": "a.example=aud"}},
		{"a team domain that is only a scheme", map[string]string{
			"CF_ACCESS_TEAM_DOMAIN": "https://", "CF_ACCESS_AUD_MAP": "a.example=aud"}},
		{"no aud map", map[string]string{"CF_ACCESS_TEAM_DOMAIN": testTeam}},
		{"an unparseable refresh interval", map[string]string{
			"CF_ACCESS_TEAM_DOMAIN": testTeam, "CF_ACCESS_AUD_MAP": "a.example=aud",
			"CF_ACCESS_JWKS_REFRESH": "soon"}},
		{"a refresh interval below the floor", map[string]string{
			"CF_ACCESS_TEAM_DOMAIN": testTeam, "CF_ACCESS_AUD_MAP": "a.example=aud",
			"CF_ACCESS_JWKS_REFRESH": "1s"}},
		{"a mode that is neither enforce nor audit", map[string]string{
			"CF_ACCESS_TEAM_DOMAIN": testTeam, "CF_ACCESS_AUD_MAP": "a.example=aud",
			"CF_ACCESS_GUARD_MODE": "enfroce"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			for k, v := range tc.env {
				t.Setenv(k, v)
			}
			if _, err := loadConfig(); err == nil {
				t.Fatal("accepted — the guard would have started on this")
			}
		})
	}
}

func TestLoadConfigNormalisesADashboardPaste(t *testing.T) {
	t.Setenv("CF_ACCESS_TEAM_DOMAIN", "https://"+testTeam+"/")
	t.Setenv("CF_ACCESS_AUD_MAP", switchyardHost+"="+switchyardAud)
	cfg, err := loadConfig()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.teamDomain != testTeam {
		t.Fatalf("teamDomain = %q, want %q", cfg.teamDomain, testTeam)
	}
	v, err := cfaccess.New(cfaccess.Config{TeamDomain: cfg.teamDomain})
	if err != nil {
		t.Fatal(err)
	}
	if v.Issuer() != testIssuer {
		t.Fatalf("issuer = %q, want %q", v.Issuer(), testIssuer)
	}
}
