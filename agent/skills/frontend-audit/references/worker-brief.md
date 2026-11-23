# Worker brief: frontend quality tickets

Hand this to each subagent that implements ONE audit ticket. Fill in the
ticket key, repo and `<floor>`. The repo's own CLAUDE.md and REVIEW.md outrank it.

You implement one Switchyard ticket end to end. The ticket says what to do;
this brief says how the estate wants it done.

## Before you start
- Read `~/.claude/CLAUDE.md`, then `~/construct-server/PRINCIPLES.md` §3
  (commits and PRs) and §5 (tickets), then the repo's `CLAUDE.md` and
  `REVIEW.md`.
- Read the ticket with the Switchyard MCP `get_ticket`. Check `review_mode`:
  `evidence` means you finish it alone, including the merge. Anything else:
  stop and report.
- Firefox is the primary browser. The floor is the "Browser floor" rule in
  `~/construct-server/PRINCIPLES.md`; use the floor `<floor>` filled in
  here, or read the version there if none is given. Never introduce
  a feature the floor lacks unless it is progressive enhancement with a
  working fallback. Check MDN rather than guessing.
- Playwright's bundled Firefox works on this box. Use it for anything
  behavioural (dialogs, popovers, focus, scroll lock).

## Workspace
- Do not touch the main checkout. Create a worktree from an up-to-date
  `origin/main`:
  `git -C <repo> fetch origin && git -C <repo> worktree add ~/projects-scratch/<repo>-<key-lowercase> -b <type>/<slug>-<KEY> origin/main`
- Branch `{type}/{slug}-{KEY}`. Use `fix:` for sub-feature polish, `chore:`
  only for docs-only work. PR title `fix(web): <summary> (KEY)`; never prefix
  with the bare key.
- End each commit message and PR body with the attribution lines your session
  was given.
- Install dependencies inside the worktree only.

## Doing the work
- Verify each cited file:line before changing it; the audit read source and
  lines may have moved. Skip an item that is wrong or not worth doing and say
  why in the PR body.
- Keep changes tight. No drive-by refactors.
- Run the ticket's test command, plus lint, typecheck and build where the repo
  has them. Add a test where the ticket asks for one.
- Screenshots: when something visible changes, upload a Trestle image
  (global CLAUDE.md). Trestle URLs are public and permanent: screenshot only
  synthetic, empty or fixture data, never real photos, messages, personal
  figures or health data. If you cannot, say so in the PR body.

## PR and ticket
- `gh pr create` against main, then `attach_external_ref` with the PR URL (a
  conflict means the webhook did it). Move the ticket to In Progress with
  `transition_ticket_by_category` (`in_progress`).
- Wait for CI. If the repo has `.github/workflows/pr-review.yml`, wait for its
  review and answer every actionable comment with follow-up commits.
- If the repo has no CI reviewer, get a fresh-context review of the diff
  before merging: give a subagent only the diff and the ticket. Without the
  Agent tool, self-review against REVIEW.md and say no independent review
  happened.
- Merge when CI is green and comments are resolved:
  `gh pr merge <n> --squash --delete-branch`. Check the ticket closed
  afterwards; if not, leave it and report.
- Never merge on red CI, never force-push to main. If blocked, stop and
  report instead of working around it.
- File unrelated bugs you notice in the same project with `create_ticket`,
  with no private data (health values, personal figures, private surfaces).
- Remove your worktree when done.

## Final report (short)
Ticket key, PR URL, merged yes/no, what landed, what you skipped and why,
follow-up ticket keys, any review you could not get.
