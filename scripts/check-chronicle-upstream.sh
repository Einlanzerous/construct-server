#!/usr/bin/env bash
# check-chronicle-upstream.sh — can Chronicle actually reach Switchyard and
# Amber with the credentials it was handed? (SERV-185 / CHRN-97, SERV-227)
#
# Chronicle links to both and copies neither: a ticket reference and an archive
# citation resolve at render time into live cards. Without these four variables
# every card answers `unconfigured` — which is a TRUE answer CHRN-51 minted a
# state for, so nothing is broken and nothing is loud. That is exactly why this
# check exists: the failure mode of this credential is silence, not an error.
#
# ── WHY NOT JUST TRUST THE VAULT ────────────────────────────────────────────
#
# SGNT-29's lesson, the same one check-promote-dispatch.sh opens with: "Signet
# says in sync" answers a different question from "the token works". `signet
# render --check` compares key SETS, not values, so a vault seeded from a stale
# file renders the stale value and reports success — which is how a wrong
# credential once sat in DEV_ENV_FILE for two days (SERV-118).
#
# ── WHAT THIS DOES NOT CHECK, AND WHERE THAT IS CHECKED INSTEAD ─────────────
#
# It proves the Switchyard token is ACCEPTED and that its grant is CREATE-ONLY.
# It does not read the scope list, because nothing lets a token read its own.
#
# Until SERV-227 this said no safe probe for the grant existed, and that was
# true: Switchyard validates a request body BEFORE the handler's scope check, so
# a malformed create answers 400 whatever the scopes are, and a WELL-FORMED one
# would create a real ticket on success. A check that has to write to learn
# whether it can write is not a check.
#
# `tickets:create` (SWY-464) changed that by putting a refusal AHEAD of the
# write. A token admitted to POST /v1/tickets by that scope alone may not name
# `label_ids` (among others), and Switchyard refuses it before it looks anything
# up. So one well-formed create, naming `label_ids` and a project key that does
# not exist, tells the three cases apart and writes nothing in any of them:
#
#   403 create_only_field   read plus create-only          — the intended grant
#   404 project not found   tickets:write or admin         — WIDER than intended
#   403 (anything else)     no create scope at all         — triage cannot file
#
# The project key is the belt to that brace: even a token wide enough to get
# past the field check has no project to write into.
#
# The exact scope list is still asserted where it is minted:
# scripts/mint-chronicle-token.sh reads the granted scopes back out of the mint
# response and refuses to hand over a token that is not exactly `tickets:read`
# plus `tickets:create`. That is the same division mint-prober-token.sh uses and
# for the same reason — "the scope list is the security property, and a
# reviewable file holds it still."
#
# ── WHAT IT WILL NOT PRINT ──────────────────────────────────────────────────
#
# Nothing here echoes a credential. A failure reports the VARIABLE NAME and
# whether it was present, never a value — the rule assert-token-shapes.sh
# states at length, and the one this repo has had to learn twice.
#
# Usage:
#   ./scripts/check-chronicle-upstream.sh                # the deployed .env
#   ./scripts/check-chronicle-upstream.sh --from-vault   # before the first deploy
#
# `--from-vault` reads what Signet holds instead of the deployed file, and
# exists because of an ordering: `signet sync` writes the PROD_ENV_FILE
# environment secret, but only a deploy renders that into $DEPLOY_ROOT/.env — so
# between minting and deploying, the default form reports "not provisioned" for
# a credential that is provisioned correctly, and the only other way to test a
# new grant would be to ship it first.
#
# Environment:
#   DEPLOY_ROOT      where the rendered .env lives (default /opt/construct-server)
#   SWITCHYARD_URL   default http://localhost:4002
#   AMBER_URL        default http://localhost:4008

set -uo pipefail

DEPLOY_ROOT="${DEPLOY_ROOT:-/opt/construct-server}"
SWITCHYARD_URL="${SWITCHYARD_URL:-http://localhost:4002}"
AMBER_URL="${AMBER_URL:-http://localhost:4008}"
FROM_VAULT=0
# A well-formed project key that names nothing. The grant probe never reaches a
# project lookup with the intended token; this is for the token that is wider.
PROBE_PROJECT_KEY="${PROBE_PROJECT_KEY:-ZZNOPROJ}"

for arg in "$@"; do
  case "$arg" in
    --from-vault) FROM_VAULT=1 ;;
    *) echo "usage: check-chronicle-upstream.sh [--from-vault]" >&2; exit 2 ;;
  esac
done

fail=0
err() { echo "$*" >&2; }

bad() { err "  FAIL  $*"; fail=1; }
ok()  { echo "  ok    $*"; }

# One clean three-digit status, or 000 when nothing answered.
#
# NOT `curl ... || echo 000`: on a refused connection curl writes its own `000`
# through -w AND exits non-zero, so the fallback appends a second one and the
# result is `000000` — which matches no case below and falls through to the
# catch-all. On the Amber probe, whose catch-all is the SUCCESS branch, that
# turned "nothing answered" into "the credential is accepted". Found by running
# this script against a closed port, which is the only way it shows up.
http_code() {
  local out
  out="$(curl -sS -m 15 -o /dev/null -w '%{http_code}' "$1" -H "authorization: Bearer $2" 2>/dev/null)"
  case "$out" in
    [0-9][0-9][0-9]) printf '%s' "$out" ;;
    *) printf '000' ;;
  esac
}

# ── read the four values, without printing any of them ──────────────────────
# Reads one value. NEVER echoes it — only whether it was there.
#
# signet's STDERR IS REPORTED rather than discarded, which
# check-promote-dispatch.sh learned the hard way: "no such secret", a locked
# vault, a daemon that is not serving and an unsupported flag all collapse into
# one empty string, and the failure line below would then send someone off to
# mint a SECOND Switchyard token for a credential that already exists. That is
# not free here — the old token stays live until it is revoked.
read_value() {
  local name="$1" out errfile
  if [ "$FROM_VAULT" -eq 1 ]; then
    errfile="$(mktemp)"
    if ! out="$(signet reveal --project construct-server --name "$name" 2>"$errfile")"; then
      # The reason, not the value. signet reports failures on stderr and the
      # secret on stdout, so this cannot print one for the other.
      err "  note  signet could not reveal $name:"
      sed 's/^/        /' "$errfile" >&2
      out=""
    fi
    rm -f "$errfile"
    printf '%s' "$out"
  else
    sed -n "s/^${name}=//p" "$DEPLOY_ROOT/.env" 2>/dev/null | head -1
  fi
}

if [ "$FROM_VAULT" -eq 1 ]; then
  command -v signet >/dev/null || { err "ERROR: signet is not on PATH — --from-vault asks the host vault directly."; exit 1; }
  echo "Reading what the vault will deliver (not what the container holds)."
else
  [ -r "$DEPLOY_ROOT/.env" ] || {
    err "ERROR: cannot read $DEPLOY_ROOT/.env."
    err "To test a freshly minted credential before any deploy, use --from-vault."
    exit 1
  }
  echo "Reading the deployed environment at $DEPLOY_ROOT/.env."
fi
echo

# Only the two TOKENS come from the environment. The two URLs are literals or
# defaulted in docker-compose.yml, so an absent .env entry for them is correct
# and checking for one would report a healthy stack as broken.
SW_TOKEN="$(read_value CHRONICLE_SWITCHYARD_TOKEN)"
AM_TOKEN="$(read_value AMBER_API_TOKEN)"

echo "Credentials present?"
[ -n "$SW_TOKEN" ] && ok "CHRONICLE_SWITCHYARD_TOKEN is set" || bad "CHRONICLE_SWITCHYARD_TOKEN is empty or absent — mint it with scripts/mint-chronicle-token.sh"
[ -n "$AM_TOKEN" ] && ok "AMBER_API_TOKEN is set (Chronicle presents Amber's own; see SERV-185)" || bad "AMBER_API_TOKEN is empty or absent"
echo

# ── the reads Chronicle actually makes ──────────────────────────────────────
echo "Switchyard, as Chronicle asks it:"
if [ -n "$SW_TOKEN" ]; then
  # GET /v1/projects is the live project key set — what decides whether `SWY-389`
  # is recognised as a reference at all, and the one call the resolver makes on
  # a schedule rather than per render.
  code="$(http_code "$SWITCHYARD_URL/v1/projects" "$SW_TOKEN")"
  case "$code" in
    200) ok "GET /v1/projects -> 200 (the key set resolves)" ;;
    401|403) bad "GET /v1/projects -> $code. The token is present but not accepted: minted against
        another instance, revoked server-side, or carrying no tickets:read." ;;
    000) bad "could not reach $SWITCHYARD_URL — is the container up?" ;;
    *) bad "GET /v1/projects -> $code (unexpected)" ;;
  esac

  # The grant. See the header for why this create cannot write anything: the
  # field refusal comes before any lookup, and the project does not exist.
  probe_out="$(mktemp)"
  # The token goes to curl on stdin (`-K -`), not as an argument (SERV-215).
  code="$(printf 'header = "authorization: Bearer %s"\n' "$SW_TOKEN" \
    | curl -sS -m 15 -K - -o "$probe_out" -w '%{http_code}' -X POST "$SWITCHYARD_URL/v1/tickets" \
    -H 'content-type: application/json' \
    -d "{\"project_key\":\"$PROBE_PROJECT_KEY\",\"type\":\"task\",\"title\":\"chronicle-upstream-check probe\",\"label_ids\":[]}" \
    2>/dev/null)" || code=000
  case "$code" in [0-9][0-9][0-9]) ;; *) code=000 ;; esac
  # Only the error's `details.code`, never the body: a 201 body would be a ticket.
  detail="$(python3 -c "
import json,sys
try:
    print((json.load(open(sys.argv[1])).get('error') or {}).get('details', {}).get('code', ''))
except Exception:
    print('')
" "$probe_out" 2>/dev/null || true)"
  rm -f "$probe_out"
  case "$code:$detail" in
    403:create_only_field)
      ok "POST /v1/tickets -> 403 create_only_field (the grant is create-only; nothing was written)" ;;
    404:*)
      bad "POST /v1/tickets -> 404. The token got PAST the create-only field check, so it holds
        tickets:write or admin — wider than Chronicle is meant to have. Re-mint it with
        scripts/mint-chronicle-token.sh and revoke this one. Nothing was written." ;;
    403:*)
      bad "POST /v1/tickets -> 403 without create_only_field. The token cannot create a ticket
        at all (tickets:read only, or a Switchyard older than 4.43), so triage's TICKET
        route is refused. Re-mint it with scripts/mint-chronicle-token.sh (SERV-227)." ;;
    201:*)
      bad "POST /v1/tickets -> 201. A project keyed $PROBE_PROJECT_KEY exists and the token is
        wide enough to have filed a probe ticket into it. Delete that ticket, re-mint." ;;
    000:*) bad "could not reach $SWITCHYARD_URL — is the container up?" ;;
    *) bad "POST /v1/tickets -> $code (unexpected; treating the grant as not proven)" ;;
  esac
else
  bad "skipped: no token to present"
fi
echo

echo "Amber, as Chronicle asks it:"
if [ -n "$AM_TOKEN" ]; then
  # A well-formed citation that resolves to nothing. Amber answers a cite body
  # at several statuses and an {"error": ...} at 401 — so the question here is
  # only "was the credential accepted", which is exactly the distinction
  # CHRN-50's classifier draws between `broken` (the archive answered) and
  # `unreachable` (nobody could ask).
  zero="00000000-0000-0000-0000-000000000000"
  code="$(http_code "$AMBER_URL/v1/cite/amber1.$zero.$zero.0" "$AM_TOKEN")"
  # FAILS CLOSED. Amber answers a cite body at 200/404/409/410 and an error body
  # at 400/401/503, so "the credential was accepted" is a specific set and not
  # "anything that is not a 401" — an unreachable archive must not read as a
  # working credential, which is the direction this check is for.
  case "$code" in
    200|404|409|410) ok "GET /v1/cite/... -> $code (the archive answered; the credential is accepted)" ;;
    401|403) bad "GET /v1/cite/... -> $code. The token is present but not accepted." ;;
    000) bad "could not reach $AMBER_URL — is the container up?" ;;
    *) bad "GET /v1/cite/... -> $code (unexpected; treating as not proven)" ;;
  esac
else
  bad "skipped: no token to present"
fi
echo

if [ "$fail" -ne 0 ]; then
  err "chronicle-upstream: FAIL"
  err
  err "A credential that is absent or not accepted means every reference Chronicle"
  err "renders answers \`unconfigured\` — a true answer rather than an outage, which is"
  err "why nothing else reports it. A grant failure alone leaves references working"
  err "and triage's TICKET route refused (or, if the token is too wide, over-granted)."
  exit 1
fi

echo "chronicle-upstream: PASS"
echo
echo "Note: this proves the credentials are accepted and the Switchyard grant is"
echo "create-only. The exact scope list is asserted at mint time by"
echo "scripts/mint-chronicle-token.sh, which refuses to hand back a token whose"
echo "granted scopes are not exactly tickets:read plus tickets:create."
