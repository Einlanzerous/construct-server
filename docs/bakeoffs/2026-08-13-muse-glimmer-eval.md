# Bakeoff: muse-glimmer:30b evaluation

**Date:** 2026-08-13
**Trigger:** New `muse-glimmer:30b` released (Meta, Apache 2.0) — a 30B causal LM
with a perception encoder, distilled from Muse Spark and pitched at agentic work
on consumer hardware. At 18 GB q4_K_M it lands in the same VRAM class as
`gemma4:31b` (19 GB), so it is a drop-in candidate for the local coding role.
**Ticket:** SERV-95
**Run:** `results/20260813-194850/` — 8 prompts × 2 generators = 16 generations.
**Lineup:** muse-glimmer:30b · gemma4:31b (reigning local champ)
**Judges:** Claude session (interactive) + gemma4:31b (local, batched). Neither saw the other's grades.

> **Claude was deliberately not run this time** to conserve session budget, so
> there is no reference line in this report. The Claude numbers in
> [2026-06-08](2026-06-08-gemma4-12b-eval.md) (GPA 4.00, $1.11 for the 8 prompts)
> are two months and at least one model generation stale — do not treat them as
> current. Re-running the Claude side is the open follow-up on SERV-95.

## Result

| Generator | Claude-judge GPA | Local-judge GPA | avg latency | avg output tok | avg visible bytes |
|---|---|---|---|---|---|
| **muse-glimmer:30b** | **3.50** | 3.38 | 118.5s | 2864 | 2389 |
| gemma4:31b | 2.88 | **3.75** | 92.5s | 1846 | 3027 |

**The two judges disagree on the ranking.** That has not happened before — the
2026-06-08 run's headline was that both judges produced the identical ordering.
Resolving that disagreement is most of what this report is about, and the short
version is that the local judge should not be trusted on this particular run.

## The local judge was grading its own homework

`gemma4:31b` is both a **generator and the judge** here. That was also true on
2026-06-08, but it did not bite then, because Claude was in the lineup as an
external anchor and the rankings agreed anyway. With Claude skipped, the field
is two models and the judge is one of them. It is no longer a judge with a
sibling in the field; it is a **competitor scoring itself against its only
rival**.

The clearest symptom is range compression. **The local judge never issued a grade
below B** — across all 16 grades its entire range was A/B, including for a
handler that does not compile and a test suite that fails. Its own rubric is
explicit that "a buggy answer is a D or F regardless of whether the others are
also buggy". It did not apply that once.

Within that compressed range the asymmetry runs one way. It **never once graded
itself below me**: higher on 6 of 8 prompts, tied on the other two. It graded its
opponent below me on 3 of 8. In fairness the one time it was *more* generous to
muse-glimmer than I was — prompt 05 — is the single prompt where muse-glimmer
genuinely failed, which is leniency rather than favouritism, and cuts the same
way.

## Two grades were settled by running the code, not reading it

Every previous report carried the caveat that "won't compile" judgments came
from reading rather than from actually running `go build` / `go test`. Two of
this run's contested grades were checkable, so I checked them. Both broke
against the local judge.

**Prompt 01 — `go build` against pgx v5.10.0:**

```
muse-glimmer_30b   → BUILD OK
gemma4_31b         → BUILD FAILED
  ./h.go:9:2:  "github.com/google/uuid" imported and not used
  ./h.go:10:2: "github.com/jackc/pgx/v5" imported as pgx and not used
```

The local judge gave that a **B**, describing the unused `google/uuid` as a
constraint violation "even though it isn't actually used in the logic" — without
registering that in Go an unused import *is a compile error*. It missed the
second one entirely.

**Prompt 03 — `go test` against the real `ParseRef`:**

```
muse-glimmer_30b   → ok    ticket  0.002s
gemma4_31b         → FAIL  TestParseRef/non-numeric_suffix_(mixed_characters)
                            Error: An error is expected but got nil.
```

`Sscanf("12a34", "%d", &num)` reads `12` and returns `nil`; it does not reject
trailing garbage. The prompt explicitly required the file "compile and pass with
`go test ./...`". The local judge gave it an **A** and praised its rigour.

Two independent, mechanically verifiable requirement failures, both graded A or
B by the local judge. That is the evidence for discounting it here — not a
matter of taste.

The same `Sscanf` trap caught `gemma4:12b` on prompt 03 in the 2026-06-08 run.
It is now a **reliable discriminator** in this suite, and worth keeping.

## Per-prompt grades

`◇` marks judge disagreement.

| # | Topic | muse (mine / local) | gemma (mine / local) |
|---|---|---|---|
| 01 | Go HTTP handler | A / A ✓ | **C** / B ◇ |
| 02 | Go concurrency bug | B / B ✓ | A / A ✓ |
| 03 | Go table tests | A / B ◇ | **C** / A ◇ |
| 04 | Go → TS translation | A / B ◇ | B / A ◇ |
| 05 | Hono + Zod route | **D** / B ◇ | B / A ◇ |
| 06 | Drizzle migration | A / A ✓ | B / A ◇ |
| 07 | TS async refactor | A / B ◇ | B / A ◇ |
| 08 | Webhook architecture | A / A ✓ | B / B ✓ |

## Failure modes

**muse-glimmer fails rarely but hard.** Seven of eight answers are A-grade; the
eighth (prompt 05) is a D. It omitted the `if (!result.success)` guard in the
Hono `zValidator` hook, so the handler returns its 400 body unconditionally —
under strict TS `result.error` does not exist on the success arm, so it does not
type-check, and at runtime every *valid* request either 400s or throws. This is
the inverse of the `gemma4:12b` profile from June ("almost right, every time"):
muse-glimmer is mostly exactly right, then occasionally confidently wrong about
a middleware contract. Worth noting the local judge *identified this bug
correctly*, called it "critical", and still awarded a B — its rubric says a buggy
answer is a D or F regardless.

**gemma4:31b fails the way the June report rejected `gemma4:12b` for.** Its
answers are consistently well-organized and consistently carry exactly one
disqualifying defect: two unused imports on 01, a failing assertion on 03, dead
null-checks contradicting its own discriminated union on 04, a no-op
`try/catch` the prompt told it not to write on 05, a comment contradicting the
code beneath it on 07, and a schema referencing an `updated_at` column it never
declared on 08. None are catastrophic. All of them are the difference between
code that runs and code that does not.

**Where muse-glimmer was genuinely stronger**, beyond just avoiding defects: it
was the only one to dedupe webhooks on `X-GitHub-Delivery` (the thing that makes
at-least-once safe given GitHub's own retries), the only one to catch that
`concurrency <= 0` deadlocks on a zero-capacity channel, and the only one to
reconcile "idempotent SQL" against "what drizzle-kit would actually emit" by
giving both.

**Where gemma4:31b was genuinely stronger**: it was more precise on the Go 1.22
loop-variable semantics, correctly kept the semaphore outside the goroutine on
02 where muse silently unbounded goroutine creation, and gave the sharpest
reason not to persist invalid-HMAC payloads (disk-fill DoS).

## On the token and latency numbers

**muse-glimmer's output-token count is not a verbosity measure.** It emits ~2×
the tokens per visible byte that gemma does, consistently across all 8 prompts
(0.50–1.65 B/tok vs 0.99–2.37). It is not tagged a thinking model and its
`.response` is always populated, but it plainly reasons internally and does not
surface it. So it is simultaneously the more *expensive* generator per answer
and the more *concise* one in what it actually writes — 2864 output tokens for
2389 visible bytes, against gemma's 1846 for 3027.

Practical consequence: it is ~28% slower per answer (118.5s vs 92.5s) and that
gap widens on hard prompts (prompt 07: 214s vs 80s). For unattended loop work
that is fine. For anything interactive it is a real cost.

Latency here is confounded as usual — 18 GB and 19 GB cannot co-reside in the
R9700's 32 GiB, so every generation paid a model swap. Treat it as directional.

## Recommendation

**Switch the default local coding generator to `muse-glimmer:30b`**
(`CENTRIFUGE_OLLAMA_MODEL`, autonomous loops), and keep `gemma4:31b` pulled.

The reasoning is deliberately narrow: on the only two prompts where correctness
could be *mechanically settled*, gemma4:31b shipped code that does not compile
and a test suite that does not pass, and muse-glimmer shipped neither. The June
report rejected `gemma4:12b` on exactly that standard. Applying it consistently
means gemma4:31b loses the role.

Caveats that should temper how hard you lean on this:

- **n=8, single run, one D.** Prompt 05 shows muse-glimmer can be confidently
  wrong about framework middleware contracts. Do not assume its output wires up
  correctly just because it usually compiles.
- **The 3.50 vs 2.88 gap is much narrower than June's 3.62 vs 2.00.** These are
  peers, not tiers apart.
- **The local judge did not corroborate this**, and while I think it is wrong
  for the reasons above, that is one judge's word against another's on 6 of the
  16 grades.

## Follow-ups

1. **Re-run the Claude reference line** (open on SERV-95). Two months stale, and
   with Claude absent this run had no external anchor — which is precisely what
   let the self-judging problem go unchecked.
2. **Stop using a generator as the judge.** Either keep a non-competing local
   judge in the lineup, or run a third judge. Recorded as a new gotcha in
   [`README.md`](README.md#gotchas).
3. **Fold `go build` / `go test` verification into the harness.** It settled two
   contested grades here in under a minute and removed the standing "judged from
   reading" caveat for the Go prompts. Prompts 01–04 are all mechanically
   checkable; 05–07 would need a tsc pass.

## Harness change made for this run

`grade-gemma.sh` discovered prompt names and generator slugs by globbing
`*.claude.md`, so it aborted with `no *.claude.md found` on any `SKIP_CLAUDE=1`
run — a workflow the README documents. Claude's answers were never a reference
(the rubric grades absolutely); those files were purely an enumeration handle.
It now anchors on any generator, still preferring `claude` when present so A1
ordering matches the historical reports.

## Caveats

- Single run, n=8 per generator, default sampling — one data point, not a distribution.
- Wall-clock includes Ollama model-swap latency on every generation; directional only.
- Grades for prompts 05–08 are from reading, not execution. Prompts 01 and 03
  were verified by running them (Go 1.26.3, testify v1.9.0, pgx v5.10.0).
- The local judge graded its own output. See above.
