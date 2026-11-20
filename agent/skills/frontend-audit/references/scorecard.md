# Scorecard: merge and publish

The scorecard is a claude.ai Data (dashboard) artifact: a page that reads three
file datasets. The 2026-11-19 run is
https://claude.ai/artifact/U2D4J38Rqyd1BzniJnsjVd (slug
`dad1eaf8-31f0-45f5-8397-fa7f105f5b64`). Reuse it each run; make a new one only
if it is gone. Read the artifact type's instructions first (the `guide` /
`describe_type` tools, and `read_file` on the artifact's `SKILL.md`); this
note does not replace them.

## Merge

From `results/*.json` write three JSON arrays:

- `scores.json`: one row per frontend: `frontend` (name), `key`, `stack`,
  `overall`, the nine category scores flat (null for N/A), `top_fix` (title of
  the first high fix), `notes`.
- `fixes.json`: one row per fix: `frontend`, `priority`, `title`, `detail`,
  `firefox`, `effort`.
- `ffrisks.json`: one row per risk string: `frontend`, `risk`.

## Diff against last run

Read the previous `scores.json` (`read_asset` on the live artifact's dataset
file, before replacing it). Report overall movement per frontend and any
category that moved 2+ points. Treat under 5 overall points as noise, so
name only overall moves of 5 or more.

## Refresh

1. `upload_asset` the three files; note each returned `/_blob/<id>` URL.
2. Repoint the datasets: `db_write` `update` on `datasets/scores`,
   `datasets/fixes`, `datasets/ffrisks`, setting `source.url` to the new URL
   and `updated: {at, by}`. Keep `fixed: true`.
3. Edit `assets/scorecard.html` for the run (counts such as "17 frontends",
   the lede, the method note: reviewer count, whether `legacy-scan` ran or was
   denied by the permission classifier, which targets were read from a fresh
   clone). Write it to the artifact's `files/index.html` document. It opens
   with `<meta name="dash-one-writer">`; read the type's `one-writer.md`
   before changing it.
4. Read the artifact's `check` and `runs` documents (`data/users/me`) and fix
   any fault before handing over.

`assets/scorecard.html` is the page source from the 2026-11-19 run. Run-specific
prose is replaced with `[N]` and `[REWRITE ...]` markers: fill every one from
the new results (counts, lede, Firefox notes, recommendations, method note).
Keep prose generic about targets from the local targets file; a target's name
still appears in the data tables, so for a target that must not be shown, use
a neutral label (for example "Extra target 1") in its result `name` and
tell the operator the mapping in the terminal only.

## If the artifact is gone

Create a new one from the Data (dashboard) type with `create_from_type`, write
the three datasets and `files/index.html` in one batch, and tell the operator
the new URL.
