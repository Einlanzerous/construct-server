package main

import (
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"math/big"
	"net/http"
	"sync"
	"time"
)

// How often a kid miss is allowed to trigger an out-of-band refresh. Without
// this, a caller sending random `kid` values turns the guard into a request
// amplifier pointed at Cloudflare — one unauthenticated request in, one JWKS
// fetch out. Cloudflare rotates Access keys on a scale of weeks, so a minute of
// staleness after a genuine rotation costs nothing.
const minRefreshInterval = time.Minute

// staleAfter is how far past the last SUCCESSFUL fetch the guard reports itself
// unhealthy, as a multiple of the refresh interval. Two consecutive failures
// are a blip; several hours of them means the key set in memory may no longer
// be the one Cloudflare is signing with, and every request is about to start
// failing. Saying so through /healthz is what lets assert-healthy.sh catch it
// before a user does.
const staleAfter = 3

// jwksCache holds Cloudflare Access's signing keys in memory.
//
// It fails CLOSED in every direction: an empty cache returns an error for every
// kid, a fetch failure leaves the previous keys in place rather than clearing
// them (a network blip must not lock the estate out), and a kid that is genuinely
// unknown after a refresh is an error rather than a fallback to "any key".
type jwksCache struct {
	url      string
	client   *http.Client
	interval time.Duration
	log      *slog.Logger

	mu      sync.RWMutex
	keys    map[string]*rsa.PublicKey
	lastOK  time.Time
	lastTry time.Time
	lastErr error
}

func newJWKSCache(teamDomain string, interval time.Duration, log *slog.Logger) *jwksCache {
	return &jwksCache{
		url:      "https://" + teamDomain + "/cdn-cgi/access/certs",
		client:   &http.Client{Timeout: 10 * time.Second},
		interval: interval,
		log:      log,
		keys:     map[string]*rsa.PublicKey{},
	}
}

// key returns the public key for a kid, refreshing once if the kid is unknown.
// A rotation Cloudflare performed since the last scheduled refresh looks exactly
// like an unknown kid, and it is the one case where refreshing on demand is both
// correct and necessary.
func (c *jwksCache) key(kid string) (*rsa.PublicKey, error) {
	if pub := c.lookup(kid); pub != nil {
		return pub, nil
	}

	c.mu.RLock()
	stale := time.Since(c.lastTry) > minRefreshInterval
	c.mu.RUnlock()
	if stale {
		if err := c.refresh(); err != nil {
			c.log.Warn("jwks refresh triggered by unknown kid failed", "kid", kid, "err", err)
		}
	}

	if pub := c.lookup(kid); pub != nil {
		return pub, nil
	}
	// Reported after the refresh, not before it: "we hold no keys at all" and
	// "we hold keys and yours is not one" are different operational problems and
	// the log line is the only place anyone will see which one happened.
	if n := c.count(); n == 0 {
		return nil, fmt.Errorf("no signing keys are loaded")
	} else {
		return nil, fmt.Errorf("not among the %d signing keys published by Cloudflare Access", n)
	}
}

func (c *jwksCache) lookup(kid string) *rsa.PublicKey {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.keys[kid]
}

func (c *jwksCache) count() int {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return len(c.keys)
}

// refresh fetches the key set and swaps it in. A fetch that succeeds but yields
// zero usable keys is treated as a failure: replacing a working key set with an
// empty one would turn a Cloudflare-side glitch into a total outage here, and
// "we have no keys" is never a legitimate steady state.
func (c *jwksCache) refresh() error {
	c.mu.Lock()
	c.lastTry = time.Now()
	c.mu.Unlock()

	keys, err := fetchKeys(c.client, c.url)
	if err == nil && len(keys) == 0 {
		err = fmt.Errorf("%s returned no usable RSA keys", c.url)
	}

	c.mu.Lock()
	defer c.mu.Unlock()
	c.lastErr = err
	if err != nil {
		return err
	}
	c.keys = keys
	c.lastOK = time.Now()
	return nil
}

// run refreshes on a schedule until ctx-less shutdown. Deliberately started
// AFTER the first synchronous refresh in main, so a hard startup failure is
// visible in the logs as a startup failure rather than as the first request
// getting a 403.
func (c *jwksCache) run() {
	for range time.Tick(c.interval) {
		if err := c.refresh(); err != nil {
			c.log.Error("scheduled jwks refresh failed, keeping the previous key set", "url", c.url, "err", err)
			continue
		}
		c.log.Info("jwks refreshed", "keys", c.count())
	}
}

// health reports whether the cache can still be trusted to answer. This is what
// the container healthcheck reads, so it has to be able to actually fail —
// a probe that reports healthy no matter what is worse than none, because it
// makes the failure invisible (SERV-102).
func (c *jwksCache) health() (bool, string) {
	c.mu.RLock()
	defer c.mu.RUnlock()

	if len(c.keys) == 0 {
		return false, fmt.Sprintf("no signing keys loaded (last error: %v)", c.lastErr)
	}
	if age := time.Since(c.lastOK); age > time.Duration(staleAfter)*c.interval {
		return false, fmt.Sprintf("signing keys are %s old, last refresh failed: %v", age.Truncate(time.Second), c.lastErr)
	}
	return true, fmt.Sprintf("%d signing keys, refreshed %s ago", len(c.keys), time.Since(c.lastOK).Truncate(time.Second))
}

// jwk is the subset of a JSON Web Key this needs. Non-RSA and non-signing keys
// are skipped rather than rejected: the endpoint is allowed to publish key types
// this guard does not use, and refusing to start over one would be brittle.
type jwk struct {
	Kid string `json:"kid"`
	Kty string `json:"kty"`
	Use string `json:"use"`
	N   string `json:"n"`
	E   string `json:"e"`
}

func fetchKeys(client *http.Client, url string) (map[string]*rsa.PublicKey, error) {
	resp, err := client.Get(url)
	if err != nil {
		return nil, fmt.Errorf("GET %s: %w", url, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("GET %s: HTTP %d", url, resp.StatusCode)
	}

	// Bounded read — this is a remote document parsed on a path that must never
	// be able to exhaust memory.
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, fmt.Errorf("reading %s: %w", url, err)
	}

	var doc struct {
		Keys []jwk `json:"keys"`
	}
	if err := json.Unmarshal(body, &doc); err != nil {
		return nil, fmt.Errorf("parsing %s: %w", url, err)
	}

	out := map[string]*rsa.PublicKey{}
	for _, k := range doc.Keys {
		if k.Kty != "RSA" || k.Kid == "" || (k.Use != "" && k.Use != "sig") {
			continue
		}
		pub, err := rsaKeyFromJWK(k)
		if err != nil {
			return nil, fmt.Errorf("key %q: %w", k.Kid, err)
		}
		out[k.Kid] = pub
	}
	return out, nil
}

func rsaKeyFromJWK(k jwk) (*rsa.PublicKey, error) {
	n, err := base64.RawURLEncoding.DecodeString(k.N)
	if err != nil {
		return nil, fmt.Errorf("modulus is not base64url: %w", err)
	}
	e, err := base64.RawURLEncoding.DecodeString(k.E)
	if err != nil {
		return nil, fmt.Errorf("exponent is not base64url: %w", err)
	}
	if len(e) == 0 || len(e) > 8 {
		return nil, fmt.Errorf("exponent is %d bytes, which is not a usable RSA exponent", len(e))
	}
	// A short RSA modulus is a broken key, not a small one. 2048 bits is what
	// Cloudflare publishes; refusing anything under 2048 means a downgraded key
	// set cannot quietly weaken verification.
	if len(n)*8 < 2048 {
		return nil, fmt.Errorf("modulus is %d bits, below the 2048-bit minimum", len(n)*8)
	}
	return &rsa.PublicKey{
		N: new(big.Int).SetBytes(n),
		E: int(new(big.Int).SetBytes(e).Int64()),
	}, nil
}
