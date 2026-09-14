#!/usr/bin/env bash
#
# Mint Chronicle's Switchyard token (SERV-185 / CHRN-97).
#
# Chronicle LINKS to Switchyard and never copies it: a ticket reference resolves
# at render time into a live card and is never written into a Chronicle table.
# Everything that needs is READ:
#
#   GET /v1/projects        the live project key set, so `SWY-389` is recognised
#                           as a reference and `UTF-8` is left as prose
#   GET /v1/tickets/{key}   the card itself — title, status, project
#   GET /v1/tickets?...     the triage sweep's lookups by memo
#
# So the token carries `tickets:read` and NOTHING else:
#
#   tickets:read     "what does Switchyard say about this key"   — this, only this.
#   tickets:write    create, edit AND DELETE, instance-wide      — NOT granted here.
#
# ── WHY THERE IS NO NARROW WRITE GRANT, WHICH IS THE PART WORTH READING ──────
#
# It would be reasonable to assume `tickets:write` means "can file a ticket".
# For an AGENT identity against Switchyard it does not, and the difference is
# two facts in server/src/lib/authz.ts:
#
#   1. `hasInstanceWideAccess` is true for `user.type === "agent"`, so an
#      agent's effectivePermissions are its TOKEN SCOPES ALONE — no project
#      role is intersected in, and no project membership is consulted.
#   2. `scopeCapabilities` emits `write` and `delete` TOGETHER for any write
#      scope (SWY-163 decision 3: "a write-capable token is delete-capable at
#      the SCOPE layer"). What withholds deletion from a `user` is the ROLE
#      layer — the layer (1) says agents bypass.
#
# So `tickets:write` on a service agent is instance-wide create, edit and delete
# on every ticket in every project. That is a materially different thing to hand
# a service than "Chronicle can file a ticket from triage", and if triage's
# ticket creation is ever enabled in production it wants its own decision rather
# than a wider scope list here. Chronicle's Scribe is not configured in
# production today, so nothing needs it (cmd/chronicle/main.go gates the whole
# triage construction on ScribeEnabled() && SwitchyardConfigured()).
#
# ── WHY THIS IS A SCRIPT AND NOT A README LINE ───────────────────────────────
#
# mint-prober-token.sh's reason, verbatim, because it is the same reason: "the
# scope list is the security property, and a reviewable file holds it still.
# Minting by hand in the UI is how a token quietly acquires `admin` because that
# is the server-side default when scopes are omitted."
#
# Idempotent in the part that can be: the agent user is created only if absent.
# The TOKEN is not — every run mints a new one, because a token secret is
# returned exactly once and is unrecoverable afterwards. Re-run this only to
# rotate, and revoke the old one after.
#
#   ./scripts/mint-chronicle-token.sh
#
# Reads SWITCHYARD_BOOTSTRAP_TOKEN from the deployed .env, which is the admin
# token that can do `users:manage` (the MCP token deliberately cannot). Override
# the source with BOOTSTRAP_TOKEN=... for a non-standard host.

set -euo pipefail

DEPLOY_ROOT="${DEPLOY_ROOT:-/opt/construct-server}"
SWITCHYARD_URL="${SWITCHYARD_URL:-http://localhost:4002}"
CHRONICLE_USER_NAME="${CHRONICLE_USER_NAME:-chronicle}"
TOKEN_NAME="${TOKEN_NAME:-chronicle-resolver}"

# The one scope. Kept in a variable so the JSON below cannot drift from the
# comment above it.
SCOPES='["tickets:read"]'
EXPECT_SCOPES='tickets:read'

die() { echo "Error: $*" >&2; exit 1; }

# ── the admin credential ────────────────────────────────────────────────────
bootstrap="${BOOTSTRAP_TOKEN:-}"
if [ -z "$bootstrap" ]; then
  env_file="$DEPLOY_ROOT/.env"
  [ -r "$env_file" ] || die "cannot read $env_file (and BOOTSTRAP_TOKEN is unset)"
  # Read without sourcing: the deployed .env holds ~99 variables including every
  # database password, and sourcing it into this shell would export all of them
  # into the environment of everything below, including curl.
  bootstrap="$(sed -n 's/^SWITCHYARD_BOOTSTRAP_TOKEN=//p' "$env_file" | head -1)"
fi
# An empty token is not a token (the repo's blank-is-unset invariant). Without
# this the curl below sends `Authorization: Bearer ` and fails as a 401, which
# reads as "the bootstrap token is wrong" rather than "it was never set".
[ -n "$bootstrap" ] || die "SWITCHYARD_BOOTSTRAP_TOKEN is empty or absent"

# Check it up front rather than letting the first real call fail. The bootstrap
# token in the deployed .env has been REVOKED server-side before while still
# sitting in the file looking usable (see mint-prober-token.sh, which found it):
# the 401 alone reads as "wrong value" and sends you looking for a typo in a
# token that is character-for-character correct.
probe_status="$(curl -sS -m 15 -o /dev/null -w '%{http_code}' \
  "$SWITCHYARD_URL/v1/users?limit=1" -H "authorization: Bearer $bootstrap" || echo 000)"
case "$probe_status" in
  200) ;;
  401|403)
    die "the bootstrap token was rejected ($probe_status).
  It may be present in $DEPLOY_ROOT/.env but revoked server-side, in which case
  it authenticates as nothing. Mint this token with a personal admin credential
  instead:
      BOOTSTRAP_TOKEN=sw_your_admin_token ./scripts/mint-chronicle-token.sh
  A Switchyard owner can create one under Settings > API tokens." ;;
  000) die "could not reach $SWITCHYARD_URL" ;;
  *)   die "unexpected $probe_status from $SWITCHYARD_URL/v1/users" ;;
esac

api() {
  local method="$1" path="$2" body="${3:-}"
  if [ -n "$body" ]; then
    curl -sS -m 15 -X "$method" "$SWITCHYARD_URL$path" \
      -H "authorization: Bearer $bootstrap" \
      -H "content-type: application/json" \
      -d "$body"
  else
    curl -sS -m 15 -X "$method" "$SWITCHYARD_URL$path" \
      -H "authorization: Bearer $bootstrap"
  fi
}

# ── the agent user ──────────────────────────────────────────────────────────
# A dedicated identity rather than hanging the token off `claude` or an owner.
# Chronicle's reads are a service's, and `claude` is an agent a person drives —
# sharing one identity would make the audit trail unable to tell "a render
# resolved a card" from "an agent looked a ticket up", and would mean revoking
# one revokes the other.
echo "Looking for the '$CHRONICLE_USER_NAME' user..."
user_id="$(api GET "/v1/users?limit=200" | python3 -c "
import json,sys
name = sys.argv[1]
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
items = d.get('items', d) if isinstance(d, dict) else d
for u in items or []:
    if u.get('name') == name and not u.get('deleted_at'):
        print(u['id']); break
" "$CHRONICLE_USER_NAME")"

if [ -z "$user_id" ]; then
  echo "Not found — creating it."
  user_id="$(api POST /v1/users "{\"name\":\"$CHRONICLE_USER_NAME\",\"type\":\"agent\"}" \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))")"
  [ -n "$user_id" ] || die "could not create the $CHRONICLE_USER_NAME user"
  echo "Created user $user_id"
else
  echo "Found existing user $user_id"
fi

# ── the token ───────────────────────────────────────────────────────────────
echo "Minting a token scoped to $SCOPES ..."
response="$(api POST "/v1/users/$user_id/tokens" \
  "{\"name\":\"$TOKEN_NAME\",\"kind\":\"agent\",\"scopes\":$SCOPES}")"

secret="$(printf '%s' "$response" | python3 -c "import json,sys; print(json.load(sys.stdin).get('token',''))" 2>/dev/null || true)"
if [ -z "$secret" ]; then
  die "token mint failed: $response"
fi

# Assert rather than trust. `scopes` is omitted-defaults-to-admin server-side,
# so a typo in the field NAME would silently mint an admin token that works
# perfectly and grants everything — the failure would never surface at runtime,
# because a token with too much access does everything a correct one does.
granted="$(printf '%s' "$response" | python3 -c "
import json,sys
print(','.join(sorted(json.load(sys.stdin).get('scopes') or [])))")"
if [ "$granted" != "$EXPECT_SCOPES" ]; then
  die "refusing to hand back a token with scopes [$granted] — expected exactly $EXPECT_SCOPES.
  Revoke it: Switchyard > Settings > API tokens, or
  POST /v1/users/$user_id/tokens/<id>/revoke with the bootstrap credential."
fi

echo
echo "Token minted, scopes verified: $granted"
echo "It is shown ONCE and cannot be retrieved again."
echo
echo "  $secret"
echo
echo "Next, per docs/delivery-pipeline.md's SERV-94 runbook — this project has no"
echo "host file target, so a new key is 'set' plus 'target add-key', never 'import',"
echo "and 'signet set' alone mints a value that reaches nothing:"
echo
echo "  signet set --project construct-server --name CHRONICLE_SWITCHYARD_TOKEN"
echo "  signet target add-key --project construct-server \\"
echo "      --gh-secret PROD_ENV_FILE --name CHRONICLE_SWITCHYARD_TOKEN"
echo "  signet sync"
echo "  make chronicle-upstream-check vault=1     # prove the grant BEFORE shipping it"
echo
echo "Then deploy, and re-run 'make chronicle-upstream-check' against the container."
