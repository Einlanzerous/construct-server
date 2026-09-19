// poster composites generated art into a print-ready magnet SVG (IDEA-52).
//
// The art and the type are deliberately separate concerns. IDEA-52 decided up
// front that typography is applied POST-generation, because in-model lettering
// cannot hold one font, kerning and placement across a set — a decision the spike
// then confirmed three times over, most memorably when the first smoke-test image
// produced "SILCR MANINE" unprompted.
//
// So the generator makes art with no text in it, and this puts the frame and the
// title around it: vector type, identical on every magnet, at whatever size the
// vendor wants.
//
// Everything is in MILLIMETRES, because the output is a physical object. The SVG
// carries real mm dimensions rather than pixels, so a print shop opening it gets
// the intended size without anyone having to agree a DPI first.
package main

import (
	"encoding/base64"
	"flag"
	"fmt"
	"html"
	"os"
	"path/filepath"
	"strings"
)

// Defaults are the 8 x 5.5 cm magnet in PORTRAIT, with the Nikko layout: art
// panel inside a cream frame, title band beneath it.
//
// The border and title-band figures are ASSUMED, not measured off the physical
// magnets — chosen so the art panel lands on 0.7705, within 1% of the 896x1152
// (0.7778) the Track B workflow generates. Measuring the real magnets may shift
// them; that is a flag change here and a one-line W,H change in sdxl_trackb.py.
const (
	defWidth  = 55.0 // trim width, mm
	defHeight = 80.0 // trim height, mm
	defBorder = 4.0  // cream frame, all round
	defTitle  = 11.0 // title band under the art
	defBleed  = 3.0  // printer bleed beyond trim — 3mm is the common ask
)

func main() {
	var (
		art     = flag.String("art", "", "PNG of the generated artwork (required)")
		place   = flag.String("place", "", "title line, e.g. MATTERHORN (required)")
		country = flag.String("country", "", "subtitle line, e.g. Switzerland")
		out     = flag.String("out", "", "output .svg (default: <place>.svg)")
		wmm     = flag.Float64("width", defWidth, "trim width in mm")
		hmm     = flag.Float64("height", defHeight, "trim height in mm")
		border  = flag.Float64("border", defBorder, "cream frame in mm")
		titleH  = flag.Float64("title-band", defTitle, "title band height in mm")
		bleed   = flag.Float64("bleed", defBleed, "bleed beyond trim in mm; 0 for none")
		cream   = flag.String("cream", "#F4F1E4", "frame colour")
		ink     = flag.String("ink", "#1B2A3A", "type colour")
		fontF   = flag.String("font", "/usr/share/fonts/truetype/liberation/LiberationSerif-Bold.ttf",
			"TTF for the place line, embedded into the SVG; \"\" to reference --font-family by name instead")
		// The two lines are DIFFERENT WEIGHTS, which is not a detail — on the Nikko
		// reference "NIKKO" is heavy and "Japan" is noticeably lighter, and setting
		// both bold reads as a different poster at a glance.
		fontFR = flag.String("font-regular", "/usr/share/fonts/truetype/liberation/LiberationSerif-Regular.ttf",
			"TTF for the country line; \"\" to reuse --font")
		fontFam   = flag.String("font-family", "Liberation Serif", "font-family name")
		placePt   = flag.Float64("place-size", 5.4, "place type size in mm")
		countryPt = flag.Float64("country-size", 2.7, "country type size in mm")
		track     = flag.Float64("tracking", 0.35, "letter-spacing for the place line, mm")
	)
	flag.Parse()

	if *art == "" || *place == "" {
		fmt.Fprintln(os.Stderr, "poster: --art and --place are required")
		flag.Usage()
		os.Exit(2)
	}
	if *out == "" {
		*out = strings.ToLower(strings.ReplaceAll(*place, " ", "_")) + ".svg"
	}

	artData, err := os.ReadFile(*art)
	if err != nil {
		fmt.Fprintf(os.Stderr, "poster: cannot read --art %q: %v\n", *art, err)
		os.Exit(1)
	}

	// The art panel: the frame insets it on three sides, the title band on the
	// fourth. Everything else is derived so there is one source of truth.
	panelX, panelY := *border, *border
	panelW := *wmm - 2**border
	panelH := *hmm - *border - *titleH - *border
	if panelW <= 0 || panelH <= 0 {
		fmt.Fprintf(os.Stderr, "poster: border %.1fmm and title band %.1fmm leave no room "+
			"in %.1fx%.1fmm\n", *border, *titleH, *wmm, *hmm)
		os.Exit(1)
	}

	// Bleed grows the canvas and shifts the origin, so trim coordinates stay the
	// numbers above and the frame colour simply runs past the cut.
	canvasW, canvasH := *wmm+2**bleed, *hmm+2**bleed
	ox, oy := *bleed, *bleed

	// EMBEDDED, not referenced. An SVG that names a font it does not carry is the
	// classic print failure: the RIP substitutes silently, the kerning the set
	// depends on is gone, and nothing on screen shows it happened.
	embed := func(path string, weight int) (string, error) {
		if path == "" {
			return "", nil
		}
		b, err := os.ReadFile(path)
		if err != nil {
			return "", err
		}
		return fmt.Sprintf(`
    @font-face {
      font-family: %q;
      font-weight: %d;
      src: url("data:font/ttf;base64,%s") format("truetype");
    }`, *fontFam, weight, base64.StdEncoding.EncodeToString(b)), nil
	}
	boldCSS, err := embed(*fontF, 700)
	if err != nil {
		fmt.Fprintf(os.Stderr, "poster: cannot read --font %q: %v\n"+
			"Pass --font \"\" to reference the family by name instead, but then the\n"+
			"print shop needs that font installed or the type will silently substitute.\n",
			*fontF, err)
		os.Exit(1)
	}
	regCSS, err := embed(*fontFR, 400)
	if err != nil {
		fmt.Fprintf(os.Stderr, "poster: cannot read --font-regular %q: %v\n", *fontFR, err)
		os.Exit(1)
	}
	fontCSS := boldCSS + regCSS

	placeY := oy + *hmm - *border - *titleH + *placePt + 1.0
	countryY := placeY + *countryPt + 2.2

	svg := fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8"?>
<!-- %s — generated by tools/poster (IDEA-52). Units are mm; trim is %.1fx%.1fmm
     with %.1fmm bleed. Art panel %.2fx%.2fmm (aspect %.4f). -->
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"
     width="%.2fmm" height="%.2fmm" viewBox="0 0 %.2f %.2f">
  <style>%s
    .place   { font-family: %q; font-weight: 700; font-size: %.2fpx; letter-spacing: %.2fpx; fill: %s; }
    .country { font-family: %q; font-weight: 400; font-size: %.2fpx; letter-spacing: %.2fpx; fill: %s; }
  </style>

  <!-- Frame colour runs to the bleed edge, so a cut anywhere in the bleed is clean. -->
  <rect x="0" y="0" width="%.2f" height="%.2f" fill="%s"/>

  <!-- Art. xMidYMid slice fills the panel and crops the overflow: the workflow
       generates 0.7778 and the panel is 0.7705, so ~1%% of the height is trimmed
       rather than the art being letterboxed against the frame. -->
  <clipPath id="panel"><rect x="%.2f" y="%.2f" width="%.2f" height="%.2f"/></clipPath>
  <image x="%.2f" y="%.2f" width="%.2f" height="%.2f"
         preserveAspectRatio="xMidYMid slice" clip-path="url(#panel)"
         xlink:href="data:image/png;base64,%s"/>

  <text class="place"   x="%.2f" y="%.2f" text-anchor="middle">%s</text>
  <text class="country" x="%.2f" y="%.2f" text-anchor="middle">%s</text>
</svg>
`,
		*place, *wmm, *hmm, *bleed, panelW, panelH, panelW/panelH,
		canvasW, canvasH, canvasW, canvasH,
		fontCSS,
		*fontFam, *placePt, *track, *ink,
		*fontFam, *countryPt, *track*0.6, *ink,
		canvasW, canvasH, *cream,
		ox+panelX, oy+panelY, panelW, panelH,
		ox+panelX, oy+panelY, panelW, panelH,
		base64.StdEncoding.EncodeToString(artData),
		ox+*wmm/2, placeY, html.EscapeString(strings.ToUpper(*place)),
		ox+*wmm/2, countryY, html.EscapeString(*country),
	)

	if err := os.WriteFile(*out, []byte(svg), 0o644); err != nil {
		fmt.Fprintf(os.Stderr, "poster: cannot write %q: %v\n", *out, err)
		os.Exit(1)
	}
	abs, _ := filepath.Abs(*out)
	fmt.Printf("%s\n  trim %.1fx%.1fmm + %.1fmm bleed, art panel %.2fx%.2fmm (%.4f)\n",
		abs, *wmm, *hmm, *bleed, panelW, panelH, panelW/panelH)
}
