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
	"encoding/xml"
	"flag"
	"fmt"
	"html"
	"image/png"
	"os"
	"path/filepath"
	"strings"
)

// Defaults are the 8 x 5.5 cm magnet in PORTRAIT, as a POLAROID: a thin even
// frame on the top and both sides, and a deeper band at the bottom carrying the
// place name alone. The first layout copied the Nikko reference — a 4mm frame
// all round and a two-line title with the country beneath — and it wasted the
// top of a small object on a frame. The art is the point; the frame now gives
// it the space.
//
// THE BOTTOM BAND IS DERIVED, NOT CHOSEN. Given the frame width, the art panel's
// height follows from the art's own aspect, so the panel matches the image
// exactly and nothing is cropped; whatever height remains is the bottom band.
// At 3mm that gives a 14mm band, which lands on a real Polaroid's proportions
// (bottom roughly 4.7x the side) without that being tuned for.
//
// The frame width is ASSUMED, not measured off the physical magnets.
const (
	defWidth  = 55.0 // trim width, mm
	defHeight = 80.0 // trim height, mm
	defBorder = 3.0  // frame on the top and both sides
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
		border  = flag.Float64("border", defBorder, "frame on the top and both sides, in mm")
		titleH  = flag.Float64("title-band", 0,
			"bottom band height in mm; 0 (default) derives it from the art's aspect so\n"+
				"the panel matches the image exactly and nothing is cropped")
		bleed = flag.Float64("bleed", defBleed, "bleed beyond trim in mm; 0 for none")
		cream = flag.String("cream", "#F4F1E4", "frame colour")
		ink   = flag.String("ink", "#1B2A3A", "type colour")
		fontF = flag.String("font", "/usr/share/fonts/truetype/liberation/LiberationSerif-Bold.ttf",
			"TTF for the place line, embedded into the SVG; \"\" to reference --font-family by name instead")
		// The two lines are DIFFERENT WEIGHTS, which is not a detail — on the Nikko
		// reference "NIKKO" is heavy and "Japan" is noticeably lighter, and setting
		// both bold reads as a different poster at a glance.
		fontFR = flag.String("font-regular", "/usr/share/fonts/truetype/liberation/LiberationSerif-Regular.ttf",
			"TTF for the country line; \"\" to reuse --font")
		fontFam = flag.String("font-family", "Liberation Serif", "font-family name")
		// One size for the whole set, set by its LONGEST name. At 6mm "GLACIER
		// EXPRESS" measured 60.6mm against a 49mm panel; 4.6mm with 0.25 tracking
		// fits it with 1.2/1.6mm to spare. Sizing each name to its own width would
		// read as three different posters, so the long one decides for all.
		placePt   = flag.Float64("place-size", 4.6, "place type size in mm")
		countryPt = flag.Float64("country-size", 2.7, "country type size in mm")
		track     = flag.Float64("tracking", 0.25, "letter-spacing for the place line, mm")
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

	// The art panel sits inside the frame on the top and both sides. Its height
	// comes from the art's own aspect unless --title-band pins the bottom band.
	panelX, panelY := *border, *border
	panelW := *wmm - 2**border
	var panelH float64
	if *titleH > 0 {
		panelH = *hmm - *border - *titleH
	} else {
		cfg, err := png.DecodeConfig(strings.NewReader(string(artData)))
		if err != nil {
			fmt.Fprintf(os.Stderr, "poster: cannot read the size of --art %q to derive "+
				"the layout: %v\nPass --title-band to set the bottom band by hand.\n", *art, err)
			os.Exit(1)
		}
		panelH = panelW * float64(cfg.Height) / float64(cfg.Width)
	}
	bandTop := panelY + panelH // the bottom band runs from here to the trim
	bandH := *hmm - bandTop
	if panelW <= 0 || panelH <= 0 || bandH < *border {
		fmt.Fprintf(os.Stderr, "poster: a %.1fmm frame and this art's aspect leave no room "+
			"for a bottom band in %.1fx%.1fmm (band would be %.1fmm)\n",
			*border, *wmm, *hmm, bandH)
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

	// SVG places text by its BASELINE, so centring a line means offsetting by half
	// its cap height — about 0.66 of the size for Liberation Serif. With no country
	// line the name sits alone and is centred in the whole band; with one, the pair
	// is centred as a block.
	const capRatio = 0.66
	var placeY, countryY float64
	if *country == "" {
		placeY = oy + bandTop + bandH/2 + *placePt*capRatio/2
	} else {
		gap := 2.2
		block := *placePt*capRatio + gap + *countryPt*capRatio
		top := oy + bandTop + (bandH-block)/2
		placeY = top + *placePt*capRatio
		countryY = placeY + gap + *countryPt*capRatio
	}

	// The country line is omitted entirely rather than emitted empty, so the SVG
	// carries nothing a print shop could mistake for a missing field.
	countryLine := ""
	if *country != "" {
		countryLine = fmt.Sprintf("\n  <text class=\"country\" x=\"%.2f\" y=\"%.2f\" "+
			"text-anchor=\"middle\">%s</text>", ox+*wmm/2, countryY, html.EscapeString(*country))
	}

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

  <!-- Art. The panel is sized from the art's own aspect by default, so slice
       crops nothing; it only matters if the title-band flag pins the band. -->
  <clipPath id="panel"><rect x="%.2f" y="%.2f" width="%.2f" height="%.2f"/></clipPath>
  <image x="%.2f" y="%.2f" width="%.2f" height="%.2f"
         preserveAspectRatio="xMidYMid slice" clip-path="url(#panel)"
         xlink:href="data:image/png;base64,%s"/>

  <text class="place" x="%.2f" y="%.2f" text-anchor="middle">%s</text>%s
</svg>
`,
		commentSafe(*place), *wmm, *hmm, *bleed, panelW, panelH, panelW/panelH,
		canvasW, canvasH, canvasW, canvasH,
		fontCSS,
		*fontFam, *placePt, *track, *ink,
		*fontFam, *countryPt, *track*0.6, *ink,
		canvasW, canvasH, *cream,
		ox+panelX, oy+panelY, panelW, panelH,
		ox+panelX, oy+panelY, panelW, panelH,
		base64.StdEncoding.EncodeToString(artData),
		// letter-spacing adds space after EVERY glyph including the last, so a
		// tracked line centred on x sits half a tracking-unit left of true centre.
		// Measured at -0.19mm on all three posters; this puts it back.
		ox+*wmm/2+*track/2, placeY, html.EscapeString(strings.ToUpper(*place)),
		countryLine,
	)

	// Refuse to write a file no renderer can open. XML forbids "--" inside a
	// comment, and this template's comments are where that bit: a comment naming
	// the --title-band flag produced an SVG that Chrome showed as a parse error
	// while this program exited 0. Parsing our own output costs nothing and turns
	// that from a silently broken print file into a loud failure here.
	if err := wellFormed(svg); err != nil {
		fmt.Fprintf(os.Stderr, "poster: refusing to write malformed SVG: %v\n", err)
		os.Exit(1)
	}

	if err := os.WriteFile(*out, []byte(svg), 0o644); err != nil {
		fmt.Fprintf(os.Stderr, "poster: cannot write %q: %v\n", *out, err)
		os.Exit(1)
	}
	abs, _ := filepath.Abs(*out)
	fmt.Printf("%s\n  trim %.1fx%.1fmm + %.1fmm bleed, art panel %.2fx%.2fmm (%.4f)\n",
		abs, *wmm, *hmm, *bleed, panelW, panelH, panelW/panelH)
}

// commentSafe makes arbitrary text legal inside an XML comment, where "--" is
// forbidden. The place name is interpolated into the header comment, so a name
// like "Foo--Bar" would otherwise break the whole file.
func commentSafe(s string) string {
	for strings.Contains(s, "--") {
		s = strings.ReplaceAll(s, "--", "-\u2011")
	}
	return s
}

func wellFormed(doc string) error {
	d := xml.NewDecoder(strings.NewReader(doc))
	for {
		if _, err := d.Token(); err != nil {
			if err.Error() == "EOF" {
				return nil
			}
			return err
		}
	}
}
