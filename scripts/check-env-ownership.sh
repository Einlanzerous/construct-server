#!/usr/bin/env bash
# check-env-ownership.sh — Assert the vault claims nothing git or a deploy already owns.
#
# The stack's environment has two sources with different homes (SERV-96), and exactly
# one of them is Signet's:
#
#   PROD_ENV_FILE   the `home-server` GitHub Environment secret — Signet renders it
#   versions.env    tracked in git — the first-party image pins, which are not secrets
#
# render-env.sh merges the two into the deployed .env. That merge STRIPS every key the
# versions file defines before appending the tracked pins, so git wins and a stale copy
# in the vault changes nothing. The stripping is what made the drift SERV-94 found
# survivable — and it is also what kept it invisible until someone went looking.
#
# This asks the vault directly, so the answer does not depend on render-env.sh still
# sitting in the path. Two questions, both about ownership rather than about values:
#
#   1. Does the vault's rendered key set contain a key the versions file defines?
#      It must not. Those values move by promote/rollback commits (SERV-78, SERV-79),
#      and a second apparent source for them is a rollback waiting to happen: if the
#      vault ever became the sole source, prod would silently revert every service
#      whose vault copy had gone stale. deploy.yml's SERV-88 assertion would NOT catch
#      it, because a stale pin is a real version, not `:latest`.
#
#   2. Does the vault write a file some other process also writes?
#      It must not. `deploy.yml` regenerates $DEPLOY_ROOT/.env on every run; a Signet
#      file target on that path makes two writers on one file, so drift becomes a race
#      rather than a state — which is exactly how `file:/opt/construct-server/.env`
#      came to sit at `changed` indefinitely.
#
# File targets are judged by the property that matters — does this path have a second
# writer — rather than against a list of literal paths this script rebuilds. Prod is
# allowed NONE: Signet owns PROD_ENV_FILE and nothing else, which is the design question
# SERV-94 settled. Dev is allowed exactly one shape, a `creds/dev.env`, its readable
# credential source. Anything under a deploy root is refused outright, in either tier.
# See the note above check 2 for why the path is not reconstructed from the caller's
# location — the short version is that a checkout is one of several on this host and the
# registered target is one, so deriving it made the answer depend on where you stood.
#
# It reads only target metadata — key NAMES, destinations, states. It never calls
# `signet reveal` and never prints a value.
#
# Not a deploy gate, deliberately. The hazard is latent while render-env.sh strips the
# pins, and a red prod deploy is the wrong way to find out that a vault edit was
# careless — SERV-94 says so in as many words. Run it after touching the vault:
# a `signet target add-key`, an `import`, a re-seeded render target.
#
# Usage:
#   ./scripts/check-env-ownership.sh          # the prod project
#   ./scripts/check-env-ownership.sh --dev    # the dev project (SERV-77, SERV-93)
#
# Exit codes:
#   0  the vault claims only what is its own
#   1  an ownership violation — a git-owned key, or a file with another writer
#   2  usage error, or signet is unavailable to answer

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd)"

err() { printf '%s\n' "$*" >&2; }

# The deploy roots, which are the paths that HAVE another writer: deploy.yml and
# deploy-dev.yml regenerate `$root/.env` on every run. Same override convention as the
# Makefile, so a non-standard host answers the same question about its own layout.
DEPLOY_ROOT="${DEPLOY_ROOT:-/opt/construct-server}"
DEV_ROOT="${DEV_ROOT:-/opt/construct-server-dev}"

DEV=0
case "${1:-}" in
  --dev) DEV=1 ;;
  "") ;;
  *) err "usage: check-env-ownership.sh [--dev]"; exit 2 ;;
esac

if [ "$DEV" -eq 1 ]; then
  PROJECT="construct-server-dev"
  VERSIONS="$REPO_ROOT/dev-versions.env"
  RENDER_SECRET="DEV_ENV_FILE"
else
  PROJECT="construct-server"
  VERSIONS="$REPO_ROOT/versions.env"
  RENDER_SECRET="PROD_ENV_FILE"
fi

command -v signet >/dev/null 2>&1 || {
  err "ERROR: signet is not on PATH — this asks the host vault and cannot answer without it."
  err "It is a host-side check; there is nothing to run in a container or on a checkout."
  exit 2
}
[ -f "$VERSIONS" ] || { err "ERROR: no versions file at $VERSIONS"; exit 2; }

# One call, reused by both checks. A vault that will not answer is an error, not an
# all-clear — the whole point is that silence here used to read as "nothing wrong".
if ! status="$(signet status 2>&1)"; then
  err "ERROR: signet status failed — the vault could not be read:"
  printf '%s\n' "$status" | sed 's/^/  /' >&2
  exit 2
fi
if ! targets="$(signet target list --project "$PROJECT" 2>&1)"; then
  err "ERROR: signet target list failed for project $PROJECT:"
  printf '%s\n' "$targets" | sed 's/^/  /' >&2
  exit 2
fi

fail=0

# ---- 1. keys git owns, claimed by the vault ---------------------------------------
#
# Membership is read per secret rather than from the target's key count, because the
# count cannot say WHICH key is wrong, and naming it is the whole value of the report.
versioned_keys="$(grep -oE '^[A-Za-z_][A-Za-z0-9_]*' "$VERSIONS" || true)"
[ -n "$versioned_keys" ] || { err "ERROR: $VERSIONS defines no keys — refusing to report an all-clear"; exit 2; }

# One pass over the status table rather than a lookup per key. The earlier shape —
# `printf … | awk '… { print; exit }'` inside a loop — was a SIGPIPE race: awk left after
# the first match while printf still had tens of KB to write, and under `pipefail` the
# 141 that follows took `set -e` with it. The script then died mid-check with no output
# at all, which is the one failure this check must not have: it reads identically to
# never having run. A here-string is a temp file, so an early exit has nothing to signal
# — and doing the whole thing in one pass means there is no early exit to begin with.
#
# A key absent from the vault is the correct state and matches nothing. A key the vault
# HOLDS but delivers nowhere is dead weight rather than a hazard, and is reported with
# the other orphans below; what fails here is the vault DELIVERING it.
claimed="$(awk -v p="$PROJECT" -v dest="$RENDER_SECRET" -v keys="$versioned_keys" '
  BEGIN {
    n = split(keys, k, "\n")
    for (i = 1; i <= n; i++) if (k[i] != "") want[k[i]] = 1
  }
  $1 == p && ($2 in want) && index($0, "gh-render:") && index($0, dest) { print $2 }
' <<< "$status")"

if [ -n "$claimed" ]; then
  err "FAIL: the $PROJECT render of $RENDER_SECRET delivers keys that $(basename "$VERSIONS") owns:"
  printf '%s' "$claimed" | sed 's/^/  /' >&2
  err ""
  err "Those pins are tracked in git (SERV-96) so promote/rollback can commit them."
  err "A vault copy is a second source for a value the vault does not own, and it goes"
  err "stale silently: render-env.sh strips these before appending the tracked pins, so"
  err "nothing misbehaves until something removes that strip — and then prod rolls back"
  err "to whatever the vault last saw."
  err ""
  err "Signet's own drift report recommends the opposite ('import them into the vault')."
  err "That advice is right in general and wrong for every key the versions file defines."
  fail=1
fi

# ---- 2. files with a second writer -------------------------------------------------
#
# Scans for the KIND column rather than a fixed field index: a project-wide row reads
# `construct-server (89 keys)  file  /path`, a per-secret row `construct-server/NAME
# gh-actions  …`, so the path's position is not the same on every line.
file_targets="$(awk '{
  for (i = 1; i < NF; i++) if ($i == "file" && substr($(i+1), 1, 1) == "/") { print $(i+1); break }
}' <<< "$targets")"

# What is allowed is a SHAPE OF OWNERSHIP, not a path this script reconstructs. An
# earlier version derived the expected path from where the script was invoked, and that
# is wrong in a way worth recording: a Signet file target is registered once, at one
# absolute path on the host, while a checkout is one of several — this box has the
# canonical one, the runner's `_work` copy, and any number of worktrees. Deriving the
# allowlist from the caller's location made the answer depend on which of those you
# stood in, and the wrong answer was the dangerous direction: it called dev's one
# legitimate target a violation and told the reader to `signet target rm` it. Detaching
# that target is close to unrecoverable, because it is what `--seed-from` reads.
#
# So the rule is expressed as the property actually being asserted — no second writer:
#
#   * A path under either deploy root is refused outright. Those are the paths that
#     have another writer; deploy.yml and deploy-dev.yml rewrite `$root/.env` every run.
#   * Prod may have NO file target at all. Signet owns PROD_ENV_FILE and nothing else.
#   * Dev may have exactly one, and only a `creds/dev.env` — its readable credential
#     source. Which clone that lives in is not the question and cannot be, since any of
#     them may be the registered one; that no deploy writes it is the question.
unexpected=""
while IFS= read -r path; do
  [ -n "$path" ] || continue
  reason=""
  case "$path" in
    "$DEPLOY_ROOT"/*|"$DEV_ROOT"/*) reason="a deploy rewrites this path on every run" ;;
    */creds/dev.env) [ "$DEV" -eq 1 ] || reason="dev's credential source, on the prod project" ;;
    *) reason="not a credential source this project is allowed to write" ;;
  esac
  [ -z "$reason" ] || unexpected="$unexpected$path — $reason"$'\n'
done <<< "$file_targets"

if [ -n "$unexpected" ]; then
  err "FAIL: project $PROJECT has file target(s) with another writer, or no consumer:"
  printf '%s' "$unexpected" | sed 's/^/  /' >&2
  err ""
  if [ "$DEV" -eq 1 ]; then
    err "Dev's one allowed file target is a creds/dev.env — the credential source it was"
    err "seeded from, which deploy-dev.yml never writes. $DEV_ROOT/.env it does."
  else
    err "Prod has no allowed file target: Signet owns $RENDER_SECRET and nothing else"
    err "(SERV-94). $DEPLOY_ROOT/.env is written by deploy.yml on every deploy, and the"
    err "checkout copy at ~/construct-server/.env stopped driving anything when SERV-76"
    err "moved the deploy root."
  fi
  err ""
  err "Confirm with \`signet target list --project $PROJECT\` before detaching anything —"
  err "a rendered target seeded from a file target cannot be re-seeded once it is gone."
  err "Detach:  signet target rm --project $PROJECT --path <path>"
  fail=1
fi

# ---- reported, not failed: secrets reaching nothing ---------------------------------
#
# A secret with no target looks managed without being managed, which is the same class
# of problem as a target with no consumer. It is reported rather than failed because
# signet has no way to delete a secret today (SGNT-39) — so this cannot be driven to
# empty, and a check that can never pass is a check people learn to skip.
orphans="$(awk -v p="$PROJECT" '$1 == p && $NF == "-" { print $2 }' <<< "$status")"
if [ -n "$orphans" ]; then
  printf 'note: %d secret(s) in %s have no target and reach nothing:\n' \
    "$(printf '%s\n' "$orphans" | wc -l)" "$PROJECT"
  printf '%s\n' "$orphans" | sed 's/^/  /'
  printf 'They deliver nowhere, so nothing consumes a stale value. Removing them needs a\n'
  printf 'delete signet does not have yet (SGNT-39).\n\n'
fi

if [ "$fail" -eq 0 ]; then
  printf 'OK: project %s delivers %s and claims nothing %s or a deploy owns.\n' \
    "$PROJECT" "$RENDER_SECRET" "$(basename "$VERSIONS")"
fi
exit "$fail"
