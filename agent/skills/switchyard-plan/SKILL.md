---
name: switchyard-plan
description: Use when a session is about to write, submit or revise a plan for a Switchyard ticket in any project (SWY, SERV, CHRN, CANT and the rest), or is answering plan feedback or a plan review. Covers the plan tool sequence, what a submission needs, what the refusals mean and what stays with the operator.
---

# Switchyard plan

A plan is a pull request against the ticket. It goes through the plan tools and
nowhere else: it is not printed to the console as the deliverable and not posted
as a ticket comment.

## Before writing

1. Call `get_plan`. A 404 means the ticket has no plan yet, not that something
   is wrong, and not that the ticket is missing.
2. No plan yet: call `open_plan_draft` before you write, so the ticket shows
   Drafting. Only a submitted revision gets you out of a draft, so open one only
   when you mean to submit.
3. A plan exists: call `get_plan_feedback` (below) and revise. Do not open a
   second plan or start over.
4. In the switchyard repo, also run plan-preflight (its own skill); its submit
   gate needs that checkout.

## What `submit_plan` needs

- A narrative of two to three sentences, which reads first.
- Acceptance criteria that can be checked one by one, each saying how. They are
  the contract the build is verified against.
- Sections ordered consequence-first: problem, approach, schema, API, toggles,
  rollout, observability, and only then frontend, tradeoffs, out of scope. Cover
  the whole change, not the visible part. Keep anchors stable across revisions.
- Rulings as data in `rulings`: each either/or is a question with two to eight
  options, each option's consequence, and a recommended option. Do not leave a
  question in prose, and do not mark one with a glyph in the text (422
  `rulings_prose`).
- Do not move the ticket; submitting does that.

## Feedback and revising

Call `get_plan_feedback` before `revise_plan`. Threads and reviews belong to a
revision, and once the next one lands the fix list you wanted is one back.
Answer every outstanding review note, criterion note and unresolved thread. Send
ONE `revise_plan` carrying the complete document, since a revision is not a
patch. An empty fix list on a plan in review means wait for a verdict. After a
supersede, the feedback carries the reason; answer it in the next revision.

## Refusals

- 409: the plan is approved. Do not resubmit. If the approach has to change, ask
  the operator, who supersedes it.
- 422 `plan_stuck`: the revision cap was hit. Stop and say so; only a person
  removes the `plan-stuck` label. Do not retry.
- 429: hourly limit. Wait `Retry-After` seconds, try once, never loop.
- Any other 422 names the field. Fix it and send once.

## Not yours

Never approve a plan and never pick a ruling; there is no tool for either.
Propose rulings, recommend, and leave the choice to the operator.

## Review and report

Where the project has no plan reviewer wired (its `REVIEW.md` has no
`## Reviewing a plan`; construct-server is one), have a fresh-context subagent
review the draft before you tell the operator it is ready, and say that you did.

After submitting or revising, tell the operator the ticket key, the revision
number and the plan state.
