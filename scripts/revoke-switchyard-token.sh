#!/usr/bin/env bash
#
# List and revoke a Switchyard user's API tokens (SERV-228).
#
# Every mint script here ends with "re-run only to rotate, and revoke the old
# one after", and until this file none of them could say how. The Switchyard UI
# revokes only the signed-in user's OWN tokens (Settings > API tokens), and an
# agent user never signs in — so a superseded agent token had no way out short
# of a hand-written curl (SWY-466 is the UI half). A rotation that cannot finish
# leaves the old credential live, which is the half of a rotation that matters.
#
#   ./scripts/revoke-switchyard-token.sh chronicle
#       List the user's tokens. Changes nothing.
#
#   ./scripts/revoke-switchyard-token.sh chronicle <token-id> [<token-id>...]
#       Revoke exactly those. Ids come from the listing.
#
#   ./scripts/revoke-switchyard-token.sh chronicle --superseded chronicle-resolver
#       The rotation case: revoke every LIVE token of that name except the
#       newest. Refuses when there is nothing older to revoke.
#
# Add --yes to skip the confirmation, and --dry-run to see what would go.
#
# ── THE ADMIN CREDENTIAL ────────────────────────────────────────────────────
#
# Needs `users:manage` on an instance admin, the same as minting. Taken from
# BOOTSTRAP_TOKEN, or prompted for (hidden) on a terminal. It is NOT read from
# the deployed .env: the bootstrap token there has been revoked server-side
# since 2026-08-16 (mint-prober-token.sh found it), so falling back to it would
# only turn "no credential" into a 401 that reads as a typo.
#
#   BOOTSTRAP_TOKEN=sw_your_admin_token ./scripts/revoke-switchyard-token.sh chronicle
#
# Nothing here echoes a credential. A token's SECRET is not retrievable from
# Switchyard at all; what is listed is metadata.
#
# ── IT WILL NOT CUT ITS OWN BRANCH, UNLESS TOLD TO ──────────────────────────
#
# Switchyard does not say which token a request was made with, so when the
# target user is the caller's own, the live token used most recently is taken
# to be the one this script is running as (it was used a moment ago, by the
# listing). Revoking that one needs --including-self, and it is revoked LAST —
# otherwise a cleanup of three tokens that starts with its own credential
# revokes one and 401s on the other two.
#
# Revocation is not reversible. A revoked token is re-minted, never restored.

set -euo pipefail

SWITCHYARD_URL="${SWITCHYARD_URL:-http://localhost:4002}"

die() { echo "Error: $*" >&2; exit 1; }
usage() {
  sed -n '3,25p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

user_name=""
superseded=""
assume_yes=0
dry_run=0
including_self=0
ids=()

while [ $# -gt 0 ]; do
  case "$1" in
    --superseded) [ $# -ge 2 ] || die "--superseded needs a token name"; superseded="$2"; shift 2 ;;
    --yes) assume_yes=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    --including-self) including_self=1; shift ;;
    -h|--help) usage ;;
    -*) die "unknown flag $1" ;;
    *) if [ -z "$user_name" ]; then user_name="$1"; else ids+=("$1"); fi; shift ;;
  esac
done
[ -n "$user_name" ] || usage
[ -z "$superseded" ] || [ "${#ids[@]}" -eq 0 ] || die "give token ids OR --superseded, not both"

# ── the admin credential ────────────────────────────────────────────────────
admin="${BOOTSTRAP_TOKEN:-}"
if [ -z "$admin" ]; then
  [ -t 0 ] || die "BOOTSTRAP_TOKEN is unset and there is no terminal to prompt on.
  BOOTSTRAP_TOKEN=sw_your_admin_token $0 $user_name"
  read -rsp "Switchyard admin token (users:manage), input hidden: " admin
  echo >&2
fi
# An empty token is not a token (the repo's blank-is-unset invariant).
[ -n "$admin" ] || die "no admin token given"

# One call. Prints the status on the LAST line and the body above it, so a
# caller can tell a refusal from a result without a second request.
api() {
  local method="$1" path="$2" out code
  out="$(mktemp)"
  code="$(curl -sS -m 15 -o "$out" -w '%{http_code}' -X "$method" "$SWITCHYARD_URL$path" \
    -H "authorization: Bearer $admin" || true)"
  cat "$out"; rm -f "$out"
  case "$code" in [0-9][0-9][0-9]) ;; *) code=000 ;; esac
  printf '\n%s\n' "$code"
}
status_of() { printf '%s' "$1" | tail -n 1; }
body_of() { printf '%s' "$1" | sed '$d'; }

explain() { # status, what was being done
  case "$1" in
    401) die "$2: 401. The admin token was not accepted — mistyped, revoked or expired." ;;
    403) die "$2: 403. The admin token lacks users:manage, or its user is not an instance admin.
  $(body_of "$3" | python3 -c "import json,sys
try: print(json.load(sys.stdin)['error']['message'])
except Exception: pass" 2>/dev/null || true)" ;;
    000) die "$2: could not reach $SWITCHYARD_URL" ;;
    *) die "$2: unexpected $1 from Switchyard" ;;
  esac
}

# ── who is asking, and who is being asked about ─────────────────────────────
me="$(api GET /v1/users/me)"
[ "$(status_of "$me")" = 200 ] || explain "$(status_of "$me")" "GET /v1/users/me" "$me"
me_id="$(body_of "$me" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))")"

users="$(api GET "/v1/users?limit=200")"
[ "$(status_of "$users")" = 200 ] || explain "$(status_of "$users")" "GET /v1/users" "$users"
user_id="$(body_of "$users" | python3 -c "
import json,sys
name = sys.argv[1]
d = json.load(sys.stdin)
items = d.get('items', d) if isinstance(d, dict) else d
for u in items or []:
    if (u.get('name') == name or u.get('id') == name) and not u.get('deleted_at'):
        print(u['id']); break
" "$user_name")"
[ -n "$user_id" ] || die "no live user named '$user_name'"

tokens="$(api GET "/v1/users/$user_id/tokens")"
[ "$(status_of "$tokens")" = 200 ] || explain "$(status_of "$tokens")" "listing $user_name's tokens" "$tokens"

# ── decide ──────────────────────────────────────────────────────────────────
# One python pass prints the table to stderr and the ids to revoke to stdout,
# in the order they should go: the caller's own credential last.
plan="$(body_of "$tokens" | python3 -c "
import json, sys
from datetime import datetime, timezone

user_name, is_self, superseded, including_self = sys.argv[1], sys.argv[2] == '1', sys.argv[3], sys.argv[4] == '1'
wanted = sys.argv[5:]
items = json.load(sys.stdin).get('items') or []

def ts(s):
    if not s: return None
    s = s.replace(' ', 'T')
    if s.endswith('+00'): s += ':00'
    if s.endswith('Z'): s = s[:-1] + '+00:00'
    try:
        d = datetime.fromisoformat(s)
    except ValueError:
        return None
    return d if d.tzinfo else d.replace(tzinfo=timezone.utc)

now = datetime.now(timezone.utc)
def live(t):
    exp = ts(t.get('expires_at'))
    return not t.get('revoked_at') and (exp is None or exp > now)

# The credential this script is running as, when it belongs to the target user:
# the live token used most recently. The listing itself just used it.
self_id = None
if is_self:
    used = [t for t in items if live(t) and ts(t.get('last_used_at'))]
    if used:
        self_id = max(used, key=lambda t: ts(t['last_used_at']))['id']

def err(*a): print(*a, file=sys.stderr)
def short(s): return (s or '-')[:16].replace('T', ' ')

err(f\"Tokens on '{user_name}' ({len(items)}), newest first:\")
err()
err(f\"  {'id':36}  {'state':8}  {'created':16}  {'last used':16}  name / scopes\")
for t in items:
    state = 'live' if live(t) else ('revoked' if t.get('revoked_at') else 'expired')
    mark = '  <- the credential this run is using' if t['id'] == self_id else ''
    err(f\"  {t['id']:36}  {state:8}  {short(t.get('created_at')):16}  {short(t.get('last_used_at')):16}  {t.get('name')}  [{', '.join(t.get('scopes') or [])}]{mark}\")
err()

by_id = {t['id']: t for t in items}
targets = []
if superseded:
    same = [t for t in items if t.get('name') == superseded and live(t)]
    if not same:
        err(f\"Error: no live token named '{superseded}' on '{user_name}'.\"); sys.exit(3)
    newest = max(same, key=lambda t: ts(t.get('created_at')) or now)
    targets = [t['id'] for t in same if t['id'] != newest['id']]
    if not targets:
        err(f\"Error: '{superseded}' has one live token and nothing older to revoke.\"); sys.exit(3)
    err(f\"Keeping the newest '{superseded}': {newest['id']} (created {short(newest.get('created_at'))}).\")
else:
    for i in wanted:
        if i not in by_id:
            err(f\"Error: {i} is not a token of '{user_name}'. Ids come from the listing above.\"); sys.exit(3)
        if not live(by_id[i]):
            err(f\"Error: {i} is already {'revoked' if by_id[i].get('revoked_at') else 'expired'}.\"); sys.exit(3)
        if i not in targets: targets.append(i)

if self_id in targets:
    if not including_self:
        err(f\"Error: {self_id} is the credential this run is using. Revoking it ends this\")
        err('  credential; pass --including-self if that is the point. It will go last.'); sys.exit(3)
    targets = [i for i in targets if i != self_id] + [self_id]

for i in targets:
    print(i + '\t' + (by_id[i].get('name') or ''))
" "$user_name" "$([ "$me_id" = "$user_id" ] && echo 1 || echo 0)" "$superseded" "$including_self" ${ids[@]+"${ids[@]}"})" || exit $?

[ -n "$plan" ] || { echo "Nothing asked for; that was the listing." >&2; exit 0; }

echo "To revoke on '$user_name':" >&2
printf '%s\n' "$plan" | sed 's/^/  /' >&2
echo >&2

if [ "$dry_run" -eq 1 ]; then
  echo "Dry run: nothing revoked." >&2
  exit 0
fi

if [ "$assume_yes" -ne 1 ]; then
  [ -t 0 ] || die "not a terminal, so nothing was confirmed. Re-run with --yes."
  read -rp "Revocation cannot be undone. Type 'revoke' to go ahead: " answer
  [ "$answer" = "revoke" ] || die "not confirmed; nothing revoked."
fi

# ── revoke ──────────────────────────────────────────────────────────────────
failed=0
while IFS=$'\t' read -r id name; do
  [ -n "$id" ] || continue
  res="$(api DELETE "/v1/users/$user_id/tokens/$id")"
  code="$(status_of "$res")"
  case "$code" in
    204|200) echo "  revoked  $id  $name" ;;
    *) echo "  FAILED   $id  $name  (HTTP $code)" >&2; failed=1 ;;
  esac
done <<EOF
$plan
EOF

[ "$failed" -eq 0 ] || die "some tokens were not revoked; re-run the listing to see which are still live."
echo "Done. A service still holding a revoked token now gets 401."
