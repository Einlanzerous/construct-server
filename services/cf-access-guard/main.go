// cf-access-guard — origin-side validation of Cloudflare Access JWTs (SERV-106).
//
// # What this closes
//
// Cloudflare Access is enforced at Cloudflare's EDGE. The origin used to check
// nothing, so anything that could open a TCP connection to Traefik's `internal`
// entrypoint got the tunneled apps by setting a Host header:
//
//	curl -H "Host: switchyard.zerogravity.industries" http://traefik:9080/   -> 200
//
// unauthenticated production Switchyard. SERV-107 made that connection harder to
// obtain (the entrypoint binds one address on construct_edge_net, which only
// cloudflared shares) but it authenticates nothing — the request is unroutable,
// not rejected, and anything with host access or the docker socket still reaches
// it. This service is the other half: Traefik forwards every request on that
// entrypoint here first, and a request without a valid, correctly-audienced
// Access assertion never reaches a backend.
//
// # Shape
//
// A Traefik `forwardAuth` target. Traefik sends the request's headers (never its
// body) to /verify; 2xx lets the request through, anything else is returned to
// the client verbatim. Two properties make that safe to rely on:
//
//   - Traefik sets X-Forwarded-Host itself when `trustForwardHeader` is false,
//     from the same Host the router matched on. That is what makes it sound to
//     pick the expected AUD from it — a spoofed Host routes to Switchyard AND is
//     held to Switchyard's audience.
//   - Every path out of validate() that is not a fully verified token returns an
//     error, and every error is a 403. There is no "allow on doubt" branch.
//
// # Deliberate non-features
//
// It adds NO headers to the requests it approves. Switchyard and Lyceum already
// validate the same assertion themselves for SSO sign-in (SWY-161, LYCM-803);
// handing them a guard-asserted identity header would create a second, weaker
// path to the same trust decision — exactly the spoofable-identity-header shape
// that strip-identity-headers exists to prevent.
//
// It reads the assertion from the Cf-Access-Jwt-Assertion header only, not from
// the CF_Authorization cookie. Cloudflare injects the header on every proxied
// request to an Access-protected app, so the cookie adds no reachable case.
//
// # Where the verification itself lives
//
// Not here any more. JWT parsing, the JWKS cache and every claim check moved to
// pkg/cfaccess (SERV-131), which Lyceum and Chronicle also import — three
// hand-rolled copies of this code had already drifted far enough apart that one
// of them panicked on a malformed key (LYCM-122) while this one did not.
//
// What stays is everything the shared module deliberately refuses to know: the
// per-host AUD map, audit mode, the forwardAuth contract with Traefik, and the
// healthcheck. The audience is passed PER REQUEST rather than configured once,
// so each tunneled host is held to its own Access application.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/Einlanzerous/construct-server/pkg/cfaccess"
)

type mode string

const (
	// modeEnforce is the only mode that closes SERV-106. Anything unverified 403s.
	modeEnforce mode = "enforce"
	// modeAudit logs the decision it WOULD have made and allows the request
	// through regardless. It exists for the cutover: switching three live routers
	// to fail-closed in one step, on an estate whose ticket tracker is behind one
	// of them, is worth being able to rehearse against real traffic first. It is
	// not a supported steady state — the startup banner and /healthz both say so
	// loudly, and check-edge-auth.sh fails while it is set.
	modeAudit mode = "audit"
)

type config struct {
	addr       string
	teamDomain string
	audByHost  map[string]string
	refresh    time.Duration
	mode       mode
}

func main() {
	healthcheck := flag.Bool("healthcheck", false,
		"probe this container's own /healthz and exit non-zero if it is not serving; used by the compose healthcheck")
	flag.Parse()

	log := slog.New(slog.NewTextHandler(os.Stdout, nil))

	cfg, err := loadConfig()
	if err != nil {
		// Refuse to start rather than start permissive. An empty environment
		// variable is not a value (CLAUDE.md): with no AUD map there is no
		// audience to hold a token to, and the only safe reading of "no
		// configuration" is "reject everything", which is indistinguishable from
		// a crash-loop but much harder to diagnose.
		log.Error("refusing to start", "err", err)
		os.Exit(2)
	}

	if *healthcheck {
		os.Exit(probeSelf(cfg.addr))
	}

	// No Audience here on purpose: the guard picks one PER REQUEST from its host
	// map and calls VerifyAudience. A configured audience would be the wrong
	// shape — it would be the union of every host's AUD, which is exactly the
	// "a wiki token opens Switchyard" failure the per-host map exists to stop.
	// Verify() on this verifier fails closed with ErrNoAudienceConfigured.
	verifier, err := cfaccess.New(cfaccess.Config{
		TeamDomain:      cfg.teamDomain,
		RefreshInterval: cfg.refresh,
		Logger:          log,
	})
	if err != nil {
		log.Error("refusing to start", "err", err)
		os.Exit(2)
	}

	ctx := context.Background()
	if err := verifier.Refresh(ctx); err != nil {
		// Not fatal: Cloudflare being briefly unreachable at start should not
		// wedge the container. The cache stays empty, every request 403s, and
		// /healthz reports unhealthy until a refresh succeeds — fail-closed and
		// visible, rather than fail-closed and silent.
		log.Error("initial jwks fetch failed; serving 403 until it succeeds", "err", err)
	} else {
		log.Info("loaded Cloudflare Access signing keys", "keys", verifier.Health().Keys)
	}
	// Started AFTER the synchronous refresh above, so a hard startup failure is
	// visible in the logs as a startup failure rather than as the first request
	// getting a 403.
	go verifier.Run(ctx)

	g := &guard{cfg: cfg, verifier: verifier, log: log}

	mux := http.NewServeMux()
	mux.HandleFunc("/verify", g.handleVerify)
	mux.HandleFunc("/healthz", g.handleHealth)

	hosts := make([]string, 0, len(cfg.audByHost))
	for h := range cfg.audByHost {
		hosts = append(hosts, h)
	}
	log.Info("cf-access-guard listening",
		"addr", cfg.addr, "mode", string(cfg.mode), "issuer", verifier.Issuer(), "hosts", strings.Join(hosts, ","))
	if cfg.mode == modeAudit {
		log.Warn("AUDIT MODE: unverified requests will be ALLOWED and only logged — this does not enforce SERV-106")
	}

	srv := &http.Server{
		Addr:              cfg.addr,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Error("server stopped", "err", err)
		os.Exit(1)
	}
}

func loadConfig() (*config, error) {
	team := strings.TrimSpace(os.Getenv("CF_ACCESS_TEAM_DOMAIN"))
	if team == "" {
		return nil, errors.New("CF_ACCESS_TEAM_DOMAIN is unset or empty")
	}
	// Reduced to a bare host by the shared module, so pasting the value straight
	// out of the Zero Trust dashboard cannot produce an issuer of
	// "https://https://team.cloudflareaccess.com" that mismatches every token.
	team = cfaccess.NormalizeTeamDomain(team)
	if team == "" {
		return nil, errors.New("CF_ACCESS_TEAM_DOMAIN has no host in it")
	}

	audByHost, err := parseAudMap(os.Getenv("CF_ACCESS_AUD_MAP"))
	if err != nil {
		return nil, err
	}

	refresh := time.Hour
	if v := strings.TrimSpace(os.Getenv("CF_ACCESS_JWKS_REFRESH")); v != "" {
		d, err := time.ParseDuration(v)
		if err != nil {
			return nil, fmt.Errorf("CF_ACCESS_JWKS_REFRESH %q is not a duration: %w", v, err)
		}
		if d < time.Minute {
			return nil, fmt.Errorf("CF_ACCESS_JWKS_REFRESH %s is below the 1m floor", d)
		}
		refresh = d
	}

	m := modeEnforce
	switch v := strings.TrimSpace(os.Getenv("CF_ACCESS_GUARD_MODE")); v {
	case "", string(modeEnforce):
	case string(modeAudit):
		m = modeAudit
	default:
		// Not a silent fallback to enforce: a typo'd mode is a misconfiguration,
		// and guessing which one was meant is how "audit" survives into prod.
		return nil, fmt.Errorf("CF_ACCESS_GUARD_MODE %q is neither %q nor %q", v, modeEnforce, modeAudit)
	}

	addr := strings.TrimSpace(os.Getenv("CF_ACCESS_GUARD_ADDR"))
	if addr == "" {
		addr = ":4020"
	}

	return &config{
		addr:       addr,
		teamDomain: team,
		audByHost:  audByHost,
		refresh:    refresh,
		mode:       m,
	}, nil
}

// parseAudMap reads `host=aud` pairs separated by commas or newlines.
//
// One variable rather than one per host, because the set of tunneled hosts is
// the thing that changes and a per-host variable scheme needs a naming rule for
// turning a hostname into an identifier. Surrounding whitespace is tolerated so
// the compose file can fold the value across lines and stay readable.
func parseAudMap(raw string) (map[string]string, error) {
	out := map[string]string{}
	for _, entry := range strings.FieldsFunc(raw, func(r rune) bool {
		return r == ',' || r == '\n' || r == '\r' || r == ' ' || r == '\t'
	}) {
		host, aud, ok := strings.Cut(entry, "=")
		if !ok {
			return nil, fmt.Errorf("CF_ACCESS_AUD_MAP entry %q is not host=aud", entry)
		}
		host, aud = strings.ToLower(strings.TrimSpace(host)), strings.TrimSpace(aud)
		if host == "" || aud == "" {
			return nil, fmt.Errorf("CF_ACCESS_AUD_MAP entry %q has an empty host or AUD", entry)
		}
		if prev, dup := out[host]; dup && prev != aud {
			return nil, fmt.Errorf("CF_ACCESS_AUD_MAP maps %s to two different AUDs", host)
		}
		out[host] = aud
	}
	if len(out) == 0 {
		return nil, errors.New("CF_ACCESS_AUD_MAP is unset or empty, so no host could ever be authorised")
	}
	return out, nil
}

type guard struct {
	cfg      *config
	verifier *cfaccess.Verifier
	log      *slog.Logger
}

func (g *guard) handleVerify(w http.ResponseWriter, r *http.Request) {
	host := canonicalHost(r.Header.Get("X-Forwarded-Host"))
	claims, err := g.validate(r.Context(), host, r.Header.Get("Cf-Access-Jwt-Assertion"))

	if err != nil {
		// The reason goes to the log, never to the response. A caller learning
		// "wrong audience" versus "expired" versus "unknown host" is a probing
		// oracle; the operator needs all three and reads them here.
		g.log.Warn("access assertion rejected",
			"host", host,
			"uri", r.Header.Get("X-Forwarded-Uri"),
			"method", r.Header.Get("X-Forwarded-Method"),
			"client", r.Header.Get("X-Forwarded-For"),
			"mode", string(g.cfg.mode),
			"reason", err.Error())

		if g.cfg.mode == modeEnforce {
			w.Header().Set("X-Cf-Access-Guard", "deny")
			w.Header().Set("Content-Type", "text/plain; charset=utf-8")
			w.WriteHeader(http.StatusForbidden)
			fmt.Fprintln(w, "403 Forbidden — this origin requires a valid Cloudflare Access assertion.")
			return
		}
		w.Header().Set("X-Cf-Access-Guard", "audit-allow")
		w.WriteHeader(http.StatusOK)
		return
	}

	if g.cfg.mode == modeAudit {
		g.log.Info("access assertion accepted", "host", host, "email", claims.Email)
	}
	w.Header().Set("X-Cf-Access-Guard", "allow")
	w.WriteHeader(http.StatusOK)
}

// validate is the whole decision, kept separate from the HTTP plumbing so the
// tests exercise the decision rather than a round trip.
func (g *guard) validate(ctx context.Context, host, assertion string) (*cfaccess.Claims, error) {
	if host == "" {
		return nil, errors.New("no X-Forwarded-Host — /verify was not called by Traefik's forwardAuth")
	}
	// Fail closed on an unmapped host. A tunneled app added to routers.yml but
	// not to the AUD map is unreachable, which is loud; the alternative — letting
	// an unknown host through — is a new router silently shipping unauthenticated.
	aud, ok := g.cfg.audByHost[host]
	if !ok {
		return nil, fmt.Errorf("host is not in CF_ACCESS_AUD_MAP, so no audience can be required of it")
	}
	if assertion == "" {
		return nil, errors.New("no Cf-Access-Jwt-Assertion header")
	}
	// One audience, this host's. Not the map's values — a token is only good for
	// the application it was minted for.
	return g.verifier.VerifyAudience(ctx, assertion, aud)
}

func (g *guard) handleHealth(w http.ResponseWriter, r *http.Request) {
	h := g.verifier.Health()
	status := http.StatusOK
	if !h.OK {
		status = http.StatusServiceUnavailable
	}
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(status)
	fmt.Fprintf(w, "mode=%s hosts=%d %s\n", g.cfg.mode, len(g.cfg.audByHost), h)
}

// canonicalHost normalises a Host/X-Forwarded-Host for map lookup: lowercased,
// port removed. Comparing raw values would make "Switchyard.Zerogravity.Industries"
// and "switchyard.zerogravity.industries:443" unmapped hosts — a fail-closed
// outcome, but an outage rather than a security property.
func canonicalHost(h string) string {
	h = strings.ToLower(strings.TrimSpace(h))
	if h == "" {
		return ""
	}
	if host, _, err := net.SplitHostPort(h); err == nil {
		return host
	}
	return h
}

// probeSelf backs the container healthcheck. The image is FROM scratch, so there
// is no shell, no wget and no curl in it to probe with — the binary probes
// itself. It reads the same CF_ACCESS_GUARD_ADDR the server binds, so the two
// cannot drift apart.
func probeSelf(addr string) int {
	_, port, err := net.SplitHostPort(addr)
	if err != nil || port == "" {
		fmt.Fprintf(os.Stderr, "healthcheck: cannot derive a port from %q\n", addr)
		return 2
	}
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, "http://127.0.0.1:"+port+"/healthz", nil)
	if err != nil {
		fmt.Fprintf(os.Stderr, "healthcheck: %v\n", err)
		return 2
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		fmt.Fprintf(os.Stderr, "healthcheck: %v\n", err)
		return 1
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		fmt.Fprintf(os.Stderr, "healthcheck: /healthz returned HTTP %d\n", resp.StatusCode)
		return 1
	}
	return 0
}
