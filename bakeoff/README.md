# Bakeoff Harness

Compares Claude Code against locally-hosted models (via Ollama on the R9700)
on real coding tasks. The harness is here; methodology, historical reports,
and the broader "when to re-run" guidance live in [`docs/bakeoffs/`](../docs/bakeoffs/).

## Quick start

```bash
./run.sh                                              # all prompts × default lineup
./run.sh 03 07                                        # only prompts 03 and 07
GEN_MODELS=gemma4:31b,gpt-oss:20b ./run.sh            # override local lineup
SKIP_CLAUDE=1 GEN_MODELS=gpt-oss:20b ./run.sh         # add a generator to an
                                                      # existing run (skip Claude)
CLAUDE_MODEL=opus ./run.sh                            # pin Claude model
```

Each run lands in `results/<timestamp>/` (gitignored — see below for what to
promote into `docs/bakeoffs/`):

```
results/20260516-111812/
├── 01-go-http-handler.claude.md
├── 01-go-http-handler.gemma4_31b.md
├── 01-go-http-handler.gemma4_26b.md
├── 01-go-http-handler.gemma4_e4b.md
├── 02-...
├── summary.tsv          # per-generation: seconds, tokens, bytes, cost
├── grades-claude.tsv    # populated by the interactive Claude judge (manual)
├── grades-gemma.tsv     # populated by ./grade-gemma.sh
└── judge-raw/           # raw judge transcripts (for inspection)
```

## Grading

Two-judge methodology — neither sees the other's grades.

1. **Claude session** reads each response and writes `grades-claude.tsv`
   directly. Interactive; needs a real chat with the assistant.
2. **Local model judge** (batched, fast):
   ```bash
   ./grade-gemma.sh results/<timestamp>            # default: gemma4:26b
   JUDGE_MODEL=gemma4:31b ./grade-gemma.sh ...     # swap judge model
   JUDGE_MODEL=gpt-oss:20b ./grade-gemma.sh ...    # also supported
   ```

   Generators are auto-discovered from `*.<slug>.md` files in the results dir,
   so adding a new generator means just dropping the new outputs in and
   re-running the grader. Output filename uses the judge slug:
   `grades-gemma.tsv`, `grades-gpt-oss.tsv`, etc.

The grader picks the right reasoning-suppression knob per model family:
gemma uses `think: false`, gpt-oss uses `reasoning_effort: "low"` plus a
system message (the former is ignored by gpt-oss). See
[`docs/bakeoffs/README.md#gotchas`](../docs/bakeoffs/README.md#gotchas).

## The prompts

| # | Topic | Stack |
|---|---|---|
| 01 | HTTP handler with validation | Go + pgx |
| 02 | Identify race condition in worker pool | Go |
| 03 | Table-driven tests | Go + testify |
| 04 | Translate Go function to TS | Go → TS/Bun |
| 05 | Hono route with Zod validation | TS + Hono + Zod |
| 06 | Drizzle schema migration | TS + Drizzle + PG |
| 07 | Refactor async spaghetti (find bugs too) | TS |
| 08 | Architecture design (HMAC webhook + PG queue) | TS — design only |

Each prompt is self-contained so identical text is fed to every generator.

## Fairness

- Claude runs with `--disallowedTools "Bash,Read,Write,Edit,Glob,Grep,WebFetch,WebSearch,Agent,NotebookEdit"`
  — pure text response, apples-to-apples with Ollama. Real Claude Code with
  tools enabled is **not** what this benchmark measures.
- Per-task token counts and `total_cost_usd` are captured for Claude via
  `--output-format json`; Ollama models report `prompt_eval_count` and
  `eval_count` via the API.
- Wall-clock is script-start to script-end per generation, not raw token
  throughput. Includes Ollama model-swap latency (no two ≥17 GB models
  co-reside in 32 GiB VRAM).

## Promoting a run to the historical record

`results/` is gitignored. When a run is worth keeping (GPU change, model
upgrade, etc.) write up a summary as
`docs/bakeoffs/YYYY-MM-DD-<trigger>.md` — see the existing reports for shape.
Raw artifacts stay on disk under `results/` until you clean them up manually.
