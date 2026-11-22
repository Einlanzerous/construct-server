#!/usr/bin/env bash
# satlink-tokens.sh — mint, store, rotate and rehearse Satlink's Argosy and Lyceum
# service tokens (SATL-31 rev 2 rollout, SERV-347).
#
#   satlink-tokens.sh list     [argosy|lyceum|both]   live tokens per service (no hashes, no values)
#   satlink-tokens.sh mint     [argosy|lyceum|both]   first token: mint, probe 200, store in Signet
#   satlink-tokens.sh deliver                         add-key to PROD_ENV_FILE, sync, assert --vault
#   satlink-tokens.sh rotate   [argosy|lyceum|both]   mint new, store, sync, pause for a deploy.yml
#                                                     run, revoke old ids once Satlink switched
#   satlink-tokens.sh rehearse [argosy|lyceum|both]   scratch token: 200, revoke, 401, no restart
#
#   --dev   use argosy-dev / lyceum-dev (127.0.0.1:18096 / :14005). Only `list` and
#           `rehearse` accept it: dev tokens never go into the construct-server vault.
#
# Why it is shaped like this:
# - A token goes from the mint's stdout into a shell variable and from there into
#   `signet set` on stdin. It is never in argv (printf is a builtin), never printed and
#   never written to a file. curl reads the header from a process substitution, not -H.
# - `argosy <unknown subcommand>` falls through to SERVING (cmd/argosy/main.go), so a
#   `docker exec` against a pre-0.39.0 image would start a second server inside the prod
#   container. Every action checks /healthz's version first and refuses below the floor.
# - Revocation is always by id. Revoking by label would also kill the token just minted.
set -euo pipefail
[[ $- == *x* ]] && { echo "refusing to run under xtrace: it would print the token" >&2; exit 2; }
ulimit -c 0

PROJECT=construct-server
LABEL=satlink
REHEARSAL_LABEL=satlink-rehearsal
CS_CHECKOUT=${CS_CHECKOUT:-$(cd "$(dirname "$0")/.." && pwd)}
DEV=0

die() { echo "error: $*" >&2; exit 1; }
say() { echo "==> $*" >&2; }

# Per-service config. svc_* functions read $SVC.
svc_set() {
  SVC=$1
  case "$SVC" in
    argosy)
      CONTAINER=argosy; URL=http://127.0.0.1:8096; MIN=0.39.0
      PATH_=/api/v1/sessions/summary; SCOPE=sessions:summary; PREFIX=ags_
      SECRET=SATLINK_ARGOSY_TOKEN
      if ((DEV)); then CONTAINER=argosy-dev; URL=http://127.0.0.1:18096; fi
      ;;
    lyceum)
      CONTAINER=lyceum; URL=http://127.0.0.1:4005; MIN=1.14.0
      PATH_=/admin/users/active; SCOPE=admin:read; PREFIX=lys_
      SECRET=SATLINK_LYCEUM_TOKEN
      if ((DEV)); then CONTAINER=lyceum-dev; URL=http://127.0.0.1:14005; fi
      ;;
    *) die "unknown service: $SVC" ;;
  esac
}

cli() { docker exec "$CONTAINER" "$SVC" service-token "$@"; }

check_version() {
  local v
  v=$(curl -fsS -m 5 "$URL/healthz" | jq -r '.version // empty') \
    || die "$SVC: /healthz at $URL unreachable"
  # A dev image reports 'dev'. Only with --dev, and only when you know it is new enough.
  if [[ $v == dev ]] && ((DEV)) && [[ ${TRUST_DEV_BUILD:-} == 1 ]]; then
    say "$SVC dev build at $URL (container $CONTAINER), trusted by TRUST_DEV_BUILD=1"; return
  fi
  [[ $v =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "$SVC reports version '$v', not semver: refusing (an old binary serves on unknown subcommands)"
  [[ $(printf '%s\n%s\n' "$MIN" "$v" | sort -V | head -1) == "$MIN" ]] \
    || die "$SVC is $v; service tokens need >= $MIN. Deploy it first."
  say "$SVC $v at $URL (container $CONTAINER)"
}

# Live ids for a label: list columns are ID LABEL SCOPE CREATED LAST_USED REVOKED.
live_ids() { cli list | awk -v l="$1" 'NR>1 && $2==l && $6=="-" {print $1}'; }

# Mint for a label. Sets TOKEN and TOKEN_ID; prints nothing secret.
mint_one() {
  local label=$1 out errf
  errf=$(mktemp)
  case "$SVC" in
    argosy)
      out=$(cli mint -label "$label" -scope "$SCOPE" 2>"$errf") || { cat "$errf" >&2; die "argosy mint failed"; }
      TOKEN=$(sed -n 's/^token: *//p' <<<"$out")
      TOKEN_ID=$(sed -n 's/^id: *//p' <<<"$out")
      ;;
    lyceum)
      out=$(cli mint --label "$label" --scope "$SCOPE" 2>"$errf") || { cat "$errf" >&2; die "lyceum mint failed"; }
      TOKEN=${out//[[:space:]]/}
      TOKEN_ID=$(sed -n 's/^minted service token \([0-9]*\).*/\1/p' "$errf")
      ;;
  esac
  rm -f "$errf"
  out=
  [[ $TOKEN == "$PREFIX"* && $TOKEN != *[[:space:]]* ]] \
    || die "$SVC: mint output did not parse as a ${PREFIX} token (nothing stored; revoke the newest '$label' id from 'list')"
  [[ -n $TOKEN_ID ]] || die "$SVC: could not read the new token's id"
  say "$SVC: minted id $TOKEN_ID for '$label' ($SCOPE)"
}

probe() {  # probe <token> -> prints HTTP status only
  curl -sS -o /dev/null -m 5 -w '%{http_code}' \
    -H @<(printf 'Authorization: Bearer %s\r\n' "$1") "$URL$PATH_"
}

expect() {  # expect <want> <token> <what>
  local got; got=$(probe "$2")
  [[ $got == "$1" ]] || die "$SVC: $3 got HTTP $got, want $1"
  say "$SVC: $3 -> HTTP $got"
}

store() {
  printf '%s' "$TOKEN" | signet set --project "$PROJECT" --name "$SECRET"
  say "$SVC: stored as $PROJECT/$SECRET"
}

confirm() { local a; read -r -p "$1 [y/N] " a </dev/tty; [[ $a == y || $a == Y ]]; }

do_list() { check_version; echo "--- $SVC ($CONTAINER)"; cli list; }

do_mint() {
  check_version
  local ids; ids=$(live_ids "$LABEL")
  [[ -z $ids ]] || die "$SVC already has live '$LABEL' token(s): $(echo $ids). Use rotate."
  mint_one "$LABEL"
  expect 200 "$TOKEN" "new token on $PATH_"
  store
  TOKEN=
}

# Rotation is two passes so one deploy covers every service rotated:
#   1. per service: note the live ids, mint a new token, probe it, store it.
#   2. sync once, then a deploy.yml run. `signet sync` updates only the PROD_ENV_FILE
#      GitHub secret; /opt/construct-server/.env is written by deploy.yml alone
#      (render-env.sh), so `make recreate` would keep the OLD token.
#   3. per service: revoke the old ids only once the database shows Satlink switched:
#      the new id used by someone other than this script, and the old ids idle across
#      two collector intervals. A probe by this script cannot prove what Satlink holds.
declare -A ROT_OLD ROT_NEW ROT_TOKEN ROT_PROBED

rotate_prepare() {
  check_version
  local old; old=$(live_ids "$LABEL")
  [[ -n $old ]] || die "$SVC has no live '$LABEL' token to rotate. Use mint."
  say "$SVC: live '$LABEL' ids before rotation: $(echo $old)"
  mint_one "$LABEL"
  expect 200 "$TOKEN" "new token on $PATH_"
  ROT_PROBED[$SVC]=$(date -u +%s)
  store
  ROT_OLD[$SVC]=$old; ROT_NEW[$SVC]=$TOKEN_ID; ROT_TOKEN[$SVC]=$TOKEN
  TOKEN=
}

# LAST USED for one id ("-" if never), RFC3339 UTC, so it compares as a string.
last_used() { cli list | awk -v i="$1" 'NR>1 && $1==i {print $5}'; }

rotate_finish() {
  local new=${ROT_NEW[$SVC]} old=${ROT_OLD[$SVC]} id t
  # last_used_at is stamped at most once a minute, and this script's probe stamped the
  # new id, so only a stamp past probe + 61 s can be Satlink's (it polls every 60 s).
  local after; after=$(date -u -d "@$(( ${ROT_PROBED[$SVC]} + 61 ))" +%Y-%m-%dT%H:%M:%SZ)
  say "$SVC: waiting for Satlink to use the new id $new (LAST USED after $after, up to 6 min)"
  local deadline=$(( SECONDS + 360 ))
  while :; do
    t=$(last_used "$new")
    [[ $t != - && ! $t < $after ]] && break
    (( SECONDS < deadline )) || die "$SVC: new id $new not used by Satlink (LAST USED $t). Nothing revoked. Did deploy.yml run and recreate satlink?"
    sleep 15
  done
  say "$SVC: new id $new last used $t: Satlink has it"
  declare -A before
  for id in $old; do before[$id]=$(last_used "$id"); done
  say "$SVC: checking the old id(s) stay idle for 150 s (two collector intervals plus the stamp floor)"
  sleep 150
  for id in $old; do
    t=$(last_used "$id")
    [[ $t == "${before[$id]}" ]] || die "$SVC: old id $id was used at $t during the check: something still holds it. Nothing revoked."
  done
  for id in $old; do
    [[ $id == "$new" ]] && continue
    cli revoke -id "$id" >&2
  done
  expect 200 "${ROT_TOKEN[$SVC]}" "new token after revoking the old id(s), no $SVC restart"
  ROT_TOKEN[$SVC]=
  cli list >&2
}

do_rotate() {  # do_rotate <services...>
  local s
  for s in "$@"; do svc_set "$s"; rotate_prepare; done
  for s in "$@"; do svc_set "$s"; signet sync --secret "$PROJECT/$SECRET"; done
  echo
  echo "The vault and PROD_ENV_FILE hold the new token(s); the host .env does not yet."
  echo "Run a prod deploy, which renders .env and recreates satlink on the changed env:"
  echo "  gh workflow run deploy.yml --repo Einlanzerous/construct-server"
  echo "and wait for it to succeed. The old token(s) stay live until the checks below pass."
  confirm "deploy.yml finished successfully?" || {
    echo "Stopped. Old and new tokens are both live; re-run 'list' and revoke by id later." >&2; exit 1; }
  for s in "$@"; do svc_set "$s"; rotate_finish; done
}

# Proves revocation is live with no restart: the same token flips 200 -> 401.
do_rehearse() {
  check_version
  mint_one "$REHEARSAL_LABEL"
  expect 200 "$TOKEN" "scratch token before revoke"
  cli revoke -id "$TOKEN_ID" >&2
  expect 401 "$TOKEN" "scratch token after revoke, no $SVC restart"
  TOKEN=
}

do_deliver() {
  ((DEV)) && die "deliver writes the prod vault target; not with --dev"
  signet target add-key --project "$PROJECT" --gh-secret PROD_ENV_FILE \
    --name SATLINK_ARGOSY_TOKEN,SATLINK_LYCEUM_TOKEN
  signet sync --check
  confirm "Preflight passed. Push PROD_ENV_FILE with signet sync?" || exit 1
  signet sync
  [[ -x $CS_CHECKOUT/scripts/assert-env-keys.sh ]] || die "no assert-env-keys.sh under $CS_CHECKOUT"
  (cd "$CS_CHECKOUT" && ./scripts/assert-env-keys.sh --vault)
  echo
  echo "Vault holds both keys. Only now add SATLINK_ARGOSY_TOKEN and SATLINK_LYCEUM_TOKEN"
  echo "to required-env-keys.txt, if they are not there already."
}

main() {
  local args=() a
  for a in "$@"; do [[ $a == --dev ]] && DEV=1 || args+=("$a"); done
  set -- "${args[@]+"${args[@]}"}"
  local cmd=${1:-} which=${2:-both}
  [[ -n $cmd ]] || { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
  ((DEV)) && [[ $cmd != list && $cmd != rehearse ]] && die "--dev is only for list and rehearse"
  [[ $cmd == deliver ]] && { do_deliver; return; }
  local services; [[ $which == both ]] && services="argosy lyceum" || services=$which
  [[ $cmd == rotate ]] && { do_rotate $services; return; }
  local s
  for s in $services; do
    svc_set "$s"
    case "$cmd" in
      list) do_list ;; mint) do_mint ;; rehearse) do_rehearse ;;
      *) die "unknown command: $cmd" ;;
    esac
  done
}

main "$@"
