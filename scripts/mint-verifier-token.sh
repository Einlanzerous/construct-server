#!/usr/bin/env bash
#
# Mint the post-deploy verifier's Switchyard token (SERV-80).
#
# The verifier RECORDS and does not gate. Two scopes, and the ones it is denied
# matter more than the ones it holds:
#
#   tickets:read      read a ticket and its acceptance criteria.  Granted.
#   comments:write    post one verdict comment.                   Granted.
#   tickets:write     transition or edit a ticket.            NOT granted.
#   admin             everything.                            NOT granted.
#
# Withholding `tickets:write` is what makes "it records, it does not gate" a
# property rather than an instruction: with it, a verifier could move a ticket to
# Closed on a verdict it got wrong, and the only thing standing in the way would
# be a sentence in a prompt. SERV-80 defers gating deliberately — a verifier that
# blocks before it has earned trust turns every false negative into a production
# incident — and a credential is how a deferral stays deferred.
#
# ── WHY THIS IS A SIBLING OF mint-prober-token.sh AND NOT A PARAMETER ───────
# The two scripts are largely the same mechanics with a different SCOPES line,
# and folding them into `mint-agent-token.sh <user> <name> <scopes>` is the
# obvious tidy. It is the wrong one: the prober script says its own reason —
# "the scope list is the security property, and a reviewable file holds it
# still" — and a parameterised minter moves that property to the caller, where
# it becomes an argument in a shell history instead of a line in a diff.
# PRINCIPLES.md §7a's rule of three also has not fired yet. A third consumer is
# when to revisit, and then the thing to share is the plumbing, never the scopes.
#
# Idempotent in the part that can be: the agent user is created only if absent.
# The TOKEN is not — a token secret is returned exactly once and is unrecoverable
# afterwards, so every run mints a new one. Re-run only to rotate, and revoke the
# old one after.
#
#   ./scripts/mint-verifier-token.sh
#
# Then add the printed value as the SWITCHYARD_VERIFIER_TOKEN repo secret; see
# docs/verifier.md. Reads SWITCHYARD_BOOTSTRAP_TOKEN from the deployed .env,
# which is the admin token that can do `users:manage`. Override the source with
# BOOTSTRAP_TOKEN=... for a non-standard host.

set -euo pipefail

DEPLOY_ROOT="${DEPLOY_ROOT:-/opt/construct-server}"
SWITCHYARD_URL="${SWITCHYARD_URL:-http://localhost:4002}"
VERIFIER_USER_NAME="${VERIFIER_USER_NAME:-post-deploy-verifier}"
TOKEN_NAME="${TOKEN_NAME:-post-deploy-verifier-ci}"

# The two scopes. Kept in variables so the JSON below and the assertion at the
# bottom cannot drift from the comment above them.
SCOPES='["tickets:read","comments:write"]'
EXPECT_SCOPES='tickets:read,comments:write'

die() { echo "Error: $*" >&2; exit 1; }

# ── the admin credential ────────────────────────────────────────────────────
bootstrap="${BOOTSTRAP_TOKEN:-}"
if [ -z "$bootstrap" ]; then
  env_file="$DEPLOY_ROOT/.env"
  [ -r "$env_file" ] || die "cannot read $env_file (and BOOTSTRAP_TOKEN is unset)"
  # Read without sourcing: the deployed .env holds ~99 variables including every
  # database password, and sourcing it here would export all of them into the
  # environment of everything below, curl included.
  bootstrap="$(sed -n 's/^SWITCHYARD_BOOTSTRAP_TOKEN=//p' "$env_file" | head -1)"
fi
# An empty token is not a token. Without this the curl below sends
# `Authorization: Bearer ` and fails as a 401, which reads as "the bootstrap
# token is wrong" rather than "it was never set".
[ -n "$bootstrap" ] || die "SWITCHYARD_BOOTSTRAP_TOKEN is empty or absent"

# The value shipped in the deployed .env has been REVOKED server-side since
# 2026-08-18 while still sitting in the file looking usable (SERV-113), and
# re-seeding does not un-revoke it. Say so plainly — a bare 401 sends you looking
# for a typo in a token that is character-for-character correct.
probe_status="$(curl -sS -m 15 -o /dev/null -w '%{http_code}' \
  "$SWITCHYARD_URL/v1/users?limit=1" -H "authorization: Bearer $bootstrap" || echo 000)"
case "$probe_status" in
  200) ;;
  401|403)
    die "the bootstrap token was rejected ($probe_status).
  It is present in $DEPLOY_ROOT/.env but revoked server-side, so it authenticates
  as nothing. Mint this token with a personal admin credential instead:
      BOOTSTRAP_TOKEN=sw_your_admin_token ./scripts/mint-verifier-token.sh
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
# A dedicated identity rather than the reviewer's or an owner's. A verdict
# carries provenance: "the post-deploy verifier observed this against dev" is a
# materially different claim from "the PR reviewer said so", and the two passes
# are only distinguishable on a ticket if their authors are.
echo "Looking for the '$VERIFIER_USER_NAME' user..."
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
" "$VERIFIER_USER_NAME")"

if [ -z "$user_id" ]; then
  echo "Not found — creating it."
  user_id="$(api POST /v1/users "{\"name\":\"$VERIFIER_USER_NAME\",\"type\":\"agent\"}" \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))")"
  [ -n "$user_id" ] || die "could not create the $VERIFIER_USER_NAME user"
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

# Assert rather than trust. `scopes` is omitted-defaults-to-ADMIN server-side, so
# a typo in the field NAME would silently mint an admin token that works
# perfectly and grants everything — a failure that never surfaces at runtime.
# Sorted before comparing so the server's ordering is not part of the contract.
granted="$(printf '%s' "$response" | python3 -c "
import json,sys
print(','.join(sorted(json.load(sys.stdin).get('scopes') or [])))")"
expected="$(printf '%s' "$EXPECT_SCOPES" | tr ',' '\n' | sort | paste -sd,)"
if [ "$granted" != "$expected" ]; then
  die "refusing to hand back a token with scopes [$granted] — expected exactly [$expected]"
fi

cat <<EOF

Minted. Scopes asserted: $granted

Add it as a repository secret, which is where verify.yml reads it:

    gh secret set SWITCHYARD_VERIFIER_TOKEN --repo Einlanzerous/construct-server --body '$secret'

Better, put it under Signet so rotation happens in the vault rather than per repo
(see CLAUDE.md > Conventions):

    signet set --project construct-server --name SWITCHYARD_VERIFIER_TOKEN
    signet target add --secret construct-server/SWITCHYARD_VERIFIER_TOKEN \\
      --gh-repo Einlanzerous/construct-server
    signet sync

This value is shown ONCE and cannot be retrieved again. If you lose it, re-run
this script and revoke the old token.
EOF
