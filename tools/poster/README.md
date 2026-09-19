# poster

Composites generated art into a print-ready magnet SVG. Built for **IDEA-52**.

```
go build -o poster .
./poster --art /srv/comfyui/output/idea52-final/matterhorn.png \
         --place "Matterhorn" --country "Switzerland" --out matterhorn.svg
```

## Why the type is not in the art

IDEA-52 decided up front that typography is applied **post-generation**: in-model
lettering cannot hold one font, kerning and placement across a set, and it is not
vector-crisp. The spike then confirmed it three times — the very first smoke-test
image produced `SILCR MANINE` unprompted, and depth-preprocessed towns produced
garbled display type across a quarter of the frame.

So `sdxl_trackb.py` generates art with no text in it, and this puts the frame and
title around it. The type is real vector type, identical on every magnet.

## Millimetres, not pixels

The output is a physical object, so the SVG carries real `mm` dimensions. A print
shop opening it gets the intended size without anyone agreeing a DPI first.

Defaults are the chosen **8 × 5.5 cm** magnet in portrait, laid out as a
**polaroid**: a thin even frame on the top and both sides, and a deeper band at the
bottom carrying the place name alone.

| | |
|---|---|
| trim | 55 × 80 mm |
| bleed | 3 mm |
| frame, top and sides | 3 mm |
| art panel | 49 × 63 mm — **derived** |
| bottom band | 14 mm — **derived** |

**The bottom band is derived, not chosen.** Given the frame width, the panel's
height follows from the art's own aspect, so the panel matches the image exactly
and nothing is cropped; whatever remains is the band. At 3 mm that lands on a real
Polaroid's proportions (bottom about 4.7× the side) without being tuned for it.
Pass `--title-band` to pin the band instead.

The first layout copied the Nikko reference — a 4 mm frame all round and a
two-line title with the country beneath. It spent the top of a small object on a
frame. `--country` still works and centres the pair as a block; it is off by
default.

**One type size for the set, set by the longest name.** At 6 mm "GLACIER EXPRESS"
measured 60.6 mm against a 49 mm panel. 4.6 mm with 0.25 mm tracking fits it with
1.2 / 1.6 mm to spare. Sizing each name to its own width would read as three
different posters.

**The frame width is assumed, not measured** off the physical magnets. Note that a
thin frame is where trim tolerance shows: a ±1 mm cut makes a 3 mm border read
anywhere from 2 to 4 mm, so ask the vendor what their tolerance is.

## The output is validated before it is written

XML forbids `--` inside a comment. An earlier version of this template had a
comment naming the `--title-band` flag, and produced an SVG that Chrome showed as
a parse error while this program exited 0. The output is now parsed before it is
written and the program refuses rather than writing a broken file; the place name
is also made comment-safe, since it is interpolated into one. `go test` covers
both, including that the guard actually rejects the original failure.

## Fonts are embedded, not referenced

Both weights are base64'd into the SVG. An SVG that *names* a font it does not
carry is the classic print failure — the RIP substitutes silently, the kerning the
set depends on is gone, and nothing on screen shows it happened.

The two lines are deliberately different weights: on the Nikko reference the place
is heavy and the country noticeably lighter, and setting both bold reads as a
different poster at a glance.

Liberation Serif is the default because it is on the box, not because it matches
the reference. The reference lettering is a higher-contrast serif; swap with
`--font` / `--font-regular` / `--font-family` once the real face is identified.

## Rendering a proof

No SVG rasteriser is installed on this host, but Chrome is:

```
google-chrome --headless --disable-gpu --no-sandbox --hide-scrollbars \
  --force-device-scale-factor=3.125 --window-size=231,325 \
  --screenshot=out.png "file://$PWD/matterhorn.svg"
```

`231 × 325` is trim-plus-bleed (61 × 86 mm) at 96 CSS dpi; the 3.125 scale factor
takes it to 300 DPI. Note `librsvg` in Alpine does **not** ship `rsvg-convert`.
