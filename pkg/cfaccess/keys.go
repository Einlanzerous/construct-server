package cfaccess

import (
	"context"
	"crypto/rsa"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"math/big"
	"net/http"
	"strings"
)

const (
	// maxJWKSBytes bounds the remote key document. This is parsed on a path
	// reachable from an unauthenticated request, so it must not be able to
	// exhaust memory however well-behaved the real source is.
	maxJWKSBytes = 1 << 20

	// minModulusBits refuses a DOWNGRADED signing key rather than a small one.
	// Cloudflare publishes 2048-bit keys; accepting less would let a substituted
	// key set quietly weaken every verification that follows.
	minModulusBits = 2048

	// maxExponentBytes is the bound whose absence is LYCM-122. Reconstructing the
	// exponent means left-padding it into a fixed 8-byte buffer, and a 9-byte
	// exponent from a hostile or malformed key set slices that buffer at index -1
	// and panics the process — no recover, remote input, security path. A real
	// RSA exponent is three bytes.
	maxExponentBytes = 8
)

// jwk is the subset of a JSON Web Key this needs.
type jwk struct {
	Kid string `json:"kid"`
	Kty string `json:"kty"`
	Use string `json:"use"`
	N   string `json:"n"` // base64url big-endian modulus
	E   string `json:"e"` // base64url big-endian exponent
}

// keySet is a parsed JWKS plus the reasons any key in it was dropped.
type keySet struct {
	keys    map[string]*rsa.PublicKey
	skipped []string
}

// fetchKeys retrieves and parses the RSA signing keys at url.
//
// A fetch that succeeds but yields ZERO usable keys is an error, not an empty
// success: replacing a working key set with an empty one turns a Cloudflare-side
// glitch into a total outage, and "we have no keys" is never a legitimate steady
// state.
func fetchKeys(ctx context.Context, client *http.Client, url string) (keySet, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return keySet{}, fmt.Errorf("GET %s: %w", url, err)
	}
	resp, err := client.Do(req)
	if err != nil {
		return keySet{}, fmt.Errorf("GET %s: %w", url, err)
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		return keySet{}, fmt.Errorf("GET %s: HTTP %d", url, resp.StatusCode)
	}

	body, err := io.ReadAll(io.LimitReader(resp.Body, maxJWKSBytes))
	if err != nil {
		return keySet{}, fmt.Errorf("reading %s: %w", url, err)
	}

	var doc struct {
		Keys []jwk `json:"keys"`
	}
	if err := json.Unmarshal(body, &doc); err != nil {
		return keySet{}, fmt.Errorf("parsing %s: %w", url, err)
	}

	out := keySet{keys: make(map[string]*rsa.PublicKey, len(doc.Keys))}
	for _, k := range doc.Keys {
		// Non-RSA and explicitly non-signing keys are SKIPPED rather than
		// rejected: the endpoint is allowed to publish key types and purposes
		// this package does not use, and refusing the whole set over one would
		// be brittle. A key with use:"enc" is an encryption key — verifying a
		// signature with it is a category error, not a near miss.
		if k.Kty != "RSA" || k.Kid == "" || (k.Use != "" && k.Use != "sig") {
			continue
		}
		pub, err := rsaKeyFromJWK(k)
		if err != nil {
			// One unusable key does not condemn the set. This is a deliberate
			// widening of construct-server's original behaviour, which failed the
			// whole refresh: on a cold start that turns a single malformed key
			// published upstream into an estate-wide sign-in outage, and the
			// zero-key check below still catches a set that is entirely bad.
			// The reason is kept so Health can show it rather than it vanishing.
			out.skipped = append(out.skipped, fmt.Sprintf("%s: %v", k.Kid, err))
			continue
		}
		out.keys[k.Kid] = pub
	}

	if len(out.keys) == 0 {
		if len(out.skipped) > 0 {
			return keySet{}, fmt.Errorf("%s published no usable RSA signing key (%s)", url, strings.Join(out.skipped, "; "))
		}
		return keySet{}, fmt.Errorf("%s published no usable RSA signing keys", url)
	}
	return out, nil
}

// rsaKeyFromJWK rebuilds an RSA public key from a JWK's base64url modulus and
// exponent, refusing anything that is not a key Cloudflare Access would publish.
func rsaKeyFromJWK(k jwk) (*rsa.PublicKey, error) {
	n, err := base64.RawURLEncoding.DecodeString(k.N)
	if err != nil {
		return nil, fmt.Errorf("modulus is not base64url: %w", err)
	}
	e, err := base64.RawURLEncoding.DecodeString(k.E)
	if err != nil {
		return nil, fmt.Errorf("exponent is not base64url: %w", err)
	}

	// The upper bound is the LYCM-122 fix; see maxExponentBytes.
	if len(e) == 0 || len(e) > maxExponentBytes {
		return nil, fmt.Errorf("exponent is %d bytes, which is not a usable RSA exponent", len(e))
	}

	// BitLen of the INTEGER, not len(n)*8 of the encoding. JWK `n` is an unsigned
	// big-endian integer with no canonical length, so left-padding with zero bytes
	// does not change the key — and a 1024-bit modulus padded out to 256 bytes
	// clears an encoding-length check while producing a 1024-bit key. Measured:
	// bare 1024 rejected, the same integer zero-padded accepted. The check that
	// looks equivalent is the one that does nothing.
	modulus := new(big.Int).SetBytes(n)
	if modulus.BitLen() < minModulusBits {
		return nil, fmt.Errorf("modulus is %d bits, below the %d-bit minimum", modulus.BitLen(), minModulusBits)
	}

	var buf [maxExponentBytes]byte
	copy(buf[maxExponentBytes-len(e):], e)
	ev := binary.BigEndian.Uint64(buf[:])
	// rsa.PublicKey.E is an int. Rejecting anything above MaxInt32 keeps that
	// conversion exact on every platform Go builds for, rather than only on the
	// 64-bit ones this happens to run on. e < 3 is not an RSA exponent at all.
	if ev < 3 || ev > math.MaxInt32 {
		return nil, fmt.Errorf("exponent %d is out of range for an RSA public key", ev)
	}

	return &rsa.PublicKey{N: modulus, E: int(ev)}, nil
}
