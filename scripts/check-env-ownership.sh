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
# survivable — and it is also what kept it invisible for three months.
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
# Allowed file targets are an ALLOWLIST, not a pattern, for the same reason the edge
# exemptions are (SERV-106): a rule that admits a shape admits the next thing of that
# shape too. Prod's list is EMPTY — Signet owns PROD_ENV_FILE and nothing else, which
# is the design question SERV-94 settled. Dev keeps exactly one, `creds/dev.env`, which
# is the readable credential source and has no second writer.
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

# A Signet file target is registered at ONE absolute path on the host, so the allowlist
# has to name that path and not "wherever this script happens to live". Those differ:
# run from a git worktree or a second clone, a REPO_ROOT-relative allowlist rejects the
# real target and reports a violation that is not there. The main working tree is the
# first row of `git worktree list`, which is the same answer from every worktree of the
# same repo. Override for a checkout somewhere else entirely.
MAIN_WORKTREE="$(git -C "$REPO_ROOT" worktree list 2>/dev/null | awk 'NR == 1 { print $1 }')"
[ -n "$MAIN_WORKTREE" ] || MAIN_WORKTREE="$REPO_ROOT"
DEV_CREDS_FILE="${DEV_CREDS_FILE:-$MAIN_WORKTREE/creds/dev.env}"

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
  # The credential source dev is seeded from and reads back. deploy-dev.yml writes
  # /opt/construct-server-dev/.env, never this, so it has one writer.
  ALLOWED_FILE_TARGETS="$DEV_CREDS_FILE"
else
  PROJECT="construct-server"
  VERSIONS="$REPO_ROOT/versions.env"
  RENDER_SECRET="PROD_ENV_FILE"
  # Empty on purpose. Prod's credentials were imported once and the vault has been
  # the source ever since; there is no local file it should be writing. See SERV-94.
  ALLOWED_FILE_TARGETS=""
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

claimed=""
while IFS= read -r key; do
  [ -n "$key" ] || continue
  # The row for this project's secret, if the vault holds one at all. A key that is
  # absent from the vault is the correct state and produces no row.
  row="$(printf '%s\n' "$status" | awk -v p="$PROJECT" -v k="$key" '$1 == p && $2 == k { print; exit }')"
  [ -n "$row" ] || continue
  # Held but delivered nowhere is dead weight, not a hazard — it is reported with the
  # other orphans below. What fails the check is the vault DELIVERING it.
  case "$row" in
    *"gh-render:"*"$RENDER_SECRET"*) claimed="$claimed$key"$'\n' ;;
  esac
done <<< "$versioned_keys"

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
file_targets="$(printf '%s\n' "$targets" | awk '{
  for (i = 1; i < NF; i++) if ($i == "file" && substr($(i+1), 1, 1) == "/") { print $(i+1); break }
}')"

unexpected=""
while IFS= read -r path; do
  [ -n "$path" ] || continue
  allowed=0
  while IFS= read -r ok; do
    [ -n "$ok" ] || continue
    [ "$path" = "$ok" ] && allowed=1
  done <<< "$ALLOWED_FILE_TARGETS"
  [ "$allowed" -eq 1 ] || unexpected="$unexpected$path"$'\n'
done <<< "$file_targets"

if [ -n "$unexpected" ]; then
  err "FAIL: project $PROJECT renders to file targets that are not on its allowlist:"
  printf '%s' "$unexpected" | sed 's/^/  /' >&2
  err ""
  if [ "$DEV" -eq 1 ]; then
    err "Dev's one allowed file target is creds/dev.env, the credential source it was"
    err "seeded from. /opt/construct-server-dev/.env is written by deploy-dev.yml."
  else
    err "Prod has no allowed file target: Signet owns $RENDER_SECRET and nothing else"
    err "(SERV-94). /opt/construct-server/.env is written by deploy.yml on every deploy,"
    err "and the checkout copy at ~/construct-server/.env stopped driving anything when"
    err "SERV-76 moved the deploy root."
  fi
  err ""
  err "Detach it:  signet target rm --project $PROJECT --path <path>"
  fail=1
fi

# ---- reported, not failed: secrets reaching nothing ---------------------------------
#
# A secret with no target looks managed without being managed, which is the same class
# of problem as a target with no consumer. It is reported rather than failed because
# signet has no way to delete a secret today (SGNT-39) — so this cannot be driven to
# empty, and a check that can never pass is a check people learn to skip.
orphans="$(printf '%s\n' "$status" | awk -v p="$PROJECT" '$1 == p && $NF == "-" { print $2 }')"
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
