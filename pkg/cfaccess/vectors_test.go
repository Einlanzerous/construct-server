package cfaccess

// Runs the shared vectors in testdata/vectors.json.
//
// This Go runner is the only thing that runs the file today. It is written to be
// vendored by a consumer in another language or repository (Switchyard's
// TypeScript service on jose, heitan, Chronicle: SERV-308, SERV-309, SERV-310),
// and a cross-language run is the one check that can span the language boundary
// — code sharing cannot reach a TypeScript service, and the cases a hand-rolled
// verifier gets wrong QUIETLY (alg:none, an RSA public key replayed as an HMAC
// secret) are exactly the ones where "both implementations agree" is worth more
// than "one implementation has a test". Until a second runner exists, that
// agreement is intended and not demonstrated.

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func loadVectors(t *testing.T) vectorFile {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("testdata", "vectors.json"))
	if err != nil {
		t.Fatalf("shared vectors are missing: %v", err)
	}
	var vf vectorFile
	if err := json.Unmarshal(raw, &vf); err != nil {
		t.Fatalf("shared vectors are not valid JSON: %v", err)
	}
	if vf.Spec != "cfaccess-vectors/2" {
		t.Fatalf("unknown vector spec %q — this runner reads cfaccess-vectors/2 and refuses spec 1, whose vectors carry no config or expectPrincipal", vf.Spec)
	}
	if len(vf.Vectors) == 0 {
		t.Fatal("the vector file is empty, so this test proves nothing")
	}
	return vf
}

func TestSharedVectors(t *testing.T) {
	vf := loadVectors(t)

	for _, vec := range vf.Vectors {
		t.Run(vec.Name, func(t *testing.T) {
			set, ok := vf.KeySets[vec.KeySet]
			if !ok {
				t.Fatalf("vector names key set %q, which the file does not define", vec.KeySet)
			}
			body, err := json.Marshal(set)
			if err != nil {
				t.Fatal(err)
			}
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", "application/json")
				_, _ = w.Write(body)
			}))
			defer srv.Close()

			now, err := time.Parse(time.RFC3339, vec.Now)
			if err != nil {
				t.Fatalf("vector now=%q: %v", vec.Now, err)
			}

			cfg := Config{
				TeamDomain: vf.TeamDomain,
				Audience:   vec.Audience,
				Now:        func() time.Time { return now },
				certsURL:   srv.URL,
			}
			if vec.Config != nil {
				cfg.RequirePrincipal = vec.Config.RequirePrincipal
			}
			v, err := New(cfg)
			if err != nil {
				t.Fatal(err)
			}

			claims, err := v.Verify(context.Background(), vec.Token)

			want := vec.Expect
			if by, hasOverride := vec.ExpectBy["go"]; hasOverride {
				want = by
			}

			switch want {
			case "accept":
				if err != nil {
					t.Fatalf("vector expects accept (%s) but verification failed: %v", vec.Because, err)
				}
				if vec.Claims != nil {
					if claims.Email != vec.Claims.Email {
						t.Errorf("email = %q, want %q", claims.Email, vec.Claims.Email)
					}
					if claims.Subject != vec.Claims.Subject {
						t.Errorf("sub = %q, want %q", claims.Subject, vec.Claims.Subject)
					}
				}
				if vec.ExpectPrincipal != nil {
					if string(claims.Kind) != vec.ExpectPrincipal.Kind {
						t.Errorf("principal kind = %q, want %q", claims.Kind, vec.ExpectPrincipal.Kind)
					}
					if claims.CommonName != vec.ExpectPrincipal.CommonName {
						t.Errorf("principal commonName = %q, want %q", claims.CommonName, vec.ExpectPrincipal.CommonName)
					}
				}
			case "reject":
				if err == nil {
					t.Fatalf("vector expects reject (%s) but verification SUCCEEDED — this is a bypass", vec.Because)
				}
			default:
				t.Fatalf("vector has expect=%q, want accept or reject", want)
			}
		})
	}
}

// The vector file is a contract with a suite in another language and another
// repository. Silently dropping a case would leave both sides green, so the
// cases this ticket named are asserted to be present by name.
func TestSharedVectorsCoverTheNamedCases(t *testing.T) {
	vf := loadVectors(t)

	seen := map[string]bool{}
	for _, v := range vf.Vectors {
		if seen[v.Name] {
			t.Errorf("duplicate vector name %q — other runners may key their report on this", v.Name)
		}
		seen[v.Name] = true
		if v.Class != "protocol" && v.Class != "keypolicy" {
			t.Errorf("vector %q has class %q, want protocol or keypolicy", v.Name, v.Class)
		}
		if v.Because == "" {
			t.Errorf("vector %q has no `because` — a reader of the other suite has only this to go on", v.Name)
		}
	}

	for _, name := range []string{
		"good-token",
		"wrong-audience",
		"wrong-issuer",
		"expired",
		"not-yet-valid",
		"alg-none",
		"hmac-replay",
		"unknown-kid",
		"nine-byte-exponent",
		"weak-modulus",
		"encryption-key",
		"empty-key-set",
		"principal-both-refused",
		"principal-neither-refused",
		"principal-service-only-accepted",
	} {
		if !seen[name] {
			t.Errorf("vector %q is missing — SERV-131 and SERV-293 name it explicitly", name)
		}
	}
}
