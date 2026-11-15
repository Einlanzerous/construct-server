#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2015,SC2034  # single-quoted stub bodies and eval strings are intentional
# test-traefik-access-log-rollout.sh — run scripts/traefik-access-log-rollout.sh against fake
# binaries (docker, gh, sudo, logrotate, make, curl) in a scratch dir. The access log is a REAL file
# of synthetic JSON lines read through the real jq pipeline, so the count assertions are genuine.
# Proves, per phase, a pass path and the fail paths: digest drift PAUSE, old-config-still-live,
# a leaked Cf-Access key, subject absent, crowdsec not advancing, a 403 carrying a subject,
# missed reopen after rotate; dry-run runs nothing; no synthetic log value reaches a record,
# stdout or an argv. Touches nothing on the host.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/traefik-access-log-rollout.sh"
T="$(mktemp -d)"
APPENDER_PID_FILE="$T/appender.pid"
cleanup() {
  if [ -s "$APPENDER_PID_FILE" ]; then kill "$(cat "$APPENDER_PID_FILE")" 2>/dev/null || true; fi
  rm -rf "$T"
}
trap cleanup EXIT
BIN="$T/bin"; F="$T/fake"; mkdir -p "$BIN" "$F" "$T/home" "$T/logs" "$T/etc"
CALLS="$T/calls.log"; : >"$CALLS"
FAILS=0
ok()   { echo "  ok    $1"; }
fail() { echo "  FAIL  $1"; FAILS=$((FAILS + 1)); }
expect() { if eval "$2"; then ok "$1"; else fail "$1"; fi; }

# Canaries: values that must never reach a record, stdout or an argv.
UA='Canary-Agent/9.9'; SUBJ='canary-subject-0001'; MAIL='canary.person@example.test'; IP='203.0.113.77'
printf '%s\n' "$UA" "$SUBJ" "$MAIL" "$IP" >"$T/canaries"

# ── a repo stand-in: the script copy, a drop-in, two commits of traefik.yml, an origin with main ──
R="$T/repo"; mkdir -p "$R/scripts" "$R/config/logrotate" "$R/config/traefik"
cp "$SRC" "$R/scripts/"
printf '# synthetic drop-in\n/x/access.log {\n  daily\n}\n' >"$R/config/logrotate/traefik-access"
printf 'accessLog:\n  format: json\nentryPoints:\n  internal:\n    address: "172.31.240.10:9080"\n' >"$R/config/traefik/traefik.yml"
git -C "$R" init -q -b main; git -C "$R" add -A; git -C "$R" -c user.email=a@b -c user.name=a commit -q -m old
printf 'accessLog:\n  format: json\n  fields:\n    headers:\n      names:\n        X-Access-Subject: keep\nentryPoints:\n  internal:\n    address: "172.31.240.10:9080"\n' >"$R/config/traefik/traefik.yml"
git -C "$R" -c user.email=a@b -c user.name=a commit -qam new
git clone -q --bare "$R" "$T/origin.git"; git -C "$R" remote add origin "$T/origin.git"
S="$R/scripts/traefik-access-log-rollout.sh"

# ── deployed-copy stand-in ──
D="$T/deploy"; mkdir -p "$D/config/traefik"
cp "$R/config/traefik/traefik.yml" "$D/config/traefik/traefik.yml"
: >"$D/docker-compose.yml"; : >"$D/.env"
printf 'LYCEUM_TAG=1.13\nSATLINK_TAG=0.5.0\n' >"$D/versions.env"
printf 'LYCEUM_TAG=1.13\nSATLINK_TAG=0.5.0\n' >"$F/main_versions"

# ── fake binaries ──
cat >"$BIN/_log" <<'EOF'
echo "$(basename "$0") $*" >>"$CALLS_LOG"
EOF
mk() { printf '#!/usr/bin/env bash\n. "%s/_log"\n%s\n' "$BIN" "$2" >"$BIN/$1"; chmod +x "$BIN/$1"; }
mk sudo 'case "$1" in -n|-v) [ "${2:-}" = true ] && exit "$(cat "$FAKE/sudo_n_rc" 2>/dev/null || echo 0)"; exit 0 ;; esac
if [ "$1" = install ]; then shift; args=(); while [ $# -gt 0 ]; do case "$1" in -o|-g) shift ;; *) args+=("$1") ;; esac; shift; done
  src="${args[-2]}"; dst="${args[-1]}"; cp "$src" "$dst"; [ -e "$FAKE/corrupt_install" ] && echo junk >>"$dst"; exit 0; fi
exec "$@"'
mk logrotate 'case "$1" in
  -d) if [ -e "$FAKE/lr_d_error" ]; then echo "error: bad config"; exit 1; fi; echo "reading config"; exit 0 ;;
  -f) log="$LOGDIR/access.log"; mv "$log" "$log.1"; : >"$log"
      tgt="$log"; [ -e "$FAKE/missed_reopen" ] && tgt="$log.1"
      ( for i in $(seq 1 80); do echo "{\"entryPointName\":\"internal\"}" >>"$tgt"; sleep 0.1; done ) </dev/null >/dev/null 2>&1 &
      echo $! >"$APPENDER_PID_FILE"; exit 0 ;;
esac'
mk make 'case "$*" in
  *edge-auth-check*) exit "$(cat "$FAKE/edge_rc" 2>/dev/null || echo 0)" ;;
  *"assert-env-keys vault=1"*) exit "$(cat "$FAKE/env_rc" 2>/dev/null || echo 0)" ;;
  *"recreate svc=traefik"*) [ -e "$FAKE/recreate_changes_image" ] && echo "sha256:changed" >"$FAKE/traefik_img_now"; exit 0 ;;
esac'
mk curl 'case "$*" in *"-w"*) cat "$FAKE/probe_code" 2>/dev/null || echo 403 ;; esac'
mk gh 'case "$*" in
  *"pr view 296"*) cat "$FAKE/gh_296" ;;
  *"pr view"*) cat "$FAKE/gh_pr" ;;
  *"contents/versions.env"*) cat "$FAKE/main_versions" ;;
  *"run list"*) cat "$FAKE/gh_run" ;;
esac'
mk docker 'case "$*" in
  *"config --format json"*) cat "$FAKE/config.json" ;;
  *"ps -aq"*) cut -d"|" -f1 "$FAKE/containers.txt" ;;
  *"inspect -f {{index .Config.Labels"*) id="${*: -1}"; grep "^$id|" "$FAKE/containers.txt" | cut -d"|" -f2- ;;
  *"buildx imagetools inspect"*) ref="$4"; grep "^$ref " "$FAKE/registry.txt" | cut -d" " -f2 ;;
  *"image inspect"*) id="${*: -1}"; grep "^$id " "$FAKE/imgdigests.txt" | cut -d" " -f2- || true ;;
  *"State.StartedAt"*) echo "2026-11-14T01:00:00.000000000Z|$(cat "$FAKE/traefik_img_now")" ;;
  *"State.Running"*) [ -e "$FAKE/no_satlink" ] && exit 1; echo true ;;
  *"exec crowdsec cscli"*) n="$(cat "$FAKE/cs_reads")"; [ -e "$FAKE/cs_const" ] || echo $((n + 100)) >"$FAKE/cs_reads"
      echo "{\"acquisition\":{\"file:/var/log/traefik/access.log\":{\"reads\":$n}}}" ;;
  *"exec traefik grep"*) cat "$FAKE/live_subj_count" ;;
  *"logs --since"*) cat "$FAKE/satlink.log" ;;
esac'

export CALLS_LOG="$CALLS" FAKE="$F" LOGDIR="$T/logs" APPENDER_PID_FILE
export PATH="$BIN:$PATH" HOME="$T/home"
export DEPLOY_ROOT="$D" TRAEFIK_LOG_DIR="$T/logs" DROPIN_DEST="$T/etc/traefik-access" TRAEFIK_ROLLOUT_DIR="$T/state"
export TRAEFIK_ROLLOUT_DEPLOY_POLL_MAX=2 TRAEFIK_ROLLOUT_DEPLOY_POLL_GAP=1 TRAEFIK_ROLLOUT_MERGE_POLL_MAX=2
export TRAEFIK_ROLLOUT_HEALTHY_MAX=2 TRAEFIK_ROLLOUT_SAMPLE_GAP=1 TRAEFIK_ROLLOUT_ROTATE_WAIT=4
export TRAEFIK_ROLLOUT_COLLECTOR_WAIT=2 TRAEFIK_ROLLOUT_CROWDSEC_WAIT=2 TRAEFIK_ROLLOUT_POLL_GAP=1

# fixtures -------------------------------------------------------------------------------------
reset_fake() {
  rm -f "$F"/* "$T/etc/"* "$T/state/state.kv"; : >"$CALLS"; rm -f "$T/logs/"*
  echo MERGED >"$F/gh_296"
  echo '{"state":"MERGED","baseRefName":"main","mergeCommit":{"oid":"abcdef0123456789abcdef0123456789abcdef01"}}' >"$F/gh_pr"
  echo '[{"status":"completed","conclusion":"success","databaseId":42}]' >"$F/gh_run"
  printf 'LYCEUM_TAG=1.13\nSATLINK_TAG=0.5.0\n' >"$F/main_versions"
  echo '{"services":{"lyceum":{"image":"ghcr.io/einlanzerous/lyceum:1.13"},"satlink":{"image":"ghcr.io/einlanzerous/satlink:0.5.0"},"traefik":{"image":"traefik:v3.3@sha256:t"}}}' >"$F/config.json"
  printf 'c1|lyceum|ghcr.io/einlanzerous/lyceum:1.13|sha256:img1\nc2|satlink|ghcr.io/einlanzerous/satlink:0.5.0|sha256:img2\nc3|traefik|traefik:v3.3@sha256:t|sha256:imgt\n' >"$F/containers.txt"
  printf 'ghcr.io/einlanzerous/lyceum:1.13 sha256:aaa\nghcr.io/einlanzerous/satlink:0.5.0 sha256:bbb\n' >"$F/registry.txt"
  printf 'sha256:img1 ghcr.io/einlanzerous/lyceum@sha256:aaa\nsha256:img2 ghcr.io/einlanzerous/satlink@sha256:bbb\nsha256:imgt traefik@sha256:t\n' >"$F/imgdigests.txt"
  echo sha256:imgt >"$F/traefik_img_now"
  echo 1000 >"$F/cs_reads"
  echo 0 >"$F/live_subj_count"
  printf '[traefik-rollup] read 60 lines, 0 malformed\n[traefik-rollup] read 61 lines, 0 malformed\n' >"$F/satlink.log"
  cp "$R/config/traefik/traefik.yml" "$D/config/traefik/traefik.yml"
  printf '{"pre":"offset-junk"}\n' >"$T/logs/access.log"
}
l_ok()   { printf '{"entryPointName":"internal","DownstreamStatus":200,"ClientAddr":"%s:1","request_User-Agent":"%s","request_X-Access-Subject":"%s"}\n' "$IP" "$UA" "$SUBJ"; }
l_403()  { printf '{"entryPointName":"internal","DownstreamStatus":403,"ClientAddr":"%s:1","request_User-Agent":"%s"}\n' "$IP" "$UA"; }
l_pub()  { printf '{"entryPointName":"websecure","DownstreamStatus":200,"request_User-Agent":"%s"}\n' "$UA"; }
l_jwt()  { printf '{"entryPointName":"internal","DownstreamStatus":200,"request_User-Agent":"%s","request_Cf-Access-Jwt-Assertion":"%s"}\n' "$UA" "$SUBJ"; }
l_mail() { printf '{"entryPointName":"internal","DownstreamStatus":200,"request_User-Agent":"%s","request_Cf-Access-Authenticated-User-Email":"%s"}\n' "$UA" "$MAIL"; }
l_403s() { printf '{"entryPointName":"internal","DownstreamStatus":403,"request_User-Agent":"%s","request_X-Access-Subject":"%s"}\n' "$UA" "$SUBJ"; }
l_nous() { printf '{"entryPointName":"internal","DownstreamStatus":200,"ClientAddr":"%s:1"}\n' "$IP"; }
# state as if preflight + recreate had run: offset = size of the junk line already in the log
set_state() {
  mkdir -p "$T/state"
  printf 'recreate_offset=%s\nrecreate_ts=2026-11-14T02:00:00Z\ncrowdsec_baseline=1000\npf_guard_state=MERGED\n' "$(stat -c %s "$T/logs/access.log")" >"$T/state/state.kv"
}
# run SCRIPT-args... : record to $T/rec.md, stdout to $T/out.txt; returns the exit code. No tty.
go() { local rc=0; rm -f "$T/rec.md"; setsid -w bash "$S" --record "$T/rec.md" "$@" >"$T/out.txt" 2>&1 </dev/null || rc=$?; cat "$T/rec.md" "$T/out.txt" >>"$T/all.log" 2>/dev/null || true; return $rc; }
rc_of() { local rc=0; "$@" || rc=$?; echo "$rc"; }

echo "dry-run: only plans, changes nothing"
reset_fake
for ph in dropin merge-gate recreate rotate rollback; do
  expect "dry-run $ph exits 0" '[ "$(rc_of go $ph)" = 0 ]'
  expect "dry-run $ph says DRY-RUN" 'grep -q "DRY-RUN" "$T/rec.md"'
done
expect "dry-run invoked no sudo/make/logrotate" '! grep -Eq "^(sudo|logrotate|make) " "$CALLS"'
expect "no phase flag is a usage error" '[ "$(rc_of go)" = 2 ]'

echo "preflight: pass path"
reset_fake
expect "preflight exits 0" '[ "$(rc_of go preflight)" = 0 ]'
expect "preflight: nine PASS lines, no FAIL" '[ "$(grep -c "PASS" "$T/rec.md")" = 9 ] && ! grep -q "FAIL" "$T/rec.md"'
expect "preflight recorded the crowdsec baseline" 'grep -q "^crowdsec_baseline=" "$T/state/state.kv"'
expect "preflight made no mutating call" '! grep -Eq "recreate|logrotate -f|install|kill" "$CALLS"'

echo "preflight: failure paths"
reset_fake; echo OPEN >"$F/gh_296"
expect "#296 not merged FAILS" '[ "$(rc_of go preflight)" = 1 ] && grep -q "FAIL.*#296" "$T/rec.md"'
reset_fake; : >"$T/logs/access.log.1"
expect "a rotated sibling FAILS" '[ "$(rc_of go preflight)" = 1 ] && grep -q "FAIL.*rotated sibling" "$T/rec.md"'
reset_fake; echo 1 >"$F/env_rc"
expect "assert-env-keys failure FAILS" '[ "$(rc_of go preflight)" = 1 ]'
reset_fake; echo 1 >"$F/edge_rc"
expect "edge-auth-check baseline failure FAILS" '[ "$(rc_of go preflight)" = 1 ]'

echo "preflight: digest drift PAUSES"
reset_fake; echo sha256:zzz >"$F/registry.txt.new"; sed -i 's/aaa/zzz/' "$F/registry.txt"
expect "dry-run lists the drift and does not wait (exit 0)" '[ "$(rc_of go preflight)" = 0 ] && grep -q "PENDING:.*lyceum(digest)" "$T/rec.md" && grep -q "dry-run: not waiting" "$T/rec.md"'
expect "--apply with no terminal PAUSES (exit 3), names the service" '[ "$(rc_of go preflight --apply)" = 3 ] && grep -q "PAUSED" "$T/rec.md" && grep -q "lyceum" "$T/rec.md"'
expect "--apply --confirm-apply proceeds past the pause" '[ "$(rc_of go preflight --apply --confirm-apply)" = 0 ]'
reset_fake; sed -i 's/1.13/1.12/' "$F/containers.txt"
expect "a running tag older than the pin is pending (tag)" 'go preflight >/dev/null; grep -q "lyceum(tag)" "$T/rec.md"'
reset_fake; printf 'LYCEUM_TAG=1.14\nSATLINK_TAG=0.5.0\n' >"$F/main_versions"
expect "deployed versions.env differing from origin/main is pending" 'go preflight >/dev/null; grep -q "versions.env:LYCEUM_TAG" "$T/rec.md"'

echo "dropin"
reset_fake
expect "dropin --apply passes" '[ "$(rc_of go dropin --apply)" = 0 ]'
expect "dropin: installed file equals the repo copy" 'cmp -s "$R/config/logrotate/traefik-access" "$T/etc/traefik-access"'
expect "dropin: validated twice and notes the ansible role" '[ "$(grep -c "^logrotate -d" "$CALLS")" = 2 ] && grep -q -- "--tags logrotate" "$T/rec.md"'
: >"$CALLS"
expect "dropin rerun is idempotent (install skipped)" '[ "$(rc_of go dropin --apply)" = 0 ] && grep -q "install skipped" "$T/rec.md" && [ "$(grep -c "^sudo install" "$CALLS")" = 1 ]'
reset_fake; touch "$F/lr_d_error"
expect "a logrotate -d error FAILS before installing" '[ "$(rc_of go dropin --apply)" = 1 ] && [ ! -e "$T/etc/traefik-access" ]'
reset_fake; touch "$F/corrupt_install"
expect "an installed copy that differs FAILS the byte-for-byte assertion" '[ "$(rc_of go dropin --apply)" = 1 ] && grep -q "FAIL.*byte for byte" "$T/rec.md"'

echo "merge-gate"
reset_fake
expect "merge-gate passes: merged, deploy green, old config live" '[ "$(rc_of go merge-gate --apply --confirm-apply)" = 0 ] && grep -q "OLD config" "$T/rec.md" && ! grep -q FAIL "$T/rec.md"'
expect "merge-gate with no terminal pauses for the owner (exit 3)" '[ "$(rc_of go merge-gate --apply)" = 3 ]'
expect "merge-gate printed the retarget sequence and never merges" 'grep -q "gh api -X PATCH" "$T/rec.md" && ! grep -q "pr merge" "$CALLS"'
reset_fake; echo 1 >"$F/live_subj_count"
expect "new config already live FAILS (not the SERV-164 state)" '[ "$(rc_of go merge-gate --apply --confirm-apply)" = 1 ] && grep -q "FAIL.*OLD config" "$T/rec.md"'
reset_fake; echo '[{"status":"completed","conclusion":"failure","databaseId":42}]' >"$F/gh_run"
expect "a red deploy run FAILS" '[ "$(rc_of go merge-gate --apply --confirm-apply)" = 1 ] && grep -q "FAIL.*finished green" "$T/rec.md"'
reset_fake; echo '[{"status":"in_progress","conclusion":"","databaseId":42}]' >"$F/gh_run"
expect "a deploy that never finishes FAILS after the bounded poll" '[ "$(rc_of go merge-gate --apply --confirm-apply)" = 1 ] && grep -q "did not finish" "$T/rec.md"'
reset_fake; echo '[]' >"$F/gh_run"
expect "no deploy run at all FAILS after the bounded poll" '[ "$(rc_of go merge-gate --apply --confirm-apply)" = 1 ]'
reset_fake; echo '{"state":"OPEN","baseRefName":"main","mergeCommit":null}' >"$F/gh_pr"
expect "an unmerged PR FAILS after the bounded poll" '[ "$(rc_of go merge-gate --apply --confirm-apply)" = 1 ]'
reset_fake; echo '{"state":"MERGED","baseRefName":"feat/x","mergeCommit":{"oid":"abc"}}' >"$F/gh_pr"
expect "merged into a branch other than main FAILS" '[ "$(rc_of go merge-gate --apply --confirm-apply)" = 1 ]'

echo "recreate"
reset_fake
expect "recreate passes" '[ "$(rc_of go recreate --apply)" = 0 ]'
expect "recreate: timed the first healthy response, same image, edge-auth-check, offset recorded" \
  'grep -q "first healthy edge response" "$T/rec.md" && grep -q "same image" "$T/rec.md" && grep -q "^recreate_offset=" "$T/state/state.kv" && grep -q "make -C $D edge-auth-check" "$CALLS"'
expect "recreate ran make from the deployed copy, scoped to traefik" 'grep -q "^make -C $D recreate svc=traefik" "$CALLS"'
reset_fake; touch "$F/recreate_changes_image"
expect "a changed image id FAILS" '[ "$(rc_of go recreate --apply)" = 1 ] && grep -q "FAIL.*same image" "$T/rec.md"'
reset_fake; echo 000 >"$F/probe_code"
expect "an edge that never answers FAILS after the bound" '[ "$(rc_of go recreate --apply)" = 1 ] && grep -q "no healthy edge response" "$T/rec.md"'
reset_fake; echo 1 >"$F/edge_rc"
expect "edge-auth-check failing after the recreate FAILS" '[ "$(rc_of go recreate --apply)" = 1 ]'
reset_fake; sed -i 's/X-Access-Subject/Other/' "$D/config/traefik/traefik.yml"
expect "a deployed copy without the new fields refuses to recreate" '[ "$(rc_of go recreate --apply)" = 1 ] && ! grep -q "recreate svc" "$CALLS"'

echo "verify"
good() { { l_ok; l_ok; l_pub; l_403; l_nous; } >>"$T/logs/access.log"; }
reset_fake; set_state; good
expect "verify passes on good lines" '[ "$(rc_of go verify)" = 0 ]'
expect "verify counted: 5 lines, 2 subjects, 1 on a 403 line... none" 'grep -q "total=5" "$T/rec.md" && grep -q "s403_subj=0" "$T/rec.md" && grep -q "leak_jwt=0" "$T/rec.md"'
expect "verify counted only lines after the offset (the junk line is excluded)" '! grep -q "total=6" "$T/rec.md"'
reset_fake; set_state; good; l_jwt >>"$T/logs/access.log"
expect "a leaked Cf-Access-Jwt-Assertion key FAILS verify" '[ "$(rc_of go verify)" = 1 ] && grep -q "FAIL.*Jwt-Assertion" "$T/rec.md"'
reset_fake; set_state; good; l_mail >>"$T/logs/access.log"
expect "a leaked Cf-Access-Authenticated-User-Email key FAILS verify" '[ "$(rc_of go verify)" = 1 ] && grep -q "FAIL.*Authenticated-User-Email" "$T/rec.md"'
reset_fake; set_state; { l_nous; l_403; l_pub; } >>"$T/logs/access.log"
expect "subject absent on every 2xx internal line FAILS" '[ "$(rc_of go verify)" = 1 ] && grep -q "FAIL.*X-Access-Subject present" "$T/rec.md"'
reset_fake; set_state; good; l_403s >>"$T/logs/access.log"
expect "a 403 line carrying a subject FAILS" '[ "$(rc_of go verify)" = 1 ] && grep -q "FAIL.*no 403 line carries a subject" "$T/rec.md"'
reset_fake; set_state; { l_ok; l_ok; } >>"$T/logs/access.log"
expect "no 403 line to judge FAILS" '[ "$(rc_of go verify)" = 1 ] && grep -q "FAIL.*403 lines exist" "$T/rec.md"'
reset_fake; set_state; good; touch "$F/cs_const"
expect "crowdsec lines-read not advancing FAILS" '[ "$(rc_of go verify)" = 1 ] && grep -q "FAIL.*crowdsec lines-read advanced" "$T/rec.md"'
reset_fake; set_state; good; : >"$F/satlink.log"
expect "a silent satlink collector FAILS" '[ "$(rc_of go verify)" = 1 ] && grep -q "FAIL.*satlink collector" "$T/rec.md"'
reset_fake; set_state; good; echo '[traefik-rollup] read 3 lines' >"$F/satlink.log"; echo '[traefik-rollup] error: cannot read' >>"$F/satlink.log"
expect "an error-looking collector line FAILS" '[ "$(rc_of go verify)" = 1 ]'
reset_fake; set_state; good; echo 1 >"$F/edge_rc"
expect "edge-auth-check failing FAILS verify" '[ "$(rc_of go verify)" = 1 ]'
reset_fake
expect "verify without a recorded recreate refuses" '[ "$(rc_of go verify)" = 1 ] && grep -q "run the recreate phase first" "$T/rec.md"'
reset_fake; set_state; good
go verify >/dev/null || true
expect "a green verify marks the state" 'grep -q "^verify_ok=1" "$T/state/state.kv"'

echo "rotate"
rot_ready() { reset_fake; set_state; good; go verify >/dev/null; cp "$R/config/logrotate/traefik-access" "$T/etc/traefik-access"; printf 'dropin_ok=1\n' >>"$T/state/state.kv"
  printf '[traefik-rollup] read 5 lines\n[traefik-rollup] rotated file read: 5 lines\n' >"$F/satlink.log"; }
rot_ready
expect "rotate without a terminal or --confirm-rotate refuses" '[ "$(rc_of go rotate --apply)" = 1 ] && ! grep -q "^logrotate -f" "$CALLS" && [ ! -e "$T/logs/access.log.1" ]'
expect "rotate passes: .1 plain and stable, new log grows, crowdsec advancing, collector read" '[ "$(rc_of go rotate --apply --confirm-rotate)" = 0 ] && [ -e "$T/logs/access.log.1" ] && ! grep -q FAIL "$T/rec.md"'
expect "rotate recorded the evidence keys" 'grep -q "^rotate_ok=1" "$T/state/state.kv"'
kill "$(cat "$APPENDER_PID_FILE")" 2>/dev/null || true
rot_ready; touch "$F/missed_reopen"
expect "MISSED REOPEN (a growing access.log.1) FAILS" '[ "$(rc_of go rotate --apply --confirm-rotate)" = 1 ] && grep -q "FAIL.*not growing" "$T/rec.md"'
kill "$(cat "$APPENDER_PID_FILE")" 2>/dev/null || true
rot_ready; touch "$F/cs_const"
expect "crowdsec stalled after the rotation FAILS" '[ "$(rc_of go rotate --apply --confirm-rotate)" = 1 ] && grep -q "FAIL.*crowdsec" "$T/rec.md"'
kill "$(cat "$APPENDER_PID_FILE")" 2>/dev/null || true
rot_ready; echo '[traefik-rollup] read 5 lines' >"$F/satlink.log"
expect "no rotated-file read by the collector FAILS" '[ "$(rc_of go rotate --apply --confirm-rotate)" = 1 ] && grep -q "FAIL.*rotated-file read" "$T/rec.md"'
kill "$(cat "$APPENDER_PID_FILE")" 2>/dev/null || true
rot_ready; : >"$T/logs/access.log.1"
expect "an existing access.log.1 refuses to rotate over it" '[ "$(rc_of go rotate --apply --confirm-rotate)" = 1 ] && ! grep -q "^logrotate -f" "$CALLS"'
rot_ready; sed -i '/^verify_ok/d' "$T/state/state.kv"
expect "rotate refuses until verify has passed" '[ "$(rc_of go rotate --apply --confirm-rotate)" = 1 ] && ! grep -q "^logrotate -f" "$CALLS"'

echo "rollback"
reset_fake
expect "rollback with no terminal and no confirmation refuses" '[ "$(ROLLBACK_REF=HEAD~1 rc_of go rollback --apply)" = 1 ] && grep -q "needs a terminal" "$T/rec.md"'
reset_fake
expect "rollback restores the previous traefik.yml, recreates, removes the drop-in" \
  '[ "$(ROLLBACK_REF=HEAD~1 rc_of go rollback --apply --confirm-rollback)" = 0 ] && ! grep -q X-Access-Subject "$D/config/traefik/traefik.yml" && grep -q "^make -C $D recreate svc=traefik" "$CALLS" && grep -q "^sudo rm -f $T/etc/traefik-access" "$CALLS"'
reset_fake
expect "rollback with a ref that still has the new fields refuses" '[ "$(ROLLBACK_REF=HEAD rc_of go rollback --apply --confirm-rollback)" = 1 ] && grep -q X-Access-Subject "$D/config/traefik/traefik.yml"'
reset_fake
expect "rollback with no ref and no recorded merge refuses" '[ "$(rc_of go rollback --apply --confirm-rollback)" = 1 ]'

echo "evidence"
rot_ready; go rotate --apply --confirm-rotate >/dev/null || true; kill "$(cat "$APPENDER_PID_FILE")" 2>/dev/null || true
bash "$S" --print-evidence >"$T/evidence.md" 2>&1 || fail "print-evidence exited non-zero"
cat "$T/evidence.md" >>"$T/all.log"
expect "evidence block has the verify and rotate counts" 'grep -q "SATL-24 rollout evidence" "$T/evidence.md" && grep -q "request_X-Access-Subject with/without 2/" "$T/evidence.md" && grep -q "rotate passed: yes" "$T/evidence.md"'
rm -f "$T/state/state.kv"
expect "evidence with no state says so and exits non-zero" '! bash "$S" --print-evidence >/dev/null 2>&1'

echo "no synthetic log value anywhere"
expect "no canary in any record, stdout or evidence" '! grep -qF -f "$T/canaries" "$T/all.log"'
expect "no canary in any argv" '! grep -qF -f "$T/canaries" "$CALLS"'

echo
[ "$FAILS" -eq 0 ] && { echo "all passed"; exit 0; } || { echo "$FAILS failed"; exit 1; }
