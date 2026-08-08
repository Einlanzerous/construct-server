# Review instructions

Review-only guidance, higher priority than `CLAUDE.md`. `CLAUDE.md` describes
how this repo works; this file describes what a review of it is *for*.

`PRINCIPLES.md` sits alongside both and is **cross-repo** — the estate-wide
defaults for languages, stack, release types, and code quality. Read it too. It
tells you what "good" looks like anywhere; this file tells you what to spend the
review on here. Where they overlap, this file wins, because it is specific to a
repo that has no test suite and a live blast radius.

## What this review is for

Green CI proves the YAML parses. A human skim proves the change looks
reasonable. Neither proves the change does what the ticket asked, and neither
catches an access boundary quietly widening. **Spend the review on what the
other two cannot see.**

The highest-value finding in this repo is not a bug in the diff — it is a gap
between the diff and its ticket. Check that first, every time.

## Ticket fidelity — check this first

When a Switchyard ticket is linked, read its description and exit criteria
before the diff, and answer explicitly in the summary:

- Does the implementation actually satisfy the stated exit criteria, or only
  the easy subset of them?
- Did a requirement present in the ticket get silently dropped, narrowed, or
  deferred without saying so?
- Does the PR claim something is done that the diff does not demonstrate?

A change that is clean code and wrong scope is a **🔴 Important** finding. Say
which criterion is unmet and quote it.

When no ticket is linked, say so in one line and review the diff on its own
terms. Do not invent a ticket's intent from the branch name.

## Severity, calibrated for a config repo

- **🔴 Important** — breaks a running service, widens who can reach something,
  loses or corrupts data, leaks a secret, makes a rollback impossible, or does
  not do what the ticket asked.
- **🟡 Nit** — conventions, clarity, a comment that will mislead the next
  reader. Worth fixing, never blocking.
- **🟣 Pre-existing** — real, not introduced here. At most two per review.

Cap nits at five. If you found more, say "plus N similar" in the summary rather
than posting them inline. A review that buries one Important finding under
twelve nits has failed at its job.

## Always check

Each of these is a rule this repo learned by breaking. `CLAUDE.md` has the
incidents; these are the review-time questions.

- **Empty env vars.** Does any new or changed variable get consumed as though
  unset means "use a default"? An empty value must skip loudly, not substitute.
- **Restart vs. recreate.** Does the change alter a mount, env, or image for a
  service, and does anything in the diff or its instructions say `docker
  restart`? It must be `make recreate svc=<svc>`.
- **Blast radius of a compose action.** Does the diff invoke `docker compose up`
  against a *named* service without `--no-deps`? Compose follows `depends_on`,
  so that reaches the shared postgres and every service behind it. Scoped is the
  default; bringing dependencies up must be the deliberate choice.
- **`db/init-db.sh` idempotency.** Anything added here runs on every deploy
  against live Postgres. Is it safe to re-run?
- **Secrets.** Does a value land in a committed file, a build arg, an image
  layer, or a log line? A secret the *stack* consumes belongs in `PROD_ENV_FILE`
  on the `home-server` environment. A credential only a workflow uses is
  currently a repo-level secret managed by Signet — a deliberate interim state,
  not an oversight, so don't flag it; environment scoping for CI credentials is
  tracked separately.
- **New public routes.** A new hostname, port, or Traefik/Caddy rule — is it
  behind Cloudflare Access, and is that deliberate? Internal reachability
  proves nothing about the public path.
- **Runner tooling.** Does a workflow shell out to something installed under
  `$HOME`? It needs `$GITHUB_PATH` and an explicit availability check.
- **Workflow permissions.** Does a change under `.github/workflows/` widen a
  token's scope, add an unpinned third-party action, or run untrusted input on
  the self-hosted runner?
- **Ansible privilege.** New `become`, sudoers, or file-mode changes — is the
  grant the narrowest one that works, and is it rendered from a template?

## Verification bar

This repo has no test suite, so you cannot lean on one. That cuts both ways:
you may not dismiss a concern because "tests would catch it," and you may not
report a finding you have not actually traced through the config.

Before posting a finding, satisfy one of these:

- You read the line that causes it and can name the failure it produces.
- You can cite the specific config that contradicts the change.

Behavior inferred from a name is not evidence. If you find yourself writing
"this may not handle…", either go read it or drop it.

## Re-reviews

Round three should be shorter than round one, not longer.

After the first review of a PR: report **new Important findings only**. No new
nits, no restating findings that are already open, no re-raising something the
author explicitly declined. Note in one line what got fixed since last time,
then move on.

## Summary shape

Open with a one-line tally — `2 important, 1 nit` — or **No blocking issues**
when nothing Important came up. Then ticket fidelity in a sentence. Then the
findings, most severe first.

If the diff is clean, say so in one line and stop. Do not pad.
