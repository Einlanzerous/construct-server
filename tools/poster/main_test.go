package main

import (
	"math"
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

func near(a, b float64) bool { return math.Abs(a-b) < 0.01 }

// The numbers the README's table states, derived from real 896x1152 art.
func TestLayoutDerivedFromArtAspect(t *testing.T) {
	g, err := computeLayout(55, 80, 3, 0, 896, 1152)
	if err != nil {
		t.Fatal(err)
	}
	if !near(g.panelW, 49) || !near(g.panelH, 63) {
		t.Errorf("panel = %.2fx%.2f, want 49x63", g.panelW, g.panelH)
	}
	if !near(g.bandTop, 66) || !near(g.bandH, 14) {
		t.Errorf("band top %.2f height %.2f, want 66 and 14", g.bandTop, g.bandH)
	}
	// The derived panel must match the art exactly — that is the whole point.
	if !near(g.panelW/g.panelH, 896.0/1152.0) {
		t.Errorf("panel aspect %.4f, art aspect %.4f: the art would be cropped",
			g.panelW/g.panelH, 896.0/1152.0)
	}
}

func TestLayoutPinnedBand(t *testing.T) {
	g, err := computeLayout(55, 80, 3, 12, 0, 0) // no art size needed when pinned
	if err != nil {
		t.Fatal(err)
	}
	if !near(g.panelH, 65) || !near(g.bandH, 12) {
		t.Errorf("pinned: panelH %.2f bandH %.2f, want 65 and 12", g.panelH, g.bandH)
	}
}

// Art too tall for the magnet must be refused, not produce a negative band.
func TestLayoutRefusesArtWithNoRoomForBand(t *testing.T) {
	if _, err := computeLayout(55, 80, 3, 0, 500, 1000); err == nil {
		t.Fatal("a 1:2 image leaves no bottom band on 55x80; want an error")
	}
	// The boundary itself: a band exactly as tall as the frame is allowed.
	// 55x80, 3mm frame -> panelW 49; a band of 3mm needs panelH 74 -> art 49:74.
	if _, err := computeLayout(55, 80, 3, 0, 4900, 7400); err != nil {
		t.Errorf("band equal to the frame should be allowed: %v", err)
	}
}

// A lone name must sit with its cap height centred on the band's centre line.
func TestSingleLineIsCentredInBand(t *testing.T) {
	const bandTop, bandH, size = 66.0, 14.0, 4.6
	placeY, _ := titleBaselines(bandTop, bandH, size, 0, false)
	capMid := placeY - size*capRatio/2
	if !near(capMid, bandTop+bandH/2) {
		t.Errorf("cap-height centre at %.3f, band centre at %.3f", capMid, bandTop+bandH/2)
	}
}

// With a country line the PAIR is centred as a block, not the name alone.
func TestTwoLinesCentredAsBlock(t *testing.T) {
	const bandTop, bandH, p, c = 66.0, 14.0, 4.6, 2.7
	placeY, countryY := titleBaselines(bandTop, bandH, p, c, true)
	blockTop := placeY - p*capRatio
	blockBottom := countryY
	if !near((blockTop+blockBottom)/2, bandTop+bandH/2) {
		t.Errorf("block centre %.3f, band centre %.3f", (blockTop+blockBottom)/2, bandTop+bandH/2)
	}
	if countryY <= placeY {
		t.Errorf("country baseline %.2f is not below place baseline %.2f", countryY, placeY)
	}
}
