# Local LLM Bakeoffs

Reproducible head-to-head benchmark of Claude Code against locally-hosted models
(via Ollama on this server). Run when something changes that could move the
needle: GPU swap, new model release, ROCm version bump, Claude model upgrade.

The harness lives at the repo root in `bakeoff/`; this directory holds the
methodology and historical reports.

---

## What this benchmark measures

**One-shot coding quality**: given a coding task as plain text, can the model
produce a correct, idiomatic answer? Eight prompts split between Go and
TypeScript, themed around projects this server actually runs
(switchyard, imperium-loop, servo-signal).

Categories covered:
- Implementation from spec (HTTP handler, Hono route)
- Bug hunting in existing code (concurrency race, async refactor)
- Translation (Go → TypeScript)
- Test writing (table-driven Go tests)
- Schema + migration design (Drizzle + Postgres)
- Architecture writeup (queue design, no code required)

**What it deliberately does NOT measure**:
- Claude Code's tool use (Read/Edit/Bash/Grep/Agent) — disabled via
  `--disallowedTools` for fairness. Claude's real edge in interactive work
  comes from tools and won't show up here.
- Long agentic loops or multi-turn refinement.
- Codebase-wide refactors that require reading many files.

Treat the GPA numbers as **"how well does the underlying model answer a coding
question with no extra help"** — not as a proxy for which model to use in
practice. That decision depends on whether your workflow needs tools.

---

## When to run a new bakeoff

| Trigger | What to compare |
|---|---|
| Major GPU swap | Same prompts, new local model lineup, document throughput change |
| New Gemma / Qwen / Llama generation | Add it to the lineup, re-grade |
| Claude model bump (e.g. Opus 4.7 → 5.0) | Re-run Claude side, hold local fixed |
| Major ROCm / Ollama / vLLM upgrade | Spot-check 3 prompts to catch throughput regressions |
| Adding a new workload pattern | New prompt — see "adding prompts" below |

Each historical report in this folder is dated and labeled with the trigger so
you can see what changed between runs.

---

## How to run

```bash
cd bakeoff
./run.sh                                              # all 8 prompts, all default generators
./run.sh 03 07                                        # only prompts 03 and 07
GEN_MODELS=gemma4:31b,qwen3:32b,llama4:70b ./run.sh   # override local lineup
CLAUDE_MODEL=opus ./run.sh                            # pin Claude to a specific model
```

Outputs land in `bakeoff/results/<timestamp>/`. The dir is gitignored — raw
artifacts are heavy and noisy. Promote the summary to this folder when the run
is worth keeping.

### Grading

Two-judge methodology:
1. **Claude session** (this assistant) reads every response and writes
   `grades-claude.tsv` directly.
2. **Local model** judges via `./grade-gemma.sh results/<timestamp>` →
   `grades-gemma.tsv`. Defaults to `gemma4:26b` as judge;
   `JUDGE_MODEL=gemma4:31b` to swap.

Both judges are independent — neither sees the other's grades. Compare the two
to detect leniency, sibling-bias, or genuinely contested calls.

---

## Cost framing — the comparison that actually matters

For each task, capture both:

- **Claude**: wall-clock seconds, input tokens, output tokens, `total_cost_usd`
  from `--output-format json`. Cold `claude -p` invocations pay a ~16K-token
  cache-creation tax per call (system prompt + project context) — if you're
  rate-modeling a real workflow, decide whether that fee will be amortized in
  an interactive session or paid fresh every CLI shot.
- **Local**: wall-clock seconds, `prompt_eval_count` (input), `eval_count`
  (output) from the Ollama API. Marginal cost is electricity-only — call it $0.

The deliverable should answer: *"At what task volume does local become the
right choice?"* Pro tier (~$20/mo), Max tier (~$200/mo), and unmetered local
each have a sweet spot.

---

## Adding a new prompt

1. Drop a file in `bakeoff/prompts/NN-short-name.md` (zero-pad the number;
   the runner globs `prompts/*.md`).
2. Make it specific: real types, real constraints, real ambiguity to surface
   judgment calls. Vague prompts produce vague answers and uninformative grades.
3. Reference an actual project in this org when possible (switchyard,
   imperium-loop, servo-signal) — keeps grading anchored to real engineering
   taste, not generic textbook style.
4. Target 200–900 words of output. Shorter prompts get answered too easily;
   longer ones blow context budgets.

---

## Adding a new generator (model under test)

For Ollama models: just add them to `GEN_MODELS` (comma-separated). The runner
calls `/api/generate` and captures token counts.

For non-Ollama models (vLLM, llama.cpp server, OpenAI-compatible endpoint):
extend `run.sh` with a new `run_<provider>` helper that mirrors the
`run_claude` / `run_ollama` pattern. Keep the output shape identical so the
summary TSV stays uniform.

---

## Gotchas (record new ones here as they're discovered)

### Reasoning-mode models silently eat output tokens

`gemma4` (and other "thinking" models — including reasoning-tuned Qwen and
DeepSeek variants) use a built-in `<think>` parser. Calling `/api/generate`
the naive way produces an **empty `.response` field** while burning all your
output tokens on hidden chain-of-thought. The `done_reason: "length"` flag is
your only clue.

**Each model family has its own knob — pick the right one**:

| Model family | Knob | Notes |
|---|---|---|
| `gemma4:*` | `think: false` at the top level of the chat request | Works in `/api/chat`. Also accepts `num_predict: 2000`. |
| `gpt-oss:*` | `options.reasoning_effort: "low"` + a `system: "Reasoning: low"` message | `think: false` is **ignored** by gpt-oss. Even with reasoning capped, gpt-oss still burns ~1000-5000 tokens internally — set `num_predict` to 4000+ for short prompts, 8000+ when batching multiple long answers. |
| `qwen3:*` (reasoning variants) | Same as gemma — `think: false` honored | Confirm with a short smoke test. |
| `deepseek-r1:*` | `think: false` ignored; reasoning ALWAYS emits — strip via parsing `<think>...</think>` from response | Treat the deepseek family as "reasoning model where the visible response is post-reasoning". |

**Symptom-driven debugging**: if the response `content` is empty AND
`done_reason: "length"` AND `eval_count` ≈ `num_predict`, you've hit this.
The model burned every available output token reasoning. Either:
1. Find the right knob for the family (table above)
2. Raise `num_predict` until the model gets to emit visible content
3. Switch to a shorter prompt — batching 5 long answers compounds the problem

**Why the runner (`run.sh`) and grader (`grade-gemma.sh`) differ**: `run.sh`
uses `/api/generate` deliberately so generators *can* think for quality. The
grader uses `/api/chat` with reasoning suppressed because the only output
that matters is "letter grade + 2-sentence rationale" — reasoning would
crowd it out.

### `claude -p --output-format json` cache-creation tax

Every fresh CLI invocation re-bundles the system prompt and project context
(~16K input tokens). In an interactive session this caches and is essentially
free on the 2nd+ call. In a scripted batch (like this benchmark) each call
pays full freight. Numbers reported in bakeoffs are the **scripted** case —
real interactive usage is cheaper per task.

### Ollama orphan curls

Killing a long-running grader via `Ctrl-C` or `pkill -f grade-gemma.sh` does
NOT always reap the in-flight `curl` it spawned — and Ollama will keep
processing the queued request. If a re-run looks stuck, check
`ps -ef | grep "curl.*11434"` and `kill -9` any leftovers.

### Model swap latency on Ollama

The R9700 has 32 GiB VRAM. The default local lineup (`gemma4:31b` @ 20 GB,
`gemma4:26b` @ 17 GB, `gemma4:e4b` @ 10 GB, `gpt-oss:20b` @ 13 GB) all fit
individually but **cannot co-reside**. Ollama swaps weights from disk on
every model change, costing ~5–10s per swap. The runner's per-prompt loop
hits N swaps × 8 prompts — figure ~3-5 minutes of overhead for a 4-generator
run. Doesn't change the comparative result but does inflate wall-clock
numbers.

### Three judges, one truth

When running >1 local judge, run them sequentially — each judge holds the
GPU during its pass. Snapshot the previous `grades-<judge>.tsv` before
re-running with more generators: adding a 5th answer to an already-judged
batch slightly changes the model's scoring of the original 4 (context
attention shifts). The 4-gen pass and 5-gen pass are not directly
comparable; pick one and stick with it for a given report.

---

## Report template

When a bakeoff is worth keeping, write up the summary as
`docs/bakeoffs/YYYY-MM-DD-<trigger>.md`. See existing reports for shape, but
the load-bearing sections are:

1. **TL;DR table**: GPA per generator (both judges), per-task cost, wall-clock.
2. **Cost framing**: which task volume favors which provider.
3. **Per-prompt grade comparison**: my-grade / judge-grade with ✓ / ◇ for
   agreement.
4. **Why the bottom-tier models failed**: characterize the failure modes —
   omissions vs bugs vs structural. This is what tells you whether the model
   is *usable but limited* vs *not safe to deploy*.
5. **Recommendations**: where does each generator earn its place in your
   actual workflow?

Raw results (`results/<timestamp>/`) stay gitignored. Only the writeup ships.
