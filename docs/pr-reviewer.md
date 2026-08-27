# The PR reviewer

A fresh-context review of every pull request, running in CI so that it
structurally cannot share context with whatever wrote the code, and so it fires
whether or not anyone remembers to ask (SERV-59).

The definition lives **once**, here, in
[`.github/workflows/pr-review-reusable.yml`](../.github/workflows/pr-review-reusable.yml).
Every repo calls it with ~20 lines. Before SERV-92 there were four hand-copied
forks at 998 / 465 / 370 / 360 lines.

## Why it lives in construct-server

`construct-server` is **public**, and a public repo's reusable workflows are
callable from any repo, private ones included, with no Actions-access
configuration. `switchyard` and `amber` are private, so hosting it in either
would have required loosening that. This was SERV-92's one open question and it
resolved by checking rather than assuming.

## Adding it to a repo

**Prerequisite: the repo needs its own registered self-hosted runner.** These
repos live under the `Einlanzerous` **user** account rather than an
organisation, and a user account cannot share runners between repositories — so
every adopter needs one of its own, which is why this box runs one per repo. The
`runs_on` default is `self-hosted` because the job has to reach Switchyard over
localhost.

Skipping it fails **silently**. The review job sits `queued` with
`labels=self-hosted, runner=` and GitHub holds it for 24 hours before timing it
out: no red check, no annotation, nothing in the job summary. It reads as a slow
queue rather than a missing prerequisite — on a workflow whose entire design goal
(SERV-87) is that the check's colour is load-bearing. purser sat there for 35
minutes with the caller, both files and both secrets already correct (SERV-138).
[Registering the repo's runner](#registering-the-repos-runner) is below.

```yaml
# .github/workflows/pr-review.yml
name: PR Review

on:
  pull_request:
    types: [opened, reopened, ready_for_review, synchronize]
  issue_comment:
    types: [created]

# A called workflow cannot be granted more than its caller holds, so the
# ceiling has to be set here even though the shared workflow declares them too.
permissions:
  contents: read
  pull-requests: write
  issues: read

jobs:
  pr-review:
    uses: Einlanzerous/construct-server/.github/workflows/pr-review-reusable.yml@main
    with:
      sensitive_paths: '^(src/auth/|migrations/|\.github/workflows/)'
    secrets:
      claude_code_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
      switchyard_token: ${{ secrets.SWITCHYARD_REVIEWER_TOKEN }}
```

Then add two files to the repo itself:

- **`REVIEW.md`** — what a review of *this* repo is for. Severity, the
  always-check list, the verification bar. This is where judgement lives.
- **`.github/review-ignore`** — the repo's generated artifacts, one ERE per
  line. Optional; absent means nothing is excluded.

Do **not** add a `concurrency:` key. The shared workflow owns it, and that key
is the accumulated result of three separate silent-pass incidents.

Do **not** copy `review-prompt.md`. The workflow fetches it from this repo —
`prompt_repo` / `prompt_ref`, defaulting to `Einlanzerous/construct-server@main`.

This was meant to derive from `github.job_workflow_sha` so the procedure would
pin to the workflow commit automatically. That context and `job_workflow_ref` are
both **empty** on this Actions version (verified on argosy#211 and signet#37), so
they are explicit inputs instead: **if you pin `uses: ...@<tag>`, pin
`prompt_ref` to the same tag**, because nothing links them for you.

### Registering the repo's runner

`runners/POOL-README.md` on the box covers adding a *pooled* runner to a repo
that already has one. This is the other case, and the one an adopter is in:
a repo's **first**. The house layout is `/home/magos/runners/<repo>/`, runner
named `<repo>-runner`, labels `self-hosted,Linux,X64`.

```bash
rsync -a --exclude='.credentials*' --exclude='.runner*' --exclude='.service' \
      --exclude='.env' --exclude='.path' --exclude='_work/' --exclude='_diag/' \
      /home/magos/runners/<sibling>/ /home/magos/runners/<repo>/

cd /home/magos/runners/<repo>
./config.sh --unattended --url https://github.com/Einlanzerous/<repo> \
  --token "$(gh api -X POST /repos/Einlanzerous/<repo>/actions/runners/registration-token --jq .token)" \
  --name <repo>-runner --work _work

cp /home/magos/runners/<sibling>/.path .path   # config.sh writes the configuring shell's PATH
sudo ./svc.sh install magos && sudo ./svc.sh start
```

Three things the copy can get wrong:

- **If the sibling's `bin` and `externals` are symlinks** into versioned
  directories — which is what a runner self-update leaves behind, so some of
  these are and some are not — `rsync` preserves the *absolute* targets and the
  new tree quietly runs the sibling's binaries. Repoint them:
  `ln -sfn /home/magos/runners/<repo>/bin.<ver> /home/magos/runners/<repo>/bin`,
  and the same for `externals`.
- **Use the stock service template.** `pool-service.template` is
  switchyard-pool-specific — its `BUN_INSTALL_CACHE_DIR` line exists because
  those three runners share one `$HOME` — and does not belong on a single runner.
- **Do not pass `--labels e2e`.** Exactly one runner on this box may carry it;
  `runners/POOL-README.md` has the whole argument.

A job already sitting in that 24-hour queue picks the runner up as soon as it
registers, so there is no need to cancel the run or close and reopen the PR.
purser's did.

## Inputs

| input | default | what it is for |
|---|---|---|
| `sensitive_paths` | **required** | ERE; a hit escalates to the deeper tier |
| `standards_files` | `REVIEW.md`, `CLAUDE.md`, `PRINCIPLES.md`, the reviewer's own files | `.md` files that are *not* documentation |
| `docs_skip_extra` | `''` | extra alternatives for the docs-only test, e.g. `^graphify-out/\|` |
| `max_turns` | `80` | runaway tripwire |
| `high_effort_model` / `low_effort_model` | `opus` / `sonnet` | |
| `high_effort` / `low_effort` | `high` / `medium` | |
| `switchyard_url` | `http://localhost:4002` | |
| `runs_on` | `self-hosted` | must reach Switchyard |
| `timeout_minutes` | `30` | what actually bounds a runaway |
| `release_branch_prefix` | `release-please--` | the release-PR skip |
| `release_files` | changelog + manifest | **fallback only** — where `release-please-config.json` exists the set is derived from it |
| `prompt_repo` / `prompt_ref` | `Einlanzerous/construct-server` / `main` | where the procedure is fetched from |

### `sensitive_paths` is the one that needs thought

It is the repo's own answer to *"where does a mistake widen access, lose data,
leak a secret, or make a rollback impossible?"* — and **a regex matching
everything is the same as one matching nothing**. SGNT-36 is signet doing
exactly that with `^(internal/|cmd/|...)`, which is its entire source tree: every
PR got the expensive tier, and the tier stopped carrying information. The
workflow refuses an empty value outright rather than guessing a default.

### Testing a change to `review-prompt.md`

`prompt_ref` defaults to `main`, so **a prompt edit is not exercised by its own
PR** — it goes live in all four repos when it merges. That is a deliberate
trade-off, not an oversight: fetching the procedure from the PR head would let a
pull request rewrite the reviewer's own instructions, and `review-prompt.md` is
not on `claude-code-action`'s restore list, so nothing else would stop it.

To exercise one before merging, point a caller at the PR head for a single run
and revert it in the same PR:

```yaml
    with:
      prompt_ref: ${{ github.event.pull_request.head.sha }}
```

Read what it produces knowing the reviewer was running the prompt under review.

### `max_turns` is a tripwire, not a budget

Completed reviews measured **9–50 turns, median 33** over 18 runs. A cap near 40
sits inside that distribution and clips roughly one review in five; `40` was the
original value and it was the cause of half of SERV-87. Turns are not billed —
`timeout_minutes` is what actually bounds a runaway.

## What the check means

The `review` check is the product, and its colour is load-bearing. Measured over
40 runs after SERV-87, it was correct 40 times out of 40; before, green meant
"reviewed" once in nineteen.

| check | meaning |
|---|---|
| 🟢 success | a reviewer ran to completion and posted a review |
| ⬜ skipped | triage declined — reason in the `triage` job summary |
| 🔴 failure | the reviewer did not complete, **or** it found blocking findings with `PR_REVIEW_BLOCKING=true` |

A red from turn exhaustion posts a comment on the PR naming which paths went
unread, so red is never silent.

### Why triage is a separate job

So that declining to review renders as a **skipped** job rather than a green
one. A green check that means "nothing was reviewed" is the failure SERV-87 was
filed about, and it was the majority case: of 22 `pull_request` runs sampled
before the fix, 18 were green having reviewed nothing.

The `review` job's `name` must stay static. It once carried an expression
rendering the skip reason into the check name; GitHub does not evaluate a job's
`name` when the job is skipped, so the checks list showed the raw expression
source — for exactly the case the expression existed to serve.

## Triage rules, in order

1. Not a PR, or a fork, or a non-member `@claude review` → the whole workflow is skipped.
2. Draft PR → skip. (`@claude review` overrides.)
3. `synchronize` without the `review:always` label, **on a PR the reviewer has
   already reviewed at least once** → skip. **This is the common case; a skipped
   check after pushing fixes usually means this fired.** Comment `@claude review`
   to force a re-review.

   The "already reviewed at least once" clause is the whole of SERV-126, and it
   is load-bearing. This rule is about *re*-review, and it was suppressing the
   *first* read: a PR that conflicts with its base produces **no `pull_request`
   runs at all** — GitHub evaluates the event against `refs/pull/N/merge`, which
   does not exist while the merge is unresolvable — so a PR opened conflicting
   never fires `opened`, the one action that reviews unconditionally. Every
   event it ever sees is a `synchronize` from the rebase that fixes the
   conflict, and every one of those hit this skip. argosy#194 went green in nine
   seconds having been read by nothing.

   So the question is not "which action is this" but "has anything ever read
   this PR", which closes the class rather than the instance. The count comes
   from the same `pulls/N/reviews` filter on `REVIEWER_LOGIN` that the review
   job's before/after assertion uses — hence `REVIEWER_LOGIN` living at workflow
   level, since both jobs now need it and two copies of an identity that must
   match exactly is precisely the drift this shared workflow exists to stop.

   An API error while counting resolves toward **reviewing**, not skipping:
   unreachable means unknown, and the cost of guessing wrong that way is one
   extra review rather than another silent pass.

   Closing it costs a **duplicate concurrent review** in one case: a fixup
   pushed while the `opened` review is still running sees no posted review yet,
   so it reviews too, and the action is in the concurrency key so neither run
   cancels the other. Accepted — reviewing twice is the safe direction and the
   second read sees the newer code.

   **This is the only action-gated rule.** `opened`, `reopened` and
   `ready_for_review` pass straight through it — and then go on to the rules
   below, which apply to every action alike. Note what that means for
   **`reopened`**: closing and reopening a PR that already has three reviews
   buys a fourth, no `review:always` needed. Deliberate — it is the one way back
   into a PR that opened conflicting and became mergeable with no push at all
   (the residual gap SERV-126 leaves open), for anyone who thinks to use it.
4. Empty diff → skip.
5. Bot-authored release PR whose changed paths are all generated release
   material → skip. The expected set is **derived from
   `release-please-config.json` on the base ref** — manifest, `changelog-path`,
   every `extra-files` target, and the files the release TYPE writes without
   being asked (SERV-142: `node` bumps `package.json`, which no key in the
   config names) — so adding an `extra-files` entry cannot silently un-match the
   skip, and neither can a release type that owns a file. `release_files` is the
   fallback for repos with no config (release-please in non-manifest mode).
   The type map holds `node` only, because it is the only type observed to write
   anything: an unset `release-type` contributes nothing rather than assuming
   release-please's own `node` default, which would widen the skip for two repos
   on a guess.
   The test is a **subset**, not set equality: a repo running release-please in
   non-manifest mode touches only `CHANGELOG.md`, and an equality test would
   never fire there. Anything *outside* the list falls through to the rules
   below; if it reaches the reviewer it fails, deliberately, because
   `claude-code-action` refuses bot-initiated runs and unreviewed code riding a
   release PR should be loud.
6. Everything in `.github/review-ignore` → out of scope. Nothing left → skip.
7. Documentation only → skip.
8. Otherwise review, at the deeper tier if `sensitive_paths` matched.

## What a review pass writes about itself (SERV-127)

Every pass writes one small JSON file naming **which PR it reviewed and which
pass it was**, so review spend can be divided by the PR rather than by the call.

```
~/.claude/ci-rounds/<sessionId>.json
```

`CLAUDE_CONFIG_DIR` is honoured if set; otherwise `$HOME/.claude`, the same
directory Claude Code writes transcripts under.

```json
{
  "schema": 1,
  "session_id": "fc163979-fd6d-42f2-9585-b86fc9ddfbb0",
  "job_class": "pr-review",
  "pr_ref": "Einlanzerous/construct-server#215",
  "round_id": "PR_kwDOL3QhOc6bF2xY",
  "pass_n": 2,
  "repository": "Einlanzerous/construct-server",
  "pr_number": 215,
  "event": "pull_request",
  "manual": false,
  "effort": "high",
  "model": "opus",
  "outcome": "completed",
  "turns": 33,
  "run_id": "31772576197",
  "run_attempt": "1",
  "run_url": "https://github.com/.../actions/runs/31772576197",
  "prompt_repo": "Einlanzerous/construct-server",
  "prompt_ref": "main",
  "prompt_sha256": "6ae46e0b…",
  "recorded_at": "2026-08-23T23:50:06Z"
}
```

### Why it exists

Switchyard measures LLM spend by sweeping the Claude Code transcript tree
(SWY-302 / SWY-305), and the reviewer is a material slice of it — **14,510
records, 14.6% of calls, ~8.0% of notional**, across 290 sessions and 6 repos on
2026-08-22.

The unit is the problem. **A PR does not cost one review, it costs N passes**:
the workflow re-triggers while findings remain, with no cap configured. Per-call
and per-session views hide that completely — five cheap passes look better than
one expensive one right up until you divide by the PR — and a loop that will not
converge is the expensive failure mode.

### Why it cannot be recovered downstream

It was tried. The review prompt carries **no PR reference** — it is the
procedure, fetched from this repo, and nothing in it names the PR. Scanning the
*whole* transcript for PR-shaped tokens finds a candidate in **289 of 290**
sessions, but **106 of those are ambiguous**: the reviewer reads other PRs,
follows issue links and cites prior work as part of reviewing. A heuristic would
be wrong about a third of the time and would look fine doing it, because every
wrong answer is still a plausible PR number.

### Why a file and not an environment variable

The cheaper shape — set `SWITCHYARD_JOB_*` on the Review step and let the reader
pick it up alongside `cwd` and `gitBranch` — does not work, and it is worth
recording *why* rather than re-proposing it. Transcript records carry `cwd`,
`gitBranch`, `entrypoint`, `effort`, `version`, `sessionId` and the message.
**They carry no environment at all** — verified against the union of top-level
keys across every CI transcript on this host. An env var set here would be
recorded nowhere, leaving the reader nothing to correlate by.

That key union does contain `prNumber` / `prRepository` / `prUrl`, which look
like the answer and are not: they belong to `type: "pr-link"` records Claude Code
writes when a session *touches* a PR. Two of 333 CI transcripts have any, and one
of those two carries several different PR numbers.

### The fields that need explaining

- **`pr_ref` carries the repository, always.** PR numbers are not unique across
  the estate, which is why Switchyard's own convention is `SWY-191 (#247)` rather
  than a bare `#247`.
- **`round_id` is the PR's GraphQL node id**, which survives a repo rename where
  `<owner>/<repo>#<number>` does not — and keeps `round_id` from being a
  byte-for-byte copy of `pr_ref`. It falls back to `pr_ref` with a warning if the
  node id cannot be resolved. On the `issue_comment` path it is fetched with
  `gh pr view --json id`, because the comment payload's `issue.node_id` is the
  **issue** node, a different object; reading that would key one PR two ways
  depending on which event triggered the pass.
- **`pass_n` is an ordering hint, not an authority.** It counts the reviewer
  sessions *this host* has already recorded for the round, so it is exact for a
  PR whose passes all ran here and were not swept. Order by `recorded_at` and the
  transcript's own timestamps when it matters. It is deliberately **not** derived
  from prior posted reviews (an exhausted pass posts none, and that is the pass
  most worth counting), nor from `run_attempt` (that counts re-runs of one run,
  not passes across pushes), nor from a run listing (an `issue_comment` pass runs
  on the default branch, so no branch filter finds it). It is counted, not
  locked, so the duplicate concurrent review this workflow already accepts
  (SERV-126) can have two passes share a rank — the round is still right and the
  cost still sums.
- **`prompt_sha256` is the exact revision of the procedure this pass ran.**
  `prompt_ref` alone does not answer it — callers pin at different refs and
  `main` moves, which is the drift this shared workflow exists to stop. Switchyard
  had to approximate this by hashing the stable first ~1200 characters of the
  prompt, recovering 7 revisions between 2026-08-03 and 2026-08-23; this makes it
  exact, and makes "which revision of the prompt converges in fewer passes" a
  question the data can answer.
- **`job_class` is written explicitly rather than left to be derived.** Today
  `service='claude-code-ci'` *is* pr-review exactly, because this is the only
  `claude-code-action` workflow in the estate — but that is true by current fact,
  not by construction, and the moment any repo adds a second one the CI figures
  become a silent mixture with no signal (SWY-327).

### The constraint on this step

**Write-only, and it may never fail a review.** Nothing here calls Switchyard;
the file is left on disk for a reader that may be offline, behind, or absent.
Every failure inside it is a `::warning::` and `continue-on-error` is the backstop
for the ones not anticipated — the measurement path may never slow or fail the
thing it measures, which is the constraint SWY-302 placed on itself.

It runs `if: always()`, because an **exhausted** pass is the single most
interesting one to have measured — it is the non-converging tail the whole
exercise exists to price — and it is exactly the pass whose Review step failed.

The session id comes from the execution file, and the action's `session_id`
output is deliberately unused. The action sets that output on the success path
only — its catch re-emits `execution_file` and **not** `session_id` — so it is
empty on precisely the runs worth measuring. Taking it as a primary with the
execution file as a fallback would leave the interesting path running the
less-exercised branch; the execution file answers on both, so it is the only
path. Same lesson, same place, as the classifier reading that file rather than
the step's exit code.

A pass with **no** resolvable session id records nothing and says so. A sidecar
keyed on a guess is worse than an absent one, because the reader cannot tell them
apart.

Sidecars older than 60 days are swept by the step that writes them. That is
aligned to Claude Code's own `cleanupPeriodDays` (30) with headroom: past that
the transcript a sidecar annotates is gone, so keeping it buys nothing. It does
mean `pass_n` restarts on a PR whose passes span more than that — the consistent
answer rather than a lossy one, since the earlier passes are no longer observable
either.

### Consumer side

**SWY-328** owns the capture and schema; **SWY-327** owns the `job_class`
dimension the rounds hang off. Subagent transcripts carry the **parent**
`sessionId`, so one sidecar per session covers those records too — though the
reviewer runs with `--allowedTools Bash,Read,Grep,Glob` and spawns none today.

## Gotchas worth knowing before you change it

- **`gh` does not read `GITHUB_REPOSITORY`.** It resolves from `--repo`, then
  `GH_REPO`, then the working directory's git remotes. The triage job never
  checks out, so `GH_REPO` is set at job level. Without it the job still passes
  on a long-lived runner — because `git clean -ffdx` does not remove `.git`, so a
  previous run's checkout is still there — and fails on a fresh one.
- **`jq`'s `//` fires on `false`, not just `null`.** `.is_error // true` turns a
  successful run into a malfunction. The classifier tests `has("is_error")`.
- **`@claude review` runs the workflow from the DEFAULT BRANCH, not from the
  PR.** GitHub resolves an `issue_comment` workflow against the default branch,
  so a comment-triggered run has `headBranch: main` and executes `main`'s copy of
  this file — even in this repo, which calls it as `./` precisely so a change is
  exercised by its own PR. Only the `pull_request` trigger reads the PR's copy.
  Measured on SERV-127 (#152): the `pull_request` pass ran the new step and the
  `@claude review` pass, ten minutes later on the same PR, did not have it.
  Consequences worth knowing before you rely on either: a workflow change cannot
  be tested by commenting, and a second `pull_request` pass over a workflow edit
  takes either a push carrying the `review:always` label or a **reopen** —
  the prior-review skip is gated on `synchronize` alone, so `reopened` and
  `ready_for_review` reach the file rules with no label at all. The label on its
  own fires nothing; the caller does not subscribe to `labeled`. It is not a gap
  after merge: both triggers then run the same merged copy.
- **`/tmp` is one namespace across every runner on this box, and the reviewer
  used to stage its review body there.** Two runs picked `/tmp/review-body.md`
  independently, one overwrote the other between writing and posting, and a
  complete review of *another repository* landed on a PR under a green check —
  twice (SERV-137 on purser#40, SERV-143 on drydock#82). The reviewer cannot see
  it happen: `-f body="$(cat …)"` never puts the content in its context, so its
  transcript looks correct and the inline comments, which do come from context,
  are its own. Nothing had instructed `/tmp` — it is simply the obvious
  filename, which is why the fix in `review-prompt.md` is a stated rule with the
  reason attached rather than a corrected path. The before/after review count
  cannot catch it either, since the wrong body still increments the count, so the
  Gate additionally checks that the posted body carries this run's
  `<!-- pr-review: <repo>#<pr> run <id> -->` marker and names the other run when
  it does not. The marker is composed once, in the review job's `env`.
- **`claude-code-action` fails runs it completed.** It throws when `num_turns`
  exceeds `max_turns` even on a run the SDK allowed to finish. The workflow reads
  the result message from the execution file and decides for itself; the action's
  exit code is an input to the verdict, not the verdict.

## Related

- `REVIEW.md` — this repo's own review standards.
- `PRINCIPLES.md` — estate-wide defaults the reviewer also applies.
- SERV-59 (the reviewer), SERV-87 (the check now means something), SERV-92 (this
  extraction), SERV-126 (the first review a conflicting PR never got), SERV-127
  (the round export), SGNT-36 (adopting it without thinking about the inputs).
- SERV-137 and SERV-143 (one repo's review body posted to another repo's PR),
  SERV-138 (adopting it needs a runner, and the checklist did not say so).
- SWY-302 (the transcript producer), SWY-327 (`job_class`), SWY-328 (the
  consumer for the sidecar above).
