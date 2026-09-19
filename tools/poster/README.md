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

Defaults are the chosen **8 × 5.5 cm** magnet in portrait, laid out like the Nikko
reference — art panel inside a cream frame, title band beneath:

| | |
|---|---|
| trim | 55 × 80 mm |
| bleed | 3 mm |
| cream frame | 4 mm all round |
| title band | 11 mm |
| **art panel** | **47 × 61 mm → 0.7705** |

The workflow generates 896 × 1152 (0.7778), so `preserveAspectRatio="xMidYMid slice"`
crops about 1% of the height rather than letterboxing the art against the frame.
That is 484 DPI across the panel — no upscale step is needed for print.

**The border and title-band figures are assumed, not measured** off the physical
magnets. They were chosen so the art panel lands on the aspect already being
generated. Measuring may shift them: that is a flag here and a one-line `W, H`
change in `sdxl_trackb.py`.

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
