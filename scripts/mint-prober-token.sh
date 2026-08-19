#!/usr/bin/env bash
#
# Mint the delivery prober's Switchyard token (SERV-111).
#
# The prober asserts what is ACTUALLY RUNNING in an environment Switchyard
# cannot reach. That claim has to be harder to produce than a claim about what
# *should* be running, or the matrix's `claimed_not_confirmed` state is
# unfalsifiable — a prober that could also report would be able to confirm its
# own claims. So the token carries `deployments:observe` and NOTHING else:
#
#   deployments:write    "I deployed X"        — a claim.  NOT granted here.
#   deployments:observe  "I saw X running"     — corroboration. This, only this.
#
# That split is why this is a script rather than a line in a README: the scope
# list is the security property, and a reviewable file holds it still. Minting
# by hand in the UI is how a token quietly acquires `admin` because that is the
# server-side default when scopes are omitted.
#
# Idempotent in the part that can be: the agent user is created only if absent.
# The TOKEN is not — every run mints a new one, because a token secret is
# returned exactly once and is unrecoverable afterwards. Re-run this only to
# rotate, and revoke the old one after.
#
#   ./scripts/mint-prober-token.sh
#
# Reads SWITCHYARD_BOOTSTRAP_TOKEN from the deployed .env, which is the admin
# token that can do `users:manage` (the MCP token deliberately cannot). Override
# the source with BOOTSTRAP_TOKEN=... for a non-standard host.

set -euo pipefail

DEPLOY_ROOT="${DEPLOY_ROOT:-/opt/construct-server}"
SWITCHYARD_URL="${SWITCHYARD_URL:-http://localhost:4002}"
PROBER_USER_NAME="${PROBER_USER_NAME:-delivery-prober}"
TOKEN_NAME="${TOKEN_NAME:-delivery-prober-host}"

# The one scope. Kept in a variable so the JSON below cannot drift from the
# comment above it.
SCOPES='["deployments:observe"]'

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

# Check it up front rather than letting the first real call fail.
#
# As of 2026-08-18 the SWITCHYARD_BOOTSTRAP_TOKEN in the deployed .env is
# REVOKED server-side (api_tokens.revoked_at is set on its row) while still
# sitting in the file looking usable. `seed()` registers that exact value as an
# admin token and returns early if a row with the same hash already exists — so
# re-running the seed does NOT un-revoke it, and nothing in a deploy ever will.
# Say that plainly here; the 401 alone reads as "wrong value" and sends you
# looking for a typo in a token that is character-for-character correct.
probe_status="$(curl -sS -m 15 -o /dev/null -w '%{http_code}' \
  "$SWITCHYARD_URL/v1/users?limit=1" -H "authorization: Bearer $bootstrap" || echo 000)"
case "$probe_status" in
  200) ;;
  401|403)
    die "the bootstrap token was rejected ($probe_status).
  It is present in $DEPLOY_ROOT/.env but revoked server-side, so it authenticates
  as nothing. Mint this token with a personal admin credential instead:
      BOOTSTRAP_TOKEN=sw_your_admin_token ./scripts/mint-prober-token.sh
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
# A dedicated identity rather than hanging the token off `claude` or an owner:
# the delivery ledger records who observed what, and "the host prober said so"
# is a materially different provenance from "an agent with admin said so".
echo "Looking for the '$PROBER_USER_NAME' user..."
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
" "$PROBER_USER_NAME")"

if [ -z "$user_id" ]; then
  echo "Not found — creating it."
  user_id="$(api POST /v1/users "{\"name\":\"$PROBER_USER_NAME\",\"type\":\"agent\"}" \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))")"
  [ -n "$user_id" ] || die "could not create the $PROBER_USER_NAME user"
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
# perfectly and grants everything — the failure would never surface at runtime.
granted="$(printf '%s' "$response" | python3 -c "
import json,sys
print(','.join(json.load(sys.stdin).get('scopes') or []))")"
if [ "$granted" != "deployments:observe" ]; then
  die "refusing to hand back a token with scopes [$granted] — expected exactly deployments:observe"
fi

echo
echo "Token minted, scopes verified: $granted"
echo "It is shown ONCE and cannot be retrieved again."
echo
echo "  $secret"
echo
echo "Next: put it in ansible/secrets.sops.yml as 'delivery_prober_token',"
echo "then apply the role:"
echo "  ansible-playbook ansible/site.yml --tags delivery_prober"
