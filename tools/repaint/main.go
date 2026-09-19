// repaint applies deterministic colour corrections to flat-vector poster art (IDEA-52).
//
// WHY THIS EXISTS. Some corrections are simply not promptable. On this set,
// three rounds of increasingly explicit wording could not put a dark tunnel mouth
// into the Glacier Express poster, because a tunnel is a dark hole and a dark hole
// produces almost no edge signal in the lineart control map — so nothing holds it
// and the model fills it with cliff. Pushing the train's red and cooling the
// over-icy cliffs ran into the same wall from the other side: the model averages
// over the whole scene, and a prompt is a blunt instrument for "that region, that
// colour".
//
// But the output is FLAT BLOCKS OF COLOUR. A hue band is a real, separable thing
// in this art in a way it would not be in a photograph, so selecting on it and
// adjusting is exact and repeatable — no model, no seed, no variance.
//
// This runs AFTER sdxl_trackb.py and BEFORE tools/poster, on the raw art.
package main

import (
	"flag"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"math"
	"os"
	"strconv"
	"strings"
)

func rgbToHSL(r, g, b float64) (h, s, l float64) {
	max := math.Max(r, math.Max(g, b))
	min := math.Min(r, math.Min(g, b))
	l = (max + min) / 2
	if max == min {
		return 0, 0, l
	}
	d := max - min
	if l > 0.5 {
		s = d / (2 - max - min)
	} else {
		s = d / (max + min)
	}
	switch max {
	case r:
		h = (g - b) / d
		if g < b {
			h += 6
		}
	case g:
		h = (b-r)/d + 2
	default:
		h = (r-g)/d + 4
	}
	return h * 60, s, l
}

func hue2rgb(p, q, t float64) float64 {
	if t < 0 {
		t++
	}
	if t > 1 {
		t--
	}
	switch {
	case t < 1.0/6:
		return p + (q-p)*6*t
	case t < 1.0/2:
		return q
	case t < 2.0/3:
		return p + (q-p)*(2.0/3-t)*6
	}
	return p
}

func hslToRGB(h, s, l float64) (r, g, b float64) {
	h = math.Mod(h, 360) / 360
	if s == 0 {
		return l, l, l
	}
	var q float64
	if l < 0.5 {
		q = l * (1 + s)
	} else {
		q = l + s - l*s
	}
	p := 2*l - q
	return hue2rgb(p, q, h+1.0/3), hue2rgb(p, q, h), hue2rgb(p, q, h-1.0/3)
}

// hueDist is circular: 350° and 10° are 20° apart, not 340°. Reds straddle the
// wrap point, so getting this wrong silently selects nothing.
func hueDist(a, b float64) float64 {
	d := math.Abs(a - b)
	if d > 180 {
		d = 360 - d
	}
	return d
}

type band struct {
	hue, tol, dSat, dLight float64
	// Optional bounding box, as fractions. A hue band alone only works when that
	// hue means ONE thing in the picture — on the Glacier Express art, 71% of
	// saturated pixels are 180-210 degrees and all of it is cliff, so draining it
	// is exact. On the Matterhorn the same band is the sky AND the lake AND the
	// shadows on the peak, so deepening "the lake" turned the whole poster
	// turquoise. Constraining the band to a box is what makes that case work.
	hasBox         bool
	bx, by, bw, bh float64
}

// "hue,tolerance,dSat,dLight", optionally followed by ",x,y,w,h" to confine it.
//
//	"0,25,0.35,0"                       reds, everywhere
//	"200,22,0.2,-0.1,0.0,0.55,1.0,0.45" blues, lower 45% of the frame only
func parseBand(s string) (band, error) {
	p := strings.Split(s, ",")
	if len(p) != 4 && len(p) != 8 {
		return band{}, fmt.Errorf("want hue,tolerance,dSat,dLight[,x,y,w,h]; got %q", s)
	}
	v := make([]float64, len(p))
	for i, x := range p {
		f, err := strconv.ParseFloat(strings.TrimSpace(x), 64)
		if err != nil {
			return band{}, fmt.Errorf("field %d of %q: %v", i+1, s, err)
		}
		v[i] = f
	}
	b := band{hue: v[0], tol: v[1], dSat: v[2], dLight: v[3]}
	if len(v) == 8 {
		b.hasBox, b.bx, b.by, b.bw, b.bh = true, v[4], v[5], v[6], v[7]
	}
	return b, nil
}

type region struct{ x, y, w, h, factor float64 }

// "x,y,w,h,factor" as FRACTIONS of the image, so the same numbers work whatever
// the resolution — which matters because the art is regenerated, not edited.
func parseRegion(s string) (region, error) {
	p := strings.Split(s, ",")
	if len(p) != 5 {
		return region{}, fmt.Errorf("want x,y,w,h,factor as fractions; got %q", s)
	}
	var v [5]float64
	for i, x := range p {
		f, err := strconv.ParseFloat(strings.TrimSpace(x), 64)
		if err != nil {
			return region{}, fmt.Errorf("field %d of %q: %v", i+1, s, err)
		}
		v[i] = f
	}
	return region{v[0], v[1], v[2], v[3], v[4]}, nil
}

func main() {
	var bands, regions multiFlag
	in := flag.String("in", "", "input PNG (required)")
	out := flag.String("out", "", "output PNG (required)")
	flag.Var(&bands, "band", "hue,tolerance,dSat,dLight[,x,y,w,h] — repeatable.\n"+
		"Adjusts pixels whose hue is within tolerance of hue,\n"+
		"optionally confined to a box given as fractions.\n"+
		"e.g. -band 0,22,0.45,0               reds, everywhere\n"+
		"     -band 192,26,-0.32,0.04         drain cyan from icy cliffs\n"+
		"     -band 200,22,0.2,-0.1,0,.55,1,.45  blues, lower 45% only")
	flag.Var(&regions, "darken", "x,y,w,h,factor as fractions of the image — repeatable.\n"+
		"e.g. -darken 0.62,0.30,0.08,0.10,0.35  a tunnel mouth to 35% lightness")
	flag.Parse()

	if *in == "" || *out == "" {
		fmt.Fprintln(os.Stderr, "repaint: --in and --out are required")
		flag.Usage()
		os.Exit(2)
	}

	var bs []band
	for _, s := range bands {
		b, err := parseBand(s)
		if err != nil {
			fmt.Fprintf(os.Stderr, "repaint: --band: %v\n", err)
			os.Exit(2)
		}
		bs = append(bs, b)
	}
	var rs []region
	for _, s := range regions {
		r, err := parseRegion(s)
		if err != nil {
			fmt.Fprintf(os.Stderr, "repaint: --darken: %v\n", err)
			os.Exit(2)
		}
		rs = append(rs, r)
	}

	f, err := os.Open(*in)
	if err != nil {
		fmt.Fprintf(os.Stderr, "repaint: cannot open --in %q: %v\n", *in, err)
		os.Exit(1)
	}
	src, err := png.Decode(f)
	f.Close()
	if err != nil {
		fmt.Fprintf(os.Stderr, "repaint: %q is not a readable PNG: %v\n", *in, err)
		os.Exit(1)
	}

	b := src.Bounds()
	dst := image.NewRGBA(b)
	touched := 0
	for y := b.Min.Y; y < b.Max.Y; y++ {
		for x := b.Min.X; x < b.Max.X; x++ {
			r16, g16, b16, a16 := src.At(x, y).RGBA()
			r, g, bl := float64(r16)/65535, float64(g16)/65535, float64(b16)/65535
			h, s, l := rgbToHSL(r, g, bl)
			changed := false
			fx := (float64(x-b.Min.X) + 0.5) / float64(b.Dx())
			fy := (float64(y-b.Min.Y) + 0.5) / float64(b.Dy())
			for _, bd := range bs {
				// Fully desaturated pixels have no meaningful hue, so a band must
				// not grab them — otherwise "boost the reds" tints every grey.
				if s <= 0.08 || hueDist(h, bd.hue) > bd.tol {
					continue
				}
				if bd.hasBox && !(fx >= bd.bx && fx < bd.bx+bd.bw && fy >= bd.by && fy < bd.by+bd.bh) {
					continue
				}
				s = clamp(s + bd.dSat)
				l = clamp(l + bd.dLight)
				changed = true
			}
			for _, rg := range rs {
				if fx >= rg.x && fx < rg.x+rg.w && fy >= rg.y && fy < rg.y+rg.h {
					l = clamp(l * rg.factor)
					changed = true
				}
			}
			if changed {
				touched++
			}
			nr, ng, nb := hslToRGB(h, s, l)
			dst.Set(x, y, color.RGBA{u8(nr), u8(ng), u8(nb), uint8(a16 >> 8)})
		}
	}

	o, err := os.Create(*out)
	if err != nil {
		fmt.Fprintf(os.Stderr, "repaint: cannot write %q: %v\n", *out, err)
		os.Exit(1)
	}
	defer o.Close()
	if err := png.Encode(o, dst); err != nil {
		fmt.Fprintf(os.Stderr, "repaint: encoding %q: %v\n", *out, err)
		os.Exit(1)
	}
	total := b.Dx() * b.Dy()
	fmt.Printf("%s  %d x %d, %d px adjusted (%.1f%%)\n",
		*out, b.Dx(), b.Dy(), touched, 100*float64(touched)/float64(total))
}

func clamp(v float64) float64 { return math.Max(0, math.Min(1, v)) }
func u8(v float64) uint8      { return uint8(math.Round(clamp(v) * 255)) }

type multiFlag []string

func (m *multiFlag) String() string     { return strings.Join(*m, " ") }
func (m *multiFlag) Set(s string) error { *m = append(*m, s); return nil }
