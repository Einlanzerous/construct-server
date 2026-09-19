# repaint

Deterministic colour corrections for flat-vector poster art. Built for **IDEA-52**.

Runs **after** `sdxl_trackb.py` and **before** `tools/poster`, on the raw art.

```
go build -o repaint .
./repaint --in art.png --out fixed.png \
  -band "0,22,0.40,0" \
  -band "192,26,-0.18,0.02"
```

## Why not just prompt for it

Some corrections are not promptable. Three rounds of increasingly explicit wording
could not put a dark tunnel mouth into the Glacier Express poster, because a
tunnel is a dark hole, a dark hole produces almost no edge in the lineart control
map, and nothing holds it. Pushing the train's red and cooling the over-icy cliffs
failed from the other side: the model averages over the whole scene.

But the output is **flat blocks of colour**, so a hue band is a genuinely separable
thing here in a way it would not be in a photograph. Selecting on it is exact and
repeatable — no model, no seed, no variance.

## A band only works when the hue means one thing

Measured on the actual art:

- **Glacier Express** — 71% of saturated pixels are 180–210°, and all of it is
  cliff. Draining that band is surgical: grey stone instead of icy teal, with the
  red train left alone at under 3% of pixels.
- **Matterhorn** — the *same* band is the sky **and** the lake **and** the shadows
  on the peak. Deepening "the lake" globally turned the whole poster turquoise.

So a band takes an optional bounding box, as fractions:

```
-band "200,24,0.20,-0.10,0,0.56,1,0.44"    # blues, lower 44% only
```

That took the Matterhorn from 41% of pixels adjusted to 17.2% — the lake deepens,
the sky does not move.

Fully desaturated pixels are never matched (`s > 0.08`), or "boost the reds" would
tint every grey. Hue distance is circular, so a red band spanning 350°–10° works.

## What this cannot do

`-darken x,y,w,h,factor` darkens a **rectangle**. That is useful for deepening a
region that is already roughly right, and it is **not** a way to add a tunnel: a
darkened rectangle on a cliff reads as a black box, which was tried and looks
exactly as bad as it sounds.

A tunnel mouth is a *shape*. If it is wanted, the natural home is the SVG in
`tools/poster`, where vector shapes are native — not here.
