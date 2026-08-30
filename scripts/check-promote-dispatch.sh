#!/usr/bin/env bash
# check-promote-dispatch.sh — Prove PROMOTE_DISPATCH_TOKEN can actually dispatch
# promote.yml (SERV-104, SERV-78 piece 3).
#
# The credential this checks is what lets Switchyard's promote gate (SWY-188) ask for a
# promote instead of linking a human out to the Actions tab. It is a fine-grained PAT
# scoped to `Actions: Read and write` on this repo and nothing else, held by the
# switchyard container through PROD_ENV_FILE.
#
# WHY THIS EXISTS AT ALL, rather than trusting the vault. SGNT-29 is the bug where a
# fine-grained PAT grant 403'd in use while `signet sync --check` reported it healthy —
# so "Signet says in sync" answers a different question than "the token works". SERV-104
# names that ticket in as many words. There is a second trap stacked on it: a
# fine-grained PAT with no grant on a private repo answers **404, not 403**, because
# GitHub will not confirm the repo exists to a token that cannot see it. That is the
# same shape that hid EXTERNAL_REF_POLLER's missing scope for weeks (see its comment in
# docker-compose.yml), and it is why the read check below reports the two codes
# differently instead of collapsing them into "failed".
#
# TWO CHECKS, AND ONLY THE SECOND ONE IS CONCLUSIVE.
#
#   default    read-only. Confirms the token exists, is non-empty, and can SEE
#              promote.yml. That rules out the common failures — unset, not synced,
#              repo grant never applied — but a read grant and a write grant are
#              separate boxes on the PAT form, so a token that passes this can still
#              be refused at the dispatch.
#   --dispatch conclusive. Actually POSTs the dispatch. GitHub evaluates `actions:
#              write` before it evaluates anything else, so a 204 IS the write grant.
#
# WHAT --dispatch COSTS, stated plainly because it is not nothing. It creates a real
# promote.yml run. The run is a deliberate NO-OP: the version dispatched is read out of
# versions.env, so it is the pin that is already there, `set-version.sh` reports
# "already", and the workflow skips its commit step — nothing is written to `main` and
# nothing deploys. But the run still enters the `version-change` concurrency group with
# `cancel-in-progress: false`, and it sits at `waiting` until the production-promote
# reviewer approves or rejects it. **A verification run left pending queues the next
# real promote behind it**, which is a bad thing to discover during a rollback. So this
# prints the run URL and says to resolve it; do not walk away from a pending run.
#
# It reads the deployed .env rather than taking a token on the command line, for the
# same reason `make probe-delivery` does: the credential worth testing is the one the
# container was actually handed, not one exported into a shell by the person testing.
#
# Usage:
#   ./scripts/check-promote-dispatch.sh                # read-only: is the grant there?
#   ./scripts/check-promote-dispatch.sh --dispatch     # conclusive: no-op promote run
#   ./scripts/check-promote-dispatch.sh --from-vault   # before the first deploy
#
# The flags compose: --from-vault --dispatch is the right pair immediately after minting
# a PAT, since it settles the write grant without waiting on a deploy to carry the value.
#
# Environment:
#   DEPLOY_ROOT   where the rendered .env lives (default /opt/construct-server)
#   PROMOTE_REPO  owner/name the token is scoped to (default Einlanzerous/construct-server)
#   NOOP_SERVICE  which pin the --dispatch no-op names (default cook_book)
#
# Exit codes:
#   0  the token is present and the grant works
#   1  the grant is missing, wrong, or the token is absent
#   2  usage error, or this host cannot answer (no .env, no curl, no versions.env)

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd)"

DEPLOY_ROOT="${DEPLOY_ROOT:-/opt/construct-server}"
PROMOTE_REPO="${PROMOTE_REPO:-Einlanzerous/construct-server}"
NOOP_SERVICE="${NOOP_SERVICE:-cook_book}"
WORKFLOW="promote.yml"

err() { printf '%s\n' "$*" >&2; }

DISPATCH=0
FROM_VAULT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dispatch)   DISPATCH=1 ;;
    --from-vault) FROM_VAULT=1 ;;
    *) err "usage: check-promote-dispatch.sh [--from-vault] [--dispatch]"; exit 2 ;;
  esac
  shift
done

command -v curl >/dev/null 2>&1 || {
  err "ERROR: curl is not on PATH — this asks GitHub and cannot answer without it."
  exit 2
}

# ---- the credential ------------------------------------------------------------------
#
# TWO SOURCES, AND THEY ANSWER DIFFERENT QUESTIONS. Default is the deployed .env — the
# value the switchyard container was actually handed, which is the one worth testing in
# steady state, and the same reasoning as `make probe-delivery` reading the unit's own
# EnvironmentFile rather than a shell export.
#
# `--from-vault` reads what Signet holds instead, and exists because of an ordering that
# bites exactly once per credential and always at the worst time. `signet sync` writes
# the PROD_ENV_FILE environment secret; only a deploy turns that into $DEPLOY_ROOT/.env,
# via render-env.sh. So between minting a PAT and deploying, the vault has the value and
# the deployed file does not — and the default check reports "not provisioned" for a
# token that is provisioned correctly. Without this flag the only way to test a new grant
# is to ship it first, which is backwards: a bad grant should be found before the merge,
# not after.
#
# It reads the value into a variable and never prints it — the same discipline
# check-env-ownership.sh keeps by never calling reveal at all. What it proves is narrower
# than the default and the report says so: that the value the vault WILL deliver carries
# a working grant, not that the running container holds it.
if [ "$FROM_VAULT" -eq 1 ]; then
  command -v signet >/dev/null 2>&1 || {
    err "ERROR: signet is not on PATH — --from-vault asks the host vault directly."
    exit 2
  }
  source_desc="the vault (construct-server/PROMOTE_DISPATCH_TOKEN)"
  if ! TOKEN="$(signet reveal --project construct-server --name PROMOTE_DISPATCH_TOKEN 2>/dev/null)"; then
    err "FAIL: the vault holds no construct-server/PROMOTE_DISPATCH_TOKEN."
    err ""
    err "Mint it first — see the provisioning steps below."
    TOKEN=""
  fi
  TOKEN="$(printf '%s' "$TOKEN" | tr -d '\r\n')"
else
  # Same read as promote.yml's GHCR login step: grep the rendered file rather than
  # sourcing it, because that file is the whole stack environment and sourcing it would
  # drag ~90 unrelated variables into this shell.
  env_file="$DEPLOY_ROOT/.env"
  if [ ! -f "$env_file" ]; then
    err "ERROR: no deployed .env at $env_file — this host is not bootstrapped (SERV-76)."
    err "This is a host-side check; there is nothing to interrogate from a bare checkout."
    err "To test a freshly minted PAT before any deploy, use --from-vault."
    exit 2
  fi
  source_desc="$env_file"
  TOKEN="$(grep -m1 '^PROMOTE_DISPATCH_TOKEN=' "$env_file" | cut -d'=' -f2- || true)"
fi

if [ -z "$TOKEN" ]; then
  err "FAIL: PROMOTE_DISPATCH_TOKEN is unset or empty in $source_desc."
  err ""
  if [ "$FROM_VAULT" -eq 0 ]; then
    err "If you have just run \`signet sync\`, this is the EXPECTED state and not a"
    err "failure of the sync: sync writes the PROD_ENV_FILE environment secret, and only"
    err "a deploy renders that into $env_file. Check the grant now with:"
    err "    make promote-dispatch-check vault=1"
    err "and re-run this form after the next deploy."
    err ""
  fi
  err "An empty credential is not a credential (the CLAUDE.md invariant), and"
  err "docker-compose.yml passes this key through BARE — so in this state switchyard"
  err "does not see the variable at all and the promote gate stays the link-out to the"
  err "Actions tab that it is today. Nothing is broken; it is simply not provisioned."
  err ""
  err "To provision it (docs/delivery-pipeline.md has the full runbook):"
  err "  1. Mint a fine-grained PAT on github.com — Actions: Read and write,"
  err "     repository Einlanzerous/construct-server ONLY. No other permission."
  err "  2. signet set --project construct-server --name PROMOTE_DISPATCH_TOKEN"
  err "  3. signet target add-key --project construct-server \\"
  err "         --gh-secret PROD_ENV_FILE --name PROMOTE_DISPATCH_TOKEN"
  err "  4. signet sync"
  err "  5. check the grant NOW, before deploying:  --from-vault"
  err "  6. deploy, so render-env.sh writes it into $DEPLOY_ROOT/.env, then re-run"
  err "     this form to confirm the container holds what the vault delivered"
  exit 1
fi

api() {
  # --write-out puts the status on its own last line, so a body containing digits
  # cannot be mistaken for one. -s so a failure does not print a progress meter into
  # the middle of the report.
  curl -sS -o /dev/null -w '%{http_code}' \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $TOKEN" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$@"
}

# ---- check 1: can the token see the workflow? ---------------------------------------
printf 'Token source: %s\n' "$source_desc"
printf 'Checking read access to %s in %s…\n' "$WORKFLOW" "$PROMOTE_REPO"
code="$(api "https://api.github.com/repos/$PROMOTE_REPO/actions/workflows/$WORKFLOW")" || {
  err "ERROR: the request to api.github.com failed outright — no answer, not a refusal."
  err "That is a network or DNS problem on this host, not a grant problem."
  exit 2
}

case "$code" in
  200)
    printf 'OK: the token can read %s.\n' "$WORKFLOW"
    ;;
  404)
    err "FAIL: 404 on $WORKFLOW — and 404 is the ANSWER, not a missing file."
    err ""
    err "A fine-grained PAT with no grant on a private repo gets 404 rather than 403:"
    err "GitHub will not confirm the repo exists to a token that cannot see it. So this"
    err "almost always means the PAT's Repository access does not include"
    err "$PROMOTE_REPO — not that promote.yml is missing."
    err ""
    err "Two other things produce it, worth ruling out in this order:"
    err "  * the PAT was minted against the wrong account or a fork"
    err "  * the PAT expired — an expired fine-grained PAT reads as no access"
    err ""
    err "This is the SGNT-29 shape. Check the grant on github.com under Settings >"
    err "Developer settings > Personal access tokens > Fine-grained tokens; \`signet"
    err "sync\` reporting in-sync says the value was DELIVERED, not that it works."
    exit 1
    ;;
  403)
    err "FAIL: 403 on $WORKFLOW — the repo is visible but Actions is not."
    err ""
    err "The token reaches $PROMOTE_REPO, so the repository grant took. What is missing"
    err "is the permission: this needs 'Actions: Read and write'. A PAT with only"
    err "'Metadata: Read' — the mandatory one every fine-grained PAT carries — lands"
    err "exactly here."
    exit 1
    ;;
  401)
    err "FAIL: 401 — the token was rejected outright."
    err ""
    err "The value in $source_desc is not a valid credential. Either it is a stale copy"
    err "from before a rotation, or the vault holds something that is not a PAT."
    err "Rotate in the vault and \`signet sync\`, then redeploy so render-env.sh rewrites"
    err "the deployed file — editing it on the host is lost on the next deploy."
    exit 1
    ;;
  *)
    err "FAIL: unexpected HTTP $code from the workflows API."
    err "Not a grant answer this script recognises — check api.github.com's status"
    err "before assuming the token is at fault."
    exit 1
    ;;
esac

if [ "$DISPATCH" -eq 0 ]; then
  cat <<EOF

Read access confirmed — but that is NOT the write grant.

'Actions: Read' and 'Actions: Read and write' are different settings on the PAT form,
and only the second one can dispatch. A token that passes the check above can still be
refused at the POST. To settle it, run:

  ./scripts/check-promote-dispatch.sh --dispatch

which fires a real but deliberately no-op promote (the version it names is read out of
versions.env, so the pin does not move and nothing is committed). Read the header of
this script first: the run enters the version-change concurrency group and waits for a
production-promote reviewer, so it must be approved or cancelled rather than left.
EOF
  exit 0
fi

# ---- check 2: the conclusive one ----------------------------------------------------
#
# The no-op version comes out of versions.env rather than being passed in, and that is
# load-bearing: a version this script INVENTED could be a real promote by accident. The
# pin that is already there cannot be.
versions="$REPO_ROOT/versions.env"
[ -f "$versions" ] || { err "ERROR: no versions.env at $versions"; exit 2; }

pin_key="$(printf '%s' "$NOOP_SERVICE" | tr '[:lower:]' '[:upper:]')_TAG"
pin_value="$(grep -m1 "^${pin_key}=" "$versions" | cut -d'=' -f2- || true)"

if [ -z "$pin_value" ]; then
  err "ERROR: $pin_key is not set in $versions, so there is no current pin to re-pin."
  err "Pick a service that is pinned there:  NOOP_SERVICE=<name> $0 --dispatch"
  exit 2
fi

printf '\nDispatching a no-op promote: %s -> %s (its current pin).\n' "$NOOP_SERVICE" "$pin_value"

payload="$(printf '{"ref":"main","inputs":{"service":"%s","version":"%s","kind":"promote","reason":"%s"}}' \
  "$NOOP_SERVICE" "$pin_value" \
  "SERV-104 dispatch grant verification — re-pins the current version, commits nothing")"

code="$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer $TOKEN" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  -d "$payload" \
  "https://api.github.com/repos/$PROMOTE_REPO/actions/workflows/$WORKFLOW/dispatches")" || {
  err "ERROR: the dispatch request failed outright — no answer, not a refusal."
  exit 2
}

case "$code" in
  204)
    cat <<EOF
OK: dispatch accepted (204). The write grant works — this is the conclusive result.

A run has been created and is WAITING on the production-promote reviewer. It is a
no-op: $pin_key is already $pin_value, so set-version.sh reports "already", the
commit step is skipped, and nothing deploys either way.

Resolve it now rather than later. It holds the version-change concurrency group, and
\`cancel-in-progress: false\` means the next real promote queues behind it — which is
the worst possible time to find a stale verification run, since a rollback runs when
prod is already broken.

  https://github.com/$PROMOTE_REPO/actions/workflows/$WORKFLOW

Approving it is fine and changes nothing; cancelling it is equally fine and faster.
EOF
    exit 0
    ;;
  403)
    err "FAIL: 403 on the dispatch — read works, write does not."
    err ""
    err "This is exactly the case the read-only check cannot see, and why --dispatch"
    err "exists. The PAT has 'Actions: Read' where it needs 'Actions: Read and write'."
    err "Change it on github.com; the value does not need reissuing, so no signet"
    err "rotation is involved — the permission is edited on the existing token."
    exit 1
    ;;
  404)
    err "FAIL: 404 on the dispatch, after a 200 on the read."
    err ""
    err "The workflow is readable but not dispatchable at ref 'main'. A workflow_dispatch"
    err "trigger is resolved from the DEFAULT BRANCH's copy of the file, so this means"
    err "the promote.yml on main does not declare workflow_dispatch — check what is"
    err "merged, not what is in this checkout."
    exit 1
    ;;
  422)
    err "FAIL: 422 — the inputs were rejected."
    err ""
    err "The grant is fine (GitHub checks permission before inputs), so this is a"
    err "mismatch between this script and promote.yml's input list: '$NOOP_SERVICE' is"
    err "most likely missing from the \`service\` choice options. Add it there, or point"
    err "this at a service that is listed:  NOOP_SERVICE=<name> $0 --dispatch"
    exit 1
    ;;
  *)
    err "FAIL: unexpected HTTP $code from the dispatch API."
    exit 1
    ;;
esac
