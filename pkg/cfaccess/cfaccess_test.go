package cfaccess

// Tests for the behaviours the shared vectors cannot express: they are a
// stateless "this token, this key set, accept or reject", and most of what went
// wrong across the three copies was stateful — a cooldown that never applied, a
// failed refresh that discarded working keys, a health probe that could not fail.

import (
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"math/big"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

const (
	tIssuerDomain = "unit.cloudflareaccess.test"
	tAud          = "aud-under-test"
	tKid          = "kid-under-test"
)

var tKey = func() *rsa.PrivateKey {
	k, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		panic(err)
	}
	return k
}()

func jwksBytes(t *testing.T, keys ...map[string]any) []byte {
	t.Helper()
	b, err := json.Marshal(map[string]any{"keys": keys})
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func goodJWKS(t *testing.T) []byte {
	t.Helper()
	return jwksBytes(t, map[string]any{
		"kid": tKid, "kty": "RSA", "alg": "RS256", "use": "sig",
		"n": b64(tKey.PublicKey.N.Bytes()),
		"e": b64(big.NewInt(int64(tKey.PublicKey.E)).Bytes()),
	})
}

func token(t *testing.T, claims map[string]any) string {
	t.Helper()
	h, _ := json.Marshal(map[string]any{"alg": "RS256", "kid": tKid, "typ": "JWT"})
	c, err := json.Marshal(claims)
	if err != nil {
		t.Fatal(err)
	}
	signing := b64(h) + "." + b64(c)
	d := sha256.Sum256([]byte(signing))
	sig, err := rsa.SignPKCS1v15(rand.Reader, tKey, crypto.SHA256, d[:])
	if err != nil {
		t.Fatal(err)
	}
	return signing + "." + b64(sig)
}

func claimsAt(now time.Time) map[string]any {
	return map[string]any{
		"iss": "https://" + tIssuerDomain, "aud": []string{tAud},
		"exp": now.Add(time.Hour).Unix(), "iat": now.Unix(), "nbf": now.Unix(),
		"sub": "sub-1", "email": "operator@example.test",
	}
}

// clock is a hand-wound clock, so nothing here sleeps.
type clock struct {
	mu sync.Mutex
	t  time.Time
}

func (c *clock) now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.t
}

func (c *clock) advance(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.t = c.t.Add(d)
}

// certsServer counts requests, which is how the amplification tests observe the
// cooldown at all.
type certsServer struct {
	*httptest.Server
	hits atomic.Int64
	mu   sync.Mutex
	body []byte
	code int
}

func newCertsServer(t *testing.T, body []byte) *certsServer {
	t.Helper()
	cs := &certsServer{body: body, code: http.StatusOK}
	cs.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		cs.hits.Add(1)
		cs.mu.Lock()
		code, body := cs.code, cs.body
		cs.mu.Unlock()
		w.WriteHeader(code)
		_, _ = w.Write(body)
	}))
	t.Cleanup(cs.Close)
	return cs
}

func (cs *certsServer) set(code int, body []byte) {
	cs.mu.Lock()
	defer cs.mu.Unlock()
	cs.code, cs.body = code, body
}

func newTestVerifier(t *testing.T, cs *certsServer, c *clock, mutate func(*Config)) *Verifier {
	t.Helper()
	cfg := Config{
		TeamDomain: tIssuerDomain,
		Audience:   []string{tAud},
		Now:        c.now,
		certsURL:   cs.URL,
	}
	if mutate != nil {
		mutate(&cfg)
	}
	v, err := New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	return v
}

func TestNewRequiresATeamDomain(t *testing.T) {
	for _, in := range []string{"", "   ", "https://"} {
		if _, err := New(Config{TeamDomain: in, Audience: []string{tAud}}); err == nil {
			t.Errorf("TeamDomain %q was accepted; an empty environment variable is not a value", in)
		}
	}
}

func TestNormalizeTeamDomainSurvivesADashboardPaste(t *testing.T) {
	for _, in := range []string{
		tIssuerDomain, "https://" + tIssuerDomain, "http://" + tIssuerDomain,
		"https://" + tIssuerDomain + "/", "  " + tIssuerDomain + "  ",
	} {
		v, err := New(Config{TeamDomain: in, Audience: []string{tAud}})
		if err != nil {
			t.Fatal(err)
		}
		if got, want := v.Issuer(), "https://"+tIssuerDomain; got != want {
			t.Errorf("TeamDomain %q gave issuer %q, want %q", in, got, want)
		}
	}
}

// The single most important negative test in the package: with no audience,
// nothing may be accepted. The opposite reading — "unconfigured means allow" —
// is how a shared verifier becomes an open door for its least careful consumer.
func TestVerifyWithNoAudienceAcceptsNothing(t *testing.T) {
	c := &clock{t: time.Unix(1_700_000_000, 0).UTC()}
	cs := newCertsServer(t, goodJWKS(t))
	v := newTestVerifier(t, cs, c, func(cfg *Config) { cfg.Audience = nil })

	_, err := v.Verify(context.Background(), token(t, claimsAt(c.now())))
	if !errors.Is(err, ErrNoAudienceConfigured) {
		t.Fatalf("err = %v, want ErrNoAudienceConfigured", err)
	}
	if cs.hits.Load() != 0 {
		t.Error("a token was allowed to trigger a key fetch before the audience check")
	}
}

// VerifyAudience is what cf-access-guard uses to hold each host to its own AUD.
// The configured audience must NOT leak into it, or a guard whose config happens
// to list every AUD would accept any of them for any host.
func TestVerifyAudienceIgnoresTheConfiguredAudience(t *testing.T) {
	c := &clock{t: time.Unix(1_700_000_000, 0).UTC()}
	cs := newCertsServer(t, goodJWKS(t))
	v := newTestVerifier(t, cs, c, func(cfg *Config) { cfg.Audience = []string{tAud, "other-app"} })

	tok := token(t, claimsAt(c.now()))
	if _, err := v.VerifyAudience(context.Background(), tok, "other-app"); !errors.Is(err, ErrAudience) {
		t.Fatalf("err = %v, want ErrAudience: a token for one application opened another", err)
	}
	if _, err := v.VerifyAudience(context.Background(), tok, tAud); err != nil {
		t.Fatalf("the matching audience was rejected: %v", err)
	}
	if _, err := v.VerifyAudience(context.Background(), tok); !errors.Is(err, ErrNoAudienceConfigured) {
		t.Fatal("VerifyAudience with no audience did not fail closed")
	}
}

func TestLeewayIsNarrowAndSymmetric(t *testing.T) {
	c := &clock{t: time.Unix(1_700_000_000, 0).UTC()}
	cs := newCertsServer(t, goodJWKS(t))
	v := newTestVerifier(t, cs, c, nil)
	base := c.now()

	// Thirty seconds past expiry: inside the default minute of tolerance.
	tok := token(t, map[string]any{
		"iss": "https://" + tIssuerDomain, "aud": []string{tAud},
		"exp": base.Add(-30 * time.Second).Unix(), "email": "operator@example.test",
	})
	if _, err := v.Verify(context.Background(), tok); err != nil {
		t.Fatalf("a token 30s past expiry was rejected inside a 60s leeway: %v", err)
	}

	// Ten minutes past is not a clock problem.
	tok = token(t, map[string]any{
		"iss": "https://" + tIssuerDomain, "aud": []string{tAud},
		"exp": base.Add(-10 * time.Minute).Unix(), "email": "operator@example.test",
	})
	if _, err := v.Verify(context.Background(), tok); !errors.Is(err, ErrExpired) {
		t.Fatalf("err = %v, want ErrExpired", err)
	}
}

func TestRequireEmailIsOptIn(t *testing.T) {
	c := &clock{t: time.Unix(1_700_000_000, 0).UTC()}
	cs := newCertsServer(t, goodJWKS(t))
	claims := claimsAt(c.now())
	delete(claims, "email")
	tok := token(t, claims)

	gate := newTestVerifier(t, cs, c, nil)
	if _, err := gate.Verify(context.Background(), tok); err != nil {
		t.Fatalf("a pass/fail gate rejected an emailless assertion: %v", err)
	}

	app := newTestVerifier(t, cs, c, func(cfg *Config) { cfg.RequireEmail = true })
	if _, err := app.Verify(context.Background(), tok); !errors.Is(err, ErrNoEmail) {
		t.Fatalf("err = %v, want ErrNoEmail", err)
	}
}

// The regression LYCM-122 would have been caught by. It is a *panic* test as
// much as a rejection test: without the bound this does not fail, it crashes the
// process, and a crashed test binary reads as an infrastructure problem rather
// than as a defect in the code under test.
func TestAnOversizedExponentIsRefusedRatherThanPanicking(t *testing.T) {
	cs := newCertsServer(t, jwksBytes(t, map[string]any{
		"kid": tKid, "kty": "RSA", "use": "sig",
		"n": b64(tKey.PublicKey.N.Bytes()),
		"e": b64([]byte{1, 0, 0, 0, 0, 0, 0, 0, 1}), // nine bytes
	}))
	c := &clock{t: time.Unix(1_700_000_000, 0).UTC()}
	v := newTestVerifier(t, cs, c, nil)

	if err := v.Refresh(context.Background()); err == nil {
		t.Fatal("a key set whose only key has a 9-byte exponent was accepted")
	}
	if _, err := v.Verify(context.Background(), token(t, claimsAt(c.now()))); !errors.Is(err, ErrNoKeys) {
		t.Fatalf("err = %v, want ErrNoKeys", err)
	}
}

func TestOneUnusableKeyDoesNotCondemnTheSet(t *testing.T) {
	weak, err := rsa.GenerateKey(rand.Reader, 1024)
	if err != nil {
		t.Fatal(err)
	}
	cs := newCertsServer(t, jwksBytes(t,
		map[string]any{
			"kid": "weak", "kty": "RSA", "use": "sig",
			"n": b64(weak.PublicKey.N.Bytes()),
			"e": b64(big.NewInt(int64(weak.PublicKey.E)).Bytes()),
		},
		map[string]any{
			"kid": tKid, "kty": "RSA", "use": "sig",
			"n": b64(tKey.PublicKey.N.Bytes()),
			"e": b64(big.NewInt(int64(tKey.PublicKey.E)).Bytes()),
		},
	))
	c := &clock{t: time.Unix(1_700_000_000, 0).UTC()}
	v := newTestVerifier(t, cs, c, nil)

	if err := v.Refresh(context.Background()); err != nil {
		t.Fatalf("one 1024-bit key took the whole set down: %v", err)
	}
	h := v.Health()
	if h.Keys != 1 {
		t.Fatalf("Keys = %d, want 1", h.Keys)
	}
	if len(h.Skipped) != 1 {
		t.Fatalf("Skipped = %v, want the weak key named so it is visible", h.Skipped)
	}
	if _, err := v.Verify(context.Background(), token(t, claimsAt(c.now()))); err != nil {
		t.Fatalf("the usable key did not verify: %v", err)
	}
}

func TestAFailedRefreshKeepsTheKeysItHad(t *testing.T) {
	c := &clock{t: time.Unix(1_700_000_000, 0).UTC()}
	cs := newCertsServer(t, goodJWKS(t))
	v := newTestVerifier(t, cs, c, nil)

	if err := v.Refresh(context.Background()); err != nil {
		t.Fatal(err)
	}
	cs.set(http.StatusInternalServerError, nil)
	if err := v.Refresh(context.Background()); err == nil {
		t.Fatal("a 500 from the certs endpoint was reported as success")
	}
	if v.Health().Keys != 1 {
		t.Fatal("a failed refresh discarded a working key set — a Cloudflare blip would black out the estate")
	}
	if _, err := v.Verify(context.Background(), token(t, claimsAt(c.now()))); err != nil {
		t.Fatalf("a token signed by a key still held was rejected: %v", err)
	}
}

// The cooldown regression that made Lyceum's copy inert. Gating it on already
// holding keys leaves it switched off in exactly the two states it exists for —
// a cold start and a failing certs endpoint — so every unauthenticated request
// becomes one outbound fetch.
func TestTheCooldownAppliesAtAColdStartAndWhileFetchesFail(t *testing.T) {
	t.Run("cold start", func(t *testing.T) {
		c := &clock{t: time.Unix(1_700_000_000, 0).UTC()}
		cs := newCertsServer(t, goodJWKS(t))
		cs.set(http.StatusInternalServerError, nil)
		v := newTestVerifier(t, cs, c, nil)

		for i := 0; i < 20; i++ {
			_, _ = v.Verify(context.Background(), token(t, claimsAt(c.now())))
		}
		if got := cs.hits.Load(); got != 1 {
			t.Fatalf("20 requests against an empty cache made %d fetches, want 1 — this is a request amplifier pointed at Cloudflare", got)
		}
	})

	t.Run("unknown kid burst", func(t *testing.T) {
		c := &clock{t: time.Unix(1_700_000_000, 0).UTC()}
		cs := newCertsServer(t, goodJWKS(t))
		v := newTestVerifier(t, cs, c, nil)
		if err := v.Refresh(context.Background()); err != nil {
			t.Fatal(err)
		}
		// Past the cooldown that Refresh itself just started: an explicit fetch
		// is a fetch, and a token-triggered one a millisecond later is precisely
		// the amplification being blocked.
		c.advance(2 * DefaultRefreshCooldown)
		before := cs.hits.Load()

		unknown := `eyJhbGciOiJSUzI1NiIsImtpZCI6InJhbmRvbSIsInR5cCI6IkpXVCJ9.e30.AAAA`
		for i := 0; i < 20; i++ {
			_, _ = v.Verify(context.Background(), unknown)
		}
		if got := cs.hits.Load() - before; got != 1 {
			t.Fatalf("20 unknown-kid tokens made %d fetches, want 1", got)
		}

		// Past the cooldown, one more is allowed — a genuine rotation must still
		// be picked up promptly.
		c.advance(2 * DefaultRefreshCooldown)
		_, _ = v.Verify(context.Background(), unknown)
		if got := cs.hits.Load() - before; got != 2 {
			t.Fatalf("after the cooldown expired, fetches = %d, want 2", got)
		}
	})
}

// An explicit Refresh is an operator or startup action, not a token-driven one,
// so it is not throttled. A daemon that called Refresh at boot and got a silent
// no-op would serve 403s until its first tick.
func TestExplicitRefreshIsNotThrottled(t *testing.T) {
	c := &clock{t: time.Unix(1_700_000_000, 0).UTC()}
	cs := newCertsServer(t, goodJWKS(t))
	v := newTestVerifier(t, cs, c, nil)

	for i := 0; i < 3; i++ {
		if err := v.Refresh(context.Background()); err != nil {
			t.Fatal(err)
		}
	}
	if got := cs.hits.Load(); got != 3 {
		t.Fatalf("three explicit refreshes made %d fetches, want 3", got)
	}
}

func TestConcurrentUnknownKidsMakeOneFetch(t *testing.T) {
	c := &clock{t: time.Unix(1_700_000_000, 0).UTC()}
	cs := newCertsServer(t, goodJWKS(t))
	v := newTestVerifier(t, cs, c, nil)

	var wg sync.WaitGroup
	for i := 0; i < 32; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, _ = v.Verify(context.Background(), token(t, claimsAt(c.now())))
		}()
	}
	wg.Wait()
	if got := cs.hits.Load(); got != 1 {
		t.Fatalf("32 concurrent cold verifications made %d fetches, want 1", got)
	}
}

// A probe that reports healthy no matter what is worse than no probe, because it
// makes the failure invisible (SERV-102).
func TestHealthCanActuallyFail(t *testing.T) {
	c := &clock{t: time.Unix(1_700_000_000, 0).UTC()}
	cs := newCertsServer(t, goodJWKS(t))

	t.Run("nothing loaded is unhealthy", func(t *testing.T) {
		v := newTestVerifier(t, cs, c, nil)
		h := v.Health()
		if h.OK {
			t.Fatal("a verifier holding no keys reported healthy")
		}
		if h.String() == "" {
			t.Fatal("the health summary is empty, so a healthcheck body says nothing")
		}
	})

	t.Run("a running ticker that has stopped succeeding is unhealthy", func(t *testing.T) {
		v := newTestVerifier(t, cs, c, func(cfg *Config) { cfg.RefreshInterval = time.Minute })
		if err := v.Refresh(context.Background()); err != nil {
			t.Fatal(err)
		}
		if !v.Health().OK {
			t.Fatal("a freshly refreshed verifier reported unhealthy")
		}

		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		go v.Run(ctx)
		waitFor(t, func() bool { return v.Health().Running })

		c.advance(4 * time.Minute) // past 3 * RefreshInterval
		if v.Health().OK {
			t.Fatal("keys four missed intervals old reported healthy — assert-healthy.sh would see nothing")
		}
	})

	t.Run("a lazy verifier is not judged on key age", func(t *testing.T) {
		v := newTestVerifier(t, cs, c, func(cfg *Config) { cfg.RefreshInterval = time.Minute })
		if err := v.Refresh(context.Background()); err != nil {
			t.Fatal(err)
		}
		c.advance(24 * time.Hour)
		if !v.Health().OK {
			t.Fatal("a quiet lazy consumer was reported unhealthy for not having been asked anything")
		}
	})
}

func TestRunRefreshesAndStopsWithItsContext(t *testing.T) {
	c := &clock{t: time.Unix(1_700_000_000, 0).UTC()}
	cs := newCertsServer(t, goodJWKS(t))
	v := newTestVerifier(t, cs, c, func(cfg *Config) { cfg.RefreshInterval = 10 * time.Millisecond })

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { v.Run(ctx); close(done) }()

	waitFor(t, func() bool { return cs.hits.Load() >= 2 })
	cancel()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("Run did not return when its context was cancelled")
	}
	if v.Health().Running {
		t.Fatal("Health still reports a ticker after Run returned")
	}
}

// The key set is remote input on an unauthenticated path, so the read is
// bounded. Without this a hostile or broken certs endpoint is an OOM.
func TestTheKeyDocumentReadIsBounded(t *testing.T) {
	huge := make([]byte, 0, maxJWKSBytes+4096)
	huge = append(huge, []byte(`{"keys":[`)...)
	for len(huge) < maxJWKSBytes+2048 {
		huge = append(huge, []byte(`{"kty":"oct","kid":"pad"},`)...)
	}
	huge = append(huge, []byte(`{"kty":"RSA","kid":"x","n":"AAAA","e":"AQAB"}]}`)...)

	cs := newCertsServer(t, huge)
	c := &clock{t: time.Unix(1_700_000_000, 0).UTC()}
	v := newTestVerifier(t, cs, c, nil)

	// Truncated at the limit, so it no longer parses. Rejecting an oversized
	// document is the point; it must not be read to the end first.
	if err := v.Refresh(context.Background()); err == nil {
		t.Fatal("a key document larger than the read limit was accepted whole")
	}
}

func TestErrorsAreDistinguishableByTheServer(t *testing.T) {
	c := &clock{t: time.Unix(1_700_000_000, 0).UTC()}
	cs := newCertsServer(t, goodJWKS(t))
	v := newTestVerifier(t, cs, c, nil)
	if err := v.Refresh(context.Background()); err != nil {
		t.Fatal(err)
	}

	cases := []struct {
		name  string
		token string
		want  error
	}{
		{"two segments", "a.b", ErrMalformed},
		{"header is not base64url", "!!!.e30.AAAA", ErrMalformed},
		{"alg none", func() string {
			h, _ := json.Marshal(map[string]any{"alg": "none", "kid": tKid})
			cl, _ := json.Marshal(claimsAt(c.now()))
			return b64(h) + "." + b64(cl) + "."
		}(), ErrUnsupportedAlgorithm},
		{"no kid", func() string {
			h, _ := json.Marshal(map[string]any{"alg": "RS256"})
			cl, _ := json.Marshal(claimsAt(c.now()))
			return b64(h) + "." + b64(cl) + ".AAAA"
		}(), ErrMalformed},
		{"wrong issuer", token(t, func() map[string]any {
			m := claimsAt(c.now())
			m["iss"] = "https://elsewhere.cloudflareaccess.test"
			return m
		}()), ErrIssuer},
		{"wrong audience", token(t, func() map[string]any {
			m := claimsAt(c.now())
			m["aud"] = []string{"someone-else"}
			return m
		}()), ErrAudience},
		{"expired", token(t, func() map[string]any {
			m := claimsAt(c.now())
			m["exp"] = c.now().Add(-time.Hour).Unix()
			return m
		}()), ErrExpired},
		{"nbf in the future", token(t, func() map[string]any {
			m := claimsAt(c.now())
			m["nbf"] = c.now().Add(time.Hour).Unix()
			return m
		}()), ErrNotYetValid},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, err := v.Verify(context.Background(), tc.token)
			if !errors.Is(err, tc.want) {
				t.Fatalf("err = %v, want %v", err, tc.want)
			}
			if err.Error() == tc.want.Error() {
				return // no extra detail is fine; a bare sentinel still reads
			}
			if !strings.Contains(err.Error(), tc.want.Error()) {
				t.Errorf("error text %q drops the sentinel's text, so a log line loses the category", err)
			}
		})
	}
}

// waitFor polls a condition. Used only for goroutine start-up, where there is
// nothing to synchronise on that is not the thing being tested.
func waitFor(t *testing.T, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("condition was not met within 2s")
}
