---
name: frontend-audit
description: Use when asked to "audit the frontends", run a "frontend quality audit" or the "quarterly frontend audit" across the estate. Fans reviewer subagents out over every frontend, scores each against Chrome's Modern Web Guidance with Firefox as the primary browser, refreshes the scorecard page and files one ticket per project. Not for a single UI PR; that is the REVIEW.md Frontend block.
---

# Frontend audit

A quarterly, Firefox-first quality read of every estate frontend. It scores
source against Chrome's Modern Web Guidance
(https://developer.chrome.com/docs/modern-web-guidance), refreshes one
scorecard page, and files the high-priority fixes as tickets. The PR-time
check is not this skill: it is `references/review-checklist.md`, pasted into
each frontend repo's `REVIEW.md`.

## Hard rules

- **Firefox is the primary browser.** The guidance is a quality bar, not the
  target. Every fix states its Firefox support; a Chromium-only feature with
  no fallback is a defect, not a suggestion.
- **construct-server is public.** This skill, its references and its PR name
  no surface that is not already public in the repo. Extra targets come from
  the local file below and stay in it.
- **Switchyard is shown to other people.** Tickets, comments and the scorecard
  carry no health values (Plimsoll), no personal figures (Sextant), and no
  private surface or its name. Audit those from code alone, read no data, and
  write fixes in generic terms. Honour anything a project's description says
  stays off the board.
- **Reviewer subagents are read-only.** They read source, CLAUDE.md and build
  config and write only their one result file in the scratchpad. No installs,
  no builds, no edits in a checkout.
- The audit reads source. It runs no browser or Lighthouse; say so on the page.

## 1. Targets

Build the list from two places:

1. Every non-archived Switchyard project (`list_projects`) whose repo has a
   frontend. Find the repo checkout under `~/projects` and its web directory.
2. The extra targets file `~/.config/frontend-audit/targets`: local,
   untracked, one `KEY | NAME | SOURCE | WEB_DIR` line each. Read it. If it is
   missing, create it with the header comment from
   `references/targets-format.md` and tell the operator it is empty; do not
   invent entries. A `git:` source with no checkout is shallow-cloned into the
   session scratchpad.

## 2. Rubric and legacy scan

Reviewers score against `references/rubric.md`: nine categories 0-10 (N/A
allowed) and an overall 0-100.

Try `npx modern-web-guidance legacy-scan` on each web directory and hand its
JSON to that frontend's reviewer. The session's permission classifier may
block it. If it is denied, do not work around it (no alternate install, no
vendored copy): the reviewers grep for the legacy patterns by hand, and the
scorecard's method note says the legacy column is a manual approximation.

## 3. Fan-out

About three frontends per subagent, run in parallel and read-only. The prompt
template is `references/reviewer-prompt.md`. Each subagent writes one JSON per
frontend to `<scratchpad>/results/<key>.json`, in the shape of
`assets/example-result.json` (schema in `references/result-schema.md`). Check
each file parses and carries all nine category keys before merging.

## 4. Merge and publish

Follow `references/scorecard.md`: merge the results into `scores.json`,
`fixes.json` and `ffrisks.json`, upload them to the scorecard artifact,
repoint its datasets, and republish the page from `assets/scorecard.html`
after rewriting its run-specific prose. When a previous run's scores exist,
diff against them and say who moved.

## 5. File work

Follow `references/ticket-workflow.md`: one ticket per project holding that
project's high-priority fixes, honouring each project's `review_mode`, then
optionally drive them with the worker brief in
`references/worker-brief.md`.

## Report

Tell the operator the scorecard URL, the median and who moved since last run,
whether `legacy-scan` ran, the ticket keys filed, and which targets could not
be read.
