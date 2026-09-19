package main

import (
	"strings"
	"testing"
)

// The guard exists because a comment naming the --title-band flag produced an
// SVG that no renderer could open while the program exited 0. A check that has
// never been seen to fail is indistinguishable from one that cannot, so these
// assert it rejects the actual failure, not just that it accepts good input.
func TestWellFormedRejectsDoubleHyphenInComment(t *testing.T) {
	bad := `<svg xmlns="http://www.w3.org/2000/svg"><!-- see --title-band --></svg>`
	if err := wellFormed(bad); err == nil {
		t.Fatal("wellFormed accepted a comment containing --; it must reject it")
	}
}

func TestWellFormedRejectsUnclosedElement(t *testing.T) {
	if err := wellFormed(`<svg><text>MATTERHORN</svg>`); err == nil {
		t.Fatal("wellFormed accepted an unclosed element")
	}
}

func TestWellFormedAcceptsValid(t *testing.T) {
	good := `<svg xmlns="http://www.w3.org/2000/svg"><!-- fine --><text>X</text></svg>`
	if err := wellFormed(good); err != nil {
		t.Fatalf("wellFormed rejected valid SVG: %v", err)
	}
}

func TestCommentSafe(t *testing.T) {
	for _, in := range []string{"Foo--Bar", "a---b", "----", "Matterhorn"} {
		out := commentSafe(in)
		if strings.Contains(out, "--") {
			t.Errorf("commentSafe(%q) = %q, still contains --", in, out)
		}
		// And the result must actually survive inside a comment.
		if err := wellFormed("<x><!-- " + out + " --></x>"); err != nil {
			t.Errorf("commentSafe(%q) = %q is not legal in a comment: %v", in, out, err)
		}
	}
}
