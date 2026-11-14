#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2015  # single-quoted stub bodies and eval strings are intentional
# test-satlink-edge-rollout.sh — run scripts/satlink-edge-rollout.sh against fake binaries
# (signet, docker, purser-via-docker, gh, systemctl, loginctl, curl, tailscale, make) in a scratch
# dir. Proves: the email and the AUD never reach the record, stdout, any argv, or the
# environment of any child except the one signet injects; dry-run runs nothing; the access phase
# only applies with --apply; a failing check stops the run.
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/satlink-edge-rollout.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
BIN="$T/bin"; mkdir -p "$BIN" "$T/home"
EMAIL='canary.owner@example.test'
AUD="$(printf 'ab%.0s' $(seq 32))"          # 64 hex chars
CALLS="$T/calls.log"; : >"$CALLS"
FAILS=0
ok()   { echo "  ok    $1"; }
fail() { echo "  FAIL  $1"; FAILS=$((FAILS + 1)); }
expect() { if eval "$2"; then ok "$1"; else fail "$1"; fi; }

# Every stub logs its argv and whether a canary is in its environment, then behaves.
cat >"$BIN/_log" <<'EOF'
echo "$(basename "$0") $*" >>"$CALLS_LOG"
if env | grep -qF -f "$CANARY_FILE"; then echo "ENV-LEAK in $(basename "$0")" >>"$CALLS_LOG"; fi
EOF
mk() { printf '#!/usr/bin/env bash\n. "%s/_log"\n%s\n' "$BIN" "$2" >"$BIN/$1"; chmod +x "$BIN/$1"; }
mk signet 'case "$1" in
  set) cat >"$STDIN_SINK"; ;;
  status) echo "construct-server   SATLINK_ACCESS_ALLOWED_EMAILS  #aaaaaa active - gh-render:x→PROD_ENV_FILE [in sync]" ;;
  exec) shift; while [ "$1" != "--" ]; do shift; done; shift; SATLINK_ACCESS_ALLOWED_EMAILS="$(head -1 "$CANARY_FILE")" exec "$@" ;;
esac'
mk docker 'case "$*" in
  *"inspect"*) echo healthy ;;
  *"purser provision-service"*) if [ "${*: -1}" = "--apply" ]; then echo "applied"; else echo "satlink: 3 in place, 0 to do, 0 skipped"; fi ;;
  *wget*) echo "  HTTP/1.1 403 Forbidden" >&2; exit 1 ;;
esac'
mk gh 'd="$4"; mkdir -p "$d/host/docker-state"; git -C "$d" init -q; git -C "$d" -c user.email=a@b -c user.name=a commit -q --allow-empty -m x; git -C "$d" tag v0.2.0
printf "#!/bin/sh\necho installed \"\$SATLINK_TAG\"\n" >"$d/host/docker-state/install.sh"; chmod +x "$d/host/docker-state/install.sh"'
mk systemctl 'case "$*" in *is-active*) echo active ;; *) echo "NEXT LEFT satlink-docker-state.timer" ;; esac'
mk loginctl 'echo Linger=yes'
mk curl 'case "$*" in *"-w"*) echo 302 ;; *) printf "HTTP/2 302\r\nlocation: https://team.cloudflareaccess.com/x\r\n" ;; esac'
mk tailscale 'echo "No serve config"'
mk make 'echo "assert-env-keys ok"'
printf "%s\n%s\n" "$EMAIL" "$AUD" >"$T/canaries"
export CALLS_LOG="$CALLS" CANARY_FILE="$T/canaries" STDIN_SINK="$T/stdin.sink"
export PATH="$BIN:$PATH" HOME="$T/home" SATLINK_ROLLOUT_AGE_GAP=1
STATE="$T/state/docker-state.json"; mkdir -p "$T/state"; touch "$STATE"; export SATLINK_STATE_FILE="$STATE"

# A repo stand-in for the access phase: a git checkout holding two placeholders.
mkrepo() {
  R="$T/repo$1"; mkdir -p "$R/scripts"; cp "$SCRIPT" "$R/scripts/"
  git -C "$R" init -q
  printf 'CF_ACCESS_AUD=__SATLINK_ACCESS_AUD__\nMAP=satlink.zerogravity.industries=__SATLINK_ACCESS_AUD__\n' >"$R/docker-compose.yml"
  git -C "$R" add -A; git -C "$R" -c user.email=a@b -c user.name=a commit -q -m base
}
leak_check() {   # leak_check LABEL RECORD STDOUTFILE
  local f
  for f in "$2" "$3" "$CALLS"; do
    expect "$1: no email or AUD in $(basename "$f")" '! grep -qF -e "$EMAIL" -e "$AUD" "$f"'
  done
  expect "$1: no secret in any child env" '! grep -q ENV-LEAK "$CALLS"'
}

echo "dry-run: prints, runs nothing"
: >"$CALLS"
bash "$SCRIPT" --dry-run --yes --record "$T/dry.md" all >"$T/dry.out" 2>&1 || fail "dry-run all exited non-zero"
expect "dry-run all exits 0 and says DRY-RUN" 'grep -q "DRY-RUN" "$T/dry.md"'
expect "dry-run invoked no stubs" '[ ! -s "$CALLS" ]'
expect "dry-run shows the purser plan command" 'grep -q "purser provision-service" "$T/dry.md"'
expect "dry-run never prints --apply for purser" '! grep -q -- "--apply" <(grep "purser provision-service" "$T/dry.md")'

echo "vault: email via stdin pipe only"
: >"$CALLS"
# Key absent -> set runs. Make status report no row first, then the row after sync.
mk signet 'case "$1" in
  set) cat >"$STDIN_SINK"; touch "$STDIN_SINK.done" ;;
  status) if [ -e "$STDIN_SINK.done" ]; then echo "construct-server   SATLINK_ACCESS_ALLOWED_EMAILS  #aaaaaa active - gh-render:x→PROD_ENV_FILE [in sync]"; fi ;;
  exec) shift; while [ "$1" != "--" ]; do shift; done; shift; SATLINK_ACCESS_ALLOWED_EMAILS="$(head -1 "$CANARY_FILE")" exec "$@" ;;
esac'
printf '%s\n' "$EMAIL" | bash "$SCRIPT" --yes --secrets-from-stdin --record "$T/vault.md" vault >"$T/vault.out" 2>&1 || { fail "vault exited non-zero"; cat "$T/vault.out"; }
leak_check vault "$T/vault.md" "$T/vault.out"
expect "vault: the email did reach signet set on stdin" '[ "$(cat "$STDIN_SINK")" = "$EMAIL" ]'
expect "vault: signet set argv has no value" 'grep -q "^signet set --project construct-server --name SATLINK_ACCESS_ALLOWED_EMAILS$" "$CALLS"'
expect "vault: in-sync and non-empty checks recorded as PASS" '[ "$(grep -c "PASS" "$T/vault.md")" -ge 3 ]'
echo "vault: second run is idempotent (key present: no set, no second prompt)"
: >"$CALLS"
bash "$SCRIPT" --yes --record "$T/vault2.md" vault </dev/null >"$T/vault2.out" 2>&1 || { fail "vault rerun exited non-zero"; cat "$T/vault2.out"; }
expect "vault rerun: signet set not called" '! grep -q "^signet set" "$CALLS"'
expect "vault rerun: add-key skipped (already targets PROD_ENV_FILE)" '! grep -q "^signet target add-key" "$CALLS"'

echo "access: plan only without --apply; AUD patched without a trace"
mkrepo 1
: >"$CALLS"
printf '%s\n' "$AUD" | bash "$R/scripts/satlink-edge-rollout.sh" --yes --secrets-from-stdin --record "$T/acc.md" access >"$T/acc.out" 2>&1 || { fail "access exited non-zero"; cat "$T/acc.out"; }
leak_check access "$T/acc.md" "$T/acc.out"
expect "access: no --apply reached purser" '! grep -q -- "--apply" "$CALLS"'
expect "access: both placeholders replaced" '[ "$(grep -cF "$AUD" "$R/docker-compose.yml")" = 2 ] && ! grep -q __SATLINK_ACCESS_AUD__ "$R/docker-compose.yml"'
expect "access: nothing committed" '[ "$(git -C "$R" rev-list --count HEAD)" = 1 ]'
expect "access: diff on screen is masked" 'grep -q "<AUD>" "$T/acc.out"'
echo "access: rerun idempotent; env AUD is not inherited by children; --apply does apply"
: >"$CALLS"
SATLINK_ACCESS_AUD="$AUD" bash "$R/scripts/satlink-edge-rollout.sh" --yes --apply --confirm-apply --record "$T/acc2.md" access >"$T/acc2.out" 2>&1 </dev/null || { fail "access rerun exited non-zero"; cat "$T/acc2.out"; }
leak_check access-rerun "$T/acc2.md" "$T/acc2.out"
expect "access rerun: apply ran once, only with --apply" '[ "$(grep -c -- "--apply" "$CALLS")" = 1 ]'
expect "access rerun: reports nothing to patch" 'grep -q "nothing to patch" "$T/acc2.md"'
echo "access: bad AUD refused"
mkrepo 2
printf 'not-hex\n' | bash "$R/scripts/satlink-edge-rollout.sh" --yes --secrets-from-stdin --record "$T/acc3.md" access >/dev/null 2>&1 && fail "bad AUD accepted" || ok "bad AUD refused"
expect "bad AUD: placeholders untouched" '[ "$(grep -c __SATLINK_ACCESS_AUD__ "$R/docker-compose.yml")" = 2 ]'

echo "exporter, pre-merge, post-deploy: happy path"
touch "$STATE"
: >"$CALLS"
bash "$SCRIPT" --yes --record "$T/exp.md" exporter >"$T/exp.out" 2>&1 || { fail "exporter exited non-zero"; cat "$T/exp.out"; }
expect "exporter: ran install.sh with SATLINK_TAG=0.2.0" 'grep -q "install.sh" "$T/exp.md" && grep -q "SATLINK_TAG=0.2.0" "$T/exp.md"'
expect "exporter: two age checks passed" '[ "$(grep -c "state file younger" "$T/exp.md")" -eq 2 ] && ! grep -q FAIL "$T/exp.md"'
mkrepo 3; printf "ok\n" >"$R/docker-compose.yml"; git -C "$R" -c user.email=a@b -c user.name=a commit -qam patched; git -C "$R" branch -m feat/satlink-edge-satl-58; git clone -q --bare "$R" "$T/origin.git"; git -C "$R" remote add origin "$T/origin.git"
bash "$R/scripts/satlink-edge-rollout.sh" --yes --record "$T/pre.md" pre-merge >"$T/pre.out" 2>&1 || { fail "pre-merge exited non-zero"; tail -5 "$T/pre.out"; }
bash "$SCRIPT" --yes --record "$T/post.md" post-deploy >"$T/post.out" 2>&1 || { fail "post-deploy exited non-zero"; tail -5 "$T/post.out"; }
expect "post-deploy: owner checks listed as pending, not automated" 'grep -q "OWNER-CHECK" "$T/post.md" && grep -q "/api/collectors" "$T/post.md"'

echo "stops at first failure"
mk docker 'case "$*" in *inspect*) echo unhealthy ;; esac'
bash "$SCRIPT" --yes --record "$T/bad.md" post-deploy >"$T/bad.out" 2>&1 && fail "unhealthy guard passed" || ok "unhealthy guard exits non-zero"
expect "stopped after the guard check" '! grep -q "Access 302" "$T/bad.md" && grep -q "FAIL" "$T/bad.md"'

echo
[ "$FAILS" -eq 0 ] && { echo "all passed"; exit 0; } || { echo "$FAILS failed"; exit 1; }
