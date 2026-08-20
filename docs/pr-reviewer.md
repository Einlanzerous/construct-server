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

```yaml
# .github/workflows/pr-review.yml
name: PR Review

on:
  pull_request:
    types: [opened, ready_for_review, synchronize]
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
3. `synchronize` without the `review:always` label → skip. **This is the common
   case; a green check after pushing fixes usually means this fired.** Comment
   `@claude review` to force a re-review.
4. Empty diff → skip.
5. Bot-authored release PR whose changed paths are all generated release
   material → skip. The expected set is **derived from
   `release-please-config.json` on the base ref** — manifest, `changelog-path`,
   and every `extra-files` target — so adding an `extra-files` entry cannot
   silently un-match the skip. `release_files` is the fallback for repos with no
   config (release-please in non-manifest mode).
   The test is a **subset**, not set equality: a repo running release-please in
   non-manifest mode touches only `CHANGELOG.md`, and an equality test would
   never fire there. Anything *outside* the list falls through to the rules
   below; if it reaches the reviewer it fails, deliberately, because
   `claude-code-action` refuses bot-initiated runs and unreviewed code riding a
   release PR should be loud.
6. Everything in `.github/review-ignore` → out of scope. Nothing left → skip.
7. Documentation only → skip.
8. Otherwise review, at the deeper tier if `sensitive_paths` matched.

## Gotchas worth knowing before you change it

- **`gh` does not read `GITHUB_REPOSITORY`.** It resolves from `--repo`, then
  `GH_REPO`, then the working directory's git remotes. The triage job never
  checks out, so `GH_REPO` is set at job level. Without it the job still passes
  on a long-lived runner — because `git clean -ffdx` does not remove `.git`, so a
  previous run's checkout is still there — and fails on a fresh one.
- **`jq`'s `//` fires on `false`, not just `null`.** `.is_error // true` turns a
  successful run into a malfunction. The classifier tests `has("is_error")`.
- **`claude-code-action` fails runs it completed.** It throws when `num_turns`
  exceeds `max_turns` even on a run the SDK allowed to finish. The workflow reads
  the result message from the execution file and decides for itself; the action's
  exit code is an input to the verdict, not the verdict.

## Related

- `REVIEW.md` — this repo's own review standards.
- `PRINCIPLES.md` — estate-wide defaults the reviewer also applies.
- SERV-59 (the reviewer), SERV-87 (the check now means something), SERV-92 (this
  extraction), SGNT-36 (adopting it without thinking about the inputs).
