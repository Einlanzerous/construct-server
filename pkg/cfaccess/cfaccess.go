package cfaccess

import (
	"context"
	"crypto"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"sync"
	"time"
)

// Defaults. Every one of these is overridable through Config; they are chosen so
// that the zero-value-plus-TeamDomain-and-Audience case is the correct one.
const (
	// DefaultRefreshInterval is how often Run refetches the key set. Cloudflare
	// rotates Access signing keys on a scale of weeks, so this is a backstop —
	// the mechanism that actually catches a rotation promptly is the unknown-kid
	// path in Verify, which refreshes on demand.
	DefaultRefreshInterval = time.Hour

	// DefaultRefreshCooldown is the minimum gap between key-set fetches TRIGGERED
	// BY A TOKEN. Without it a caller sending random `kid` values turns any
	// consumer into a request amplifier pointed at Cloudflare: one unauthenticated
	// request in, one JWKS fetch out.
	DefaultRefreshCooldown = time.Minute

	// DefaultLeeway is the clock-skew tolerance. The origin and Cloudflare's edge
	// are independently synced, and a token one second "not yet valid" is a clock
	// problem rather than an attack. Kept small on purpose: this is also the
	// window in which an expired token still passes.
	DefaultLeeway = time.Minute

	// DefaultFetchTimeout bounds one call to the certs endpoint.
	DefaultFetchTimeout = 10 * time.Second

	// defaultStaleMultiple is how many missed refresh intervals make Health
	// unhealthy. Two consecutive failures are a blip; several hours of them mean
	// the keys in memory may no longer be the ones Cloudflare signs with, and
	// every request is about to start failing.
	defaultStaleMultiple = 3
)

// Config builds a Verifier. TeamDomain is the only required field.
type Config struct {
	// TeamDomain is the Cloudflare Zero Trust team domain, e.g.
	// "example.cloudflareaccess.com". A full URL is accepted and reduced to the
	// host, so pasting the value straight out of the dashboard cannot produce an
	// issuer of "https://https://…" that mismatches every token.
	TeamDomain string

	// Audience is the set of Access application AUD tags Verify accepts.
	//
	// A LIST, not a string, because AUD tags are per-application and services
	// grow second applications — Switchyard reached this shape the hard way at
	// SWY-260 and Chronicle needed it for CHRN-65. An empty list is legal only
	// for a caller that exclusively uses VerifyAudience (cf-access-guard, which
	// picks the audience per request from its host map); Verify itself then fails
	// closed with ErrNoAudienceConfigured.
	Audience []string

	// RequireEmail rejects an assertion with no email claim. Services that mint a
	// session from the verified identity want it; a gate that only decides
	// pass/fail does not.
	RequireEmail bool

	// HTTPClient fetches the key set. Injectable so tests never reach Cloudflare:
	// give it a Transport that serves a JWKS and the whole verifier is offline.
	// That is the supported test seam, and it is why the certs URL itself is NOT
	// configurable — "verified by Cloudflare Access" should not be something a
	// deployment can repoint. Defaults to a client with DefaultFetchTimeout.
	HTTPClient *http.Client

	// Now is the clock. Injectable so expiry tests do not sleep. Defaults to
	// time.Now.
	Now func() time.Time

	// Logger records refresh outcomes. Defaults to discarding them; verification
	// failures are never logged here, because only the caller knows what of a
	// rejected request is safe to record.
	Logger *slog.Logger

	// RefreshInterval is Run's ticker period. Defaults to
	// DefaultRefreshInterval. Ignored by a consumer that never calls Run, except
	// as the basis for MaxKeyAge and StaleAfter.
	RefreshInterval time.Duration

	// MaxKeyAge is how old a cached key may be before Verify refreshes ahead of
	// using it. Defaults to RefreshInterval, which makes a lazy consumer behave
	// like a ticking one without owning a goroutine.
	MaxKeyAge time.Duration

	// RefreshCooldown is the amplification brake described at
	// DefaultRefreshCooldown. It gates token-triggered refreshes only: an
	// explicit Refresh, and Run's ticker, are never throttled.
	RefreshCooldown time.Duration

	// StaleAfter is how far past the last SUCCESSFUL fetch Health reports
	// unhealthy. Defaults to three RefreshIntervals. It applies only while Run is
	// active — see Health.
	StaleAfter time.Duration

	// Leeway is the clock-skew tolerance on exp/nbf/iat. Defaults to
	// DefaultLeeway.
	Leeway time.Duration

	// FetchTimeout bounds one token-triggered key-set fetch. It exists because
	// that fetch deliberately does NOT inherit the caller's cancellation (see
	// Verify), so it needs a deadline of its own rather than the caller's.
	// Defaults to DefaultFetchTimeout.
	FetchTimeout time.Duration

	// certsURL overrides the endpoint. Test seam only; there is no reason for a
	// real consumer to point this anywhere but Cloudflare, and making it public
	// would make "verified by Cloudflare Access" configurable.
	certsURL string
}

// Verifier verifies Cloudflare Access assertions for one team domain. It is safe
// for concurrent use. Build it with New; the zero value is not usable.
type Verifier struct {
	issuer   string
	certsURL string
	audience []string

	requireEmail    bool
	client          *http.Client
	now             func() time.Time
	log             *slog.Logger
	refreshInterval time.Duration
	maxKeyAge       time.Duration
	cooldown        time.Duration
	staleAfter      time.Duration
	leeway          time.Duration
	fetchTimeout    time.Duration

	// fetchMu serialises key-set fetches, so a burst of unknown-kid requests
	// produces one HTTP call rather than one each. Held across the request; the
	// cooldown re-check after acquiring it is what makes the waiters no-ops.
	fetchMu sync.Mutex

	mu          sync.RWMutex
	keys        map[string]*rsa.PublicKey
	skipped     []string
	lastSuccess time.Time
	lastAttempt time.Time
	lastErr     error
	running     bool
}

// errCooling means a refresh was SKIPPED by the cooldown, not that it failed.
// The caller has no new key either way, but keeping them distinct stops a
// skipped refresh being logged as an outage.
var errCooling = errors.New("cfaccess: key refresh is cooling down")

// NormalizeTeamDomain reduces a team domain to a bare host.
func NormalizeTeamDomain(v string) string {
	v = strings.TrimSpace(v)
	v = strings.TrimPrefix(strings.TrimPrefix(v, "https://"), "http://")
	return strings.TrimSuffix(v, "/")
}

// New builds a Verifier. It does no network I/O, so construction cannot fail on
// Cloudflare being unreachable and a consumer's boot does not depend on it.
func New(cfg Config) (*Verifier, error) {
	team := NormalizeTeamDomain(cfg.TeamDomain)
	if team == "" {
		return nil, errors.New("cfaccess: TeamDomain is unset or empty")
	}

	aud := make([]string, 0, len(cfg.Audience))
	for _, a := range cfg.Audience {
		if a = strings.TrimSpace(a); a != "" {
			aud = append(aud, a)
		}
	}

	v := &Verifier{
		issuer:          "https://" + team,
		certsURL:        cfg.certsURL,
		audience:        aud,
		requireEmail:    cfg.RequireEmail,
		client:          cfg.HTTPClient,
		now:             cfg.Now,
		log:             cfg.Logger,
		refreshInterval: cfg.RefreshInterval,
		maxKeyAge:       cfg.MaxKeyAge,
		cooldown:        cfg.RefreshCooldown,
		staleAfter:      cfg.StaleAfter,
		leeway:          cfg.Leeway,
		fetchTimeout:    cfg.FetchTimeout,
		keys:            map[string]*rsa.PublicKey{},
	}

	if v.certsURL == "" {
		v.certsURL = "https://" + team + "/cdn-cgi/access/certs"
	}
	if v.client == nil {
		v.client = &http.Client{Timeout: DefaultFetchTimeout}
	}
	if v.now == nil {
		v.now = time.Now
	}
	if v.log == nil {
		v.log = slog.New(slog.NewTextHandler(io.Discard, nil))
	}
	if v.refreshInterval <= 0 {
		v.refreshInterval = DefaultRefreshInterval
	}
	if v.maxKeyAge <= 0 {
		v.maxKeyAge = v.refreshInterval
	}
	if v.cooldown <= 0 {
		v.cooldown = DefaultRefreshCooldown
	}
	if v.staleAfter <= 0 {
		v.staleAfter = defaultStaleMultiple * v.refreshInterval
	}
	if v.leeway <= 0 {
		v.leeway = DefaultLeeway
	}
	if v.fetchTimeout <= 0 {
		v.fetchTimeout = DefaultFetchTimeout
	}
	return v, nil
}

// Issuer is the issuer every assertion must carry, derived from the team domain.
func (v *Verifier) Issuer() string { return v.issuer }

// Verify checks an assertion against the audiences the Verifier was built with.
func (v *Verifier) Verify(ctx context.Context, token string) (*Claims, error) {
	return v.VerifyAudience(ctx, token, v.audience...)
}

// VerifyAudience checks an assertion against an explicitly supplied audience
// set, ignoring the configured one.
//
// This exists for cf-access-guard, which picks the required AUD per request from
// its host map — a token minted for the wiki must not open Switchyard just
// because both are behind the same guard. The audience check stays INSIDE this
// package either way: an API that returned the claims and left the caller to
// compare audiences would be one forgotten line away from accepting everything.
//
// Passing no audience is an error, never "any audience will do".
func (v *Verifier) VerifyAudience(ctx context.Context, token string, audiences ...string) (*Claims, error) {
	want := make([]string, 0, len(audiences))
	for _, a := range audiences {
		if a = strings.TrimSpace(a); a != "" {
			want = append(want, a)
		}
	}
	if len(want) == 0 {
		return nil, ErrNoAudienceConfigured
	}

	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return nil, fmt.Errorf("%w: got %d segments, want 3", ErrMalformed, len(parts))
	}

	headerBytes, err := decodeSegment(parts[0])
	if err != nil {
		return nil, fmt.Errorf("%w: header: %v", ErrMalformed, err)
	}
	var header joseHeader
	if err := json.Unmarshal(headerBytes, &header); err != nil {
		return nil, fmt.Errorf("%w: header is not JSON: %v", ErrMalformed, err)
	}
	// Before any key lookup, and not a switch on header.Alg: see
	// ErrUnsupportedAlgorithm. `none` and an HS256 replay of the public key are
	// unreachable rather than handled.
	if header.Alg != signingAlg {
		return nil, fmt.Errorf("%w: %q, only %s is accepted", ErrUnsupportedAlgorithm, header.Alg, signingAlg)
	}
	if header.Kid == "" {
		return nil, fmt.Errorf("%w: header carries no kid, so no key can be selected", ErrMalformed)
	}

	pub, err := v.key(ctx, header.Kid)
	if err != nil {
		return nil, err
	}

	sig, err := decodeSegment(parts[2])
	if err != nil {
		return nil, fmt.Errorf("%w: signature: %v", ErrMalformed, err)
	}
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	if err := rsa.VerifyPKCS1v15(pub, crypto.SHA256, digest[:], sig); err != nil {
		return nil, fmt.Errorf("%w against kid %q", ErrSignature, header.Kid)
	}

	// Only now are the claims worth reading. Until the signature checks out they
	// are attacker-supplied text, which is why this is not hoisted above the
	// verification for tidiness.
	payloadBytes, err := decodeSegment(parts[1])
	if err != nil {
		return nil, fmt.Errorf("%w: payload: %v", ErrMalformed, err)
	}
	var claims accessClaims
	if err := json.Unmarshal(payloadBytes, &claims); err != nil {
		return nil, fmt.Errorf("%w: payload is not JSON: %v", ErrMalformed, err)
	}

	if claims.Iss != v.issuer {
		return nil, fmt.Errorf("%w: %q is not %q", ErrIssuer, claims.Iss, v.issuer)
	}
	if !claims.Aud.intersects(want) {
		return nil, fmt.Errorf("%w: %v does not include any accepted audience", ErrAudience, []string(claims.Aud))
	}

	now := v.now()
	// Each claim is required rather than validated-if-present. An absent exp must
	// not read as "never expires" — that is the shape of a check that silently
	// passes.
	if claims.Exp == 0 {
		return nil, fmt.Errorf("%w: no exp claim, and a token with no expiry is not accepted", ErrExpired)
	}
	exp := time.Unix(claims.Exp, 0)
	if now.After(exp.Add(v.leeway)) {
		return nil, fmt.Errorf("%w at %s", ErrExpired, exp.UTC().Format(time.RFC3339))
	}
	out := &Claims{
		Email:    claims.Email,
		Subject:  claims.Sub,
		Issuer:   claims.Iss,
		Audience: []string(claims.Aud),
		Expires:  exp,
	}
	if claims.Nbf != 0 {
		out.NotBefore = time.Unix(claims.Nbf, 0)
		if now.Add(v.leeway).Before(out.NotBefore) {
			return nil, fmt.Errorf("%w before %s", ErrNotYetValid, out.NotBefore.UTC().Format(time.RFC3339))
		}
	}
	if claims.Iat != 0 {
		out.IssuedAt = time.Unix(claims.Iat, 0)
		if now.Add(v.leeway).Before(out.IssuedAt) {
			return nil, fmt.Errorf("%w: issued in the future, at %s", ErrNotYetValid, out.IssuedAt.UTC().Format(time.RFC3339))
		}
	}
	if v.requireEmail && out.Email == "" {
		return nil, ErrNoEmail
	}
	return out, nil
}

// key returns the signing key for kid, refreshing when the cached set is older
// than MaxKeyAge or the kid is unknown.
//
// A rotation Cloudflare performed since the last scheduled refresh looks exactly
// like an unknown kid, and it is the one case where refreshing on demand is both
// correct and necessary. A stale-but-present key beats a failed refresh, so a
// transient certs-endpoint outage does not reject a token signed by a key
// already held.
func (v *Verifier) key(ctx context.Context, kid string) (*rsa.PublicKey, error) {
	v.mu.RLock()
	pub, ok := v.keys[kid]
	fresh := !v.lastSuccess.IsZero() && v.now().Sub(v.lastSuccess) < v.maxKeyAge
	v.mu.RUnlock()
	if ok && fresh {
		return pub, nil
	}

	if err := v.refresh(ctx, true); err != nil {
		if ok {
			return pub, nil
		}
		if !errors.Is(err, errCooling) {
			v.log.Warn("cfaccess: refresh triggered by an unknown kid failed", "kid", kid, "err", err)
		}
	}

	v.mu.RLock()
	pub, ok = v.keys[kid]
	n := len(v.keys)
	v.mu.RUnlock()
	if ok {
		return pub, nil
	}
	// Reported AFTER the refresh, not before it: "we hold no keys at all" and
	// "we hold keys and yours is not one" are different operational problems.
	if n == 0 {
		return nil, ErrNoKeys
	}
	return nil, fmt.Errorf("%w: kid %q is not among the %d keys published by Cloudflare Access", ErrUnknownKey, kid, n)
}

// Refresh fetches the key set now and swaps it in.
//
// It is NOT subject to the cooldown: an explicit refresh is an operator or
// startup action, not a token-driven one, and the cooldown exists to stop
// untrusted input driving fetches. A daemon calls this once before serving, so a
// hard startup failure reads as a startup failure rather than as the first
// request getting a 403.
//
// A failed refresh leaves the previous key set in place. Replacing a working set
// with nothing would turn a Cloudflare blip into a total outage.
//
// Unlike the token-triggered path, this one DOES honour ctx cancellation: an
// explicit Refresh is the caller's own call, and Run needs it to stop on
// shutdown.
func (v *Verifier) Refresh(ctx context.Context) error {
	return v.refresh(ctx, false)
}

func (v *Verifier) refresh(ctx context.Context, throttled bool) error {
	v.fetchMu.Lock()
	defer v.fetchMu.Unlock()

	if throttled {
		// A token-triggered fetch populates a PROCESS-WIDE cache, so it must not
		// inherit one caller's cancellation.
		//
		// Without this, a client that disconnects mid-fetch aborts the fetch while
		// leaving lastAttempt stamped, and every other caller is then refused for a
		// full cooldown having never reached Cloudflare. Two ways that bites on the
		// auth path: a cold start (the initial Refresh is non-fatal by design, so
		// the first request is what loads the keys), and a key rotation, where the
		// unknown-kid path is the only prompt pickup — one request-then-abort per
		// minute suppresses either until the hourly ticker fires. It is also a
		// regression from the code this replaced, which fetched with a plain
		// client.Get that no caller could cancel.
		//
		// Not-stamping-on-ctx.Err would fix the symptom and reopen the hole the
		// cooldown exists for: an attacker's cancelled request would once again be
		// one inbound request producing one outbound fetch. Detaching keeps both
		// properties, and the cancelled caller's fetch still populates the cache
		// for everyone else.
		//
		// WithoutCancel keeps context values (traces, deadline plumbing) and
		// drops only cancellation; FetchTimeout supplies the deadline the caller's
		// context is no longer providing.
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(context.WithoutCancel(ctx), v.fetchTimeout)
		defer cancel()
	}

	// Re-checked after acquiring fetchMu, not before: that is what turns a burst
	// of concurrent unknown-kid requests into one fetch plus N no-ops instead of
	// one fetch plus N queued fetches.
	if throttled {
		v.mu.RLock()
		cooling := !v.lastAttempt.IsZero() && v.now().Sub(v.lastAttempt) < v.cooldown
		v.mu.RUnlock()
		if cooling {
			return errCooling
		}
	}

	v.mu.Lock()
	// Stamped for the ATTEMPT, before the fetch, and unconditionally. Gating this
	// on already holding keys — as Lyceum's copy did — makes the cooldown inert in
	// precisely the two situations it exists for: a cold start, and a certs
	// endpoint that is failing. In both, the key set stays empty, so every single
	// request fetches again.
	v.lastAttempt = v.now()
	v.mu.Unlock()

	set, err := fetchKeys(ctx, v.client, v.certsURL)

	v.mu.Lock()
	defer v.mu.Unlock()
	v.lastErr = err
	if err != nil {
		return err
	}
	v.keys = set.keys
	v.skipped = set.skipped
	v.lastSuccess = v.now()
	return nil
}

// Run refreshes the key set on a ticker until ctx is cancelled, and marks the
// Verifier as actively refreshed so Health can judge staleness. It blocks;
// callers run it in a goroutine.
//
// A library inside an app simply never calls this — keys are then fetched lazily
// on first use and refreshed on demand, with no goroutine to own.
//
// Deliberately does NOT do an initial fetch: a daemon should call Refresh
// synchronously first so a startup failure is visible as one.
func (v *Verifier) Run(ctx context.Context) {
	v.mu.Lock()
	v.running = true
	v.mu.Unlock()
	defer func() {
		v.mu.Lock()
		v.running = false
		v.mu.Unlock()
	}()

	t := time.NewTicker(v.refreshInterval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			if err := v.Refresh(ctx); err != nil {
				v.log.Error("cfaccess: scheduled refresh failed, keeping the previous key set",
					"url", v.certsURL, "err", err)
				continue
			}
			h := v.Health()
			v.log.Info("cfaccess: keys refreshed", "keys", h.Keys, "skipped", len(h.Skipped))
		}
	}
}

// Health is what a container healthcheck reads.
type Health struct {
	// OK is false whenever this Verifier cannot be trusted to answer.
	OK bool
	// Keys is how many usable signing keys are held.
	Keys int
	// Skipped names the keys the last successful fetch could not use, and why.
	// Empty is the normal case; a non-empty one is worth reading before it
	// becomes a zero-key fetch.
	Skipped []string
	// LastSuccess and LastAttempt are zero before the first of each.
	LastSuccess time.Time
	LastAttempt time.Time
	// Age is how long ago LastSuccess was, measured on the Verifier's own clock
	// so an injected one is honoured. Zero when there has never been a success.
	Age time.Duration
	// Err is the last fetch error, nil after a success.
	Err error
	// Running reports whether a Run ticker is active. Staleness is only judged
	// when it is — see Health on Verifier.
	Running bool
}

// Health reports whether this Verifier can still be trusted to answer.
//
// It has to be able to actually FAIL: a probe that reports healthy no matter
// what is worse than no probe, because it makes the failure invisible (SERV-102,
// where a service sat at a failing streak of 12 while the deploy that caused it
// stayed green).
//
// Staleness is judged ONLY when Run is active. With a ticker, a last success
// older than StaleAfter means the ticker is failing and every request is about
// to start failing with it. Without one, key age means nothing — nobody has
// asked, and the next Verify will refresh — so reporting a quiet lazy consumer
// as unhealthy would be a false alarm on the one signal that must stay
// trustworthy.
func (v *Verifier) Health() Health {
	v.mu.RLock()
	defer v.mu.RUnlock()

	h := Health{
		Keys:        len(v.keys),
		Skipped:     append([]string(nil), v.skipped...),
		LastSuccess: v.lastSuccess,
		LastAttempt: v.lastAttempt,
		Err:         v.lastErr,
		Running:     v.running,
	}
	if !v.lastSuccess.IsZero() {
		h.Age = v.now().Sub(v.lastSuccess)
	}
	if h.Keys == 0 {
		return h
	}
	if h.Running && h.Age > v.staleAfter {
		return h
	}
	h.OK = true
	return h
}

// String is a one-line summary for a healthcheck body or a log field.
func (h Health) String() string {
	var b strings.Builder
	if h.OK {
		b.WriteString("ok")
	} else {
		b.WriteString("UNHEALTHY")
	}
	fmt.Fprintf(&b, " keys=%d", h.Keys)
	if h.LastSuccess.IsZero() {
		b.WriteString(" refreshed=never")
	} else {
		fmt.Fprintf(&b, " refreshed=%s ago", h.Age.Truncate(time.Second))
	}
	if len(h.Skipped) > 0 {
		fmt.Fprintf(&b, " skipped=%d (%s)", len(h.Skipped), strings.Join(h.Skipped, "; "))
	}
	if h.Err != nil {
		fmt.Fprintf(&b, " last_error=%v", h.Err)
	}
	return b.String()
}
