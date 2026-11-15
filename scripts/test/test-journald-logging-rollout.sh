#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2015,SC2034  # single-quoted stub bodies and eval strings are intentional
# test-journald-logging-rollout.sh — run scripts/journald-logging-rollout.sh against fake binaries
# (docker, journalctl, systemctl, sudo, gh, make) in a scratch dir. Nothing real is touched: the "host"
# is a few files under $T. The fake journal prints a CANARY line for every line it counts, so any path that
# let a log line out would show in a record, stdout or an argv.
# Proves, per phase, a pass path and the fail paths: drop-in not byte-identical, vacuum detected (usage and
# oldest entry), global rate limit not effective / journald not restarted after the file, legacy docker.service
# drop-in removed without a dockerd restart, StartedAt/id unchanged after
# force-recreate (the traefik no-op lesson), pre-recreate lines missing, old container id absent,
# Suppressed > 0, plimsoll switched to journald, dry-run runs nothing, plain `make recreate` never called,
# dockerd never restarted.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/journald-logging-rollout.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
BIN="$T/bin"; F="$T/fake"; mkdir -p "$BIN" "$F" "$T/home" "$T/etc/jd" "$T/etc/dk" "$T/run"
CALLS="$T/calls.log"; : >"$CALLS"
FAILS=0
ok()   { echo "  ok    $1"; }
fail() { echo "  FAIL  $1"; FAILS=$((FAILS + 1)); }
expect() { if eval "$2"; then ok "$1"; else fail "$1"; fi; }

CANARY='JOURNAL-LINE-CANARY-7c1e55a0'
printf '%s\n' "$CANARY" >"$T/canaries"

# ── a repo stand-in: the script, the two drop-ins, a Makefile target for journald-check ──
R="$T/repo"; mkdir -p "$R/scripts" "$R/ansible/roles/server/files/journald"
cp "$SRC" "$R/scripts/"
printf '[Journal]\nSystemMaxUse=6G\nRateLimitIntervalSec=30s\nRateLimitBurst=50000\n' >"$R/ansible/roles/server/files/journald/50-construct-containers.conf"
git -C "$R" init -q -b main; git -C "$R" add -A; git -C "$R" -c user.email=a@b -c user.name=a commit -q -m x
S="$R/scripts/journald-logging-rollout.sh"
JDF=50-construct-containers.conf; DKF=50-log-rate.conf   # DKF is the LEGACY docker.service drop-in

D="$T/deploy"; mkdir -p "$D"; : >"$D/docker-compose.yml"; : >"$D/.env"
printf 'LYCEUM_TAG=1.13\n' >"$D/versions.env"

# ── fake binaries ──
cat >"$BIN/_log" <<'EOF'
echo "$(basename "$0") $*" >>"$CALLS_LOG"
EOF
mk() { printf '#!/usr/bin/env bash\n. "%s/_log"\n%s\n' "$BIN" "$2" >"$BIN/$1"; chmod +x "$BIN/$1"; }
# sudo: -v ok; install (-d and file) emulated; everything else runs the (fake) command.
mk sudo 'case "$1" in -v) exit "$(cat "$FAKE/sudo_rc" 2>/dev/null || echo 0)" ;; esac
if [ "$1" = install ]; then shift
  if [ "$1" = -d ]; then shift; mkdir -p "$@"; exit 0; fi
  args=(); while [ $# -gt 0 ]; do case "$1" in -m) shift ;; *) args+=("$1") ;; esac; shift; done
  dst="${args[-1]}"; src="${args[-2]}"; [ -d "$dst" ] && dst="$dst/$(basename "$src")"
  cp "$src" "$dst"; [ -e "$FAKE/corrupt_install" ] && echo junk >>"$dst"; exit 0; fi
exec "$@"'
# systemctl: restart journald optionally "vacuums" (shrinks usage / moves the oldest entry); restarting docker is recorded.
mk systemctl 'case "$*" in
  *"show --timestamp=unix systemd-journald"*) echo "@$(cat "$FAKE/jstart")" ;;
  *"restart systemd-journald"*) [ -e "$FAKE/vacuum_usage" ] && echo "1.0G" >"$FAKE/disk"; [ -e "$FAKE/vacuum_oldest" ] && echo 1760000000 >"$FAKE/oldest"; exit 0 ;;
  *) exit 0 ;;
esac'
# systemd-analyze cat-config: the effective journald.conf; the repo drop-in contributes its lines once installed.
mk systemd-analyze 'echo "[Journal]"; echo "# RateLimitBurst=1"; [ -n "$(cat "$FAKE/eff_burst" 2>/dev/null)" ] && echo "RateLimitBurst=$(cat "$FAKE/eff_burst")"
[ -n "$(cat "$FAKE/eff_interval" 2>/dev/null)" ] && echo "RateLimitIntervalSec=$(cat "$FAKE/eff_interval")"; exit 0'
# journalctl: counts come from files; every counted line is the CANARY.
mk journalctl 'emit() { local n="$1" i; for ((i = 0; i < n; i++)); do echo "$CANARY secret reading $i"; done; }
nm=satlink; for a in "$@"; do case "$a" in CONTAINER_NAME=*) nm="${a#CONTAINER_NAME=}" ;; esac; done
fk() { if [ "$nm" = satlink ]; then echo "$FAKE/$1"; else echo "$FAKE/$nm.$1"; fi; }
case "$*" in
  *--disk-usage*) echo "Archived and active journals take up $(cat "$FAKE/disk") in the file system." ;;
  *"-o short-unix"*) echo "$(cat "$FAKE/oldest").123456 imperial-construct kernel: $CANARY"; echo "1770000000.5 imperial-construct app: $CANARY" ;;
  *"CONTAINER_NAME="*"-o json"*) echo "{\"CONTAINER_ID\":\"$(cat "$(fk jid)")\",\"MESSAGE\":\"$CANARY\"}" ;;
  *"CONTAINER_NAME="*) emit "$(cat "$(fk count)")" ;;
  *"CONTAINER_ID="*) id="${*#*CONTAINER_ID=}"; id="${id%% *}"; emit "$(cat "$FAKE/old_$id" 2>/dev/null || echo 0)" ;;
  *"-u systemd-journald"*) for ((i = 0; i < $(cat "$FAKE/suppressed"); i++)); do echo "Suppressed 9 messages from docker.service"; done; echo "$CANARY" ;;
esac'
# make: journald-check prints the check script'"'"'s lines; force-recreate svc=satlink rotates id/StartedAt and keeps the old journal lines.
mk make 'case "$*" in
  *journald-check*) [ "$(cat "$FAKE/check_rc" 2>/dev/null || echo 0)" = 7 ] && { echo "ERROR: journalctl not found" >&2; exit 2; }
    echo "== rate-limit drops, last 24 h (expect 0) =="; echo "Suppressed notices for docker.service: $(cat "$FAKE/suppressed")"
    [ "$(cat "$FAKE/check_rc" 2>/dev/null || echo 0)" = 0 ] || exit 2; exit 0 ;;   # make reports the check'"'"'s exit 1 as 2
  *"force-recreate svc="*)
    [ -e "$FAKE/recreate_noop" ] && exit 0
    for a in "$@"; do case "$a" in svc=*) nm="${a#svc=}" ;; esac; done; fk() { if [ "$nm" = satlink ]; then echo "$FAKE/$1"; else echo "$FAKE/$nm.$1"; fi; }
    old="$(cat "$(fk jid)")"; n="$(cat "$(fk count)")"
    [ -e "$FAKE/old_absent" ] || echo "$n" >"$FAKE/old_$old"
    echo "new${nm}container000000000000000000000000000000000000000000000001" >"$(fk cid)"; cut -c1-12 "$(fk cid)" >"$(fk jid)"
    echo "2026-11-15T04:00:00.000000000Z" >"$(fk started)"
    if [ -e "$FAKE/lines_lost" ]; then echo 2 >"$(fk count)"; else echo $((n + 6)) >"$(fk count)"; fi
    echo "$nm" >>"$FAKE/recreated"
    [ -e "$FAKE/rollback_flips" ] && echo json-file >"$FAKE/drv_$nm"
    exit 0 ;;
  *"recreate svc="*) exit 0 ;;   # the plain target is a no-op on an unchanged spec: the script must never call it
esac'
mk gh 'case "$*" in
  *"pr view 297"*"-q .state"*) cat "$FAKE/gh_state" ;;
  *"pr view 297"*) cat "$FAKE/gh_pr" ;;
  *"pr view 310"*) cat "$FAKE/gh_revert" ;;
  *"contents/versions.env"*) cat "$FAKE/main_versions" ;;
  *"run list"*) cat "$FAKE/gh_run" ;;
esac'
mk docker 'case "$*" in
  *"compose"*"config --format json"*) [ "${*: -1}" = json ] && cat "$FAKE/config.json" ;;
  *"compose"*"ps -aq"*) cut -d"|" -f1 "$FAKE/containers.txt" ;;
  *"inspect -f {{index .Config.Labels"*) id="${*: -1}"; grep "^$id|" "$FAKE/containers.txt" | cut -d"|" -f2- ;;
  *"buildx imagetools inspect"*) ref="$4"; grep "^$ref " "$FAKE/registry.txt" | cut -d" " -f2 ;;
  *"image inspect"*) id="${*: -1}"; grep "^$id " "$FAKE/imgdigests.txt" | cut -d" " -f2- || true ;;
  "ps -aq") echo satlink; echo plimsoll; echo plimsoll-llm; echo traefik ;;
  *"LogConfig.Type"*) name="${*: -1}"; cat "$FAKE/drv_$name" 2>/dev/null || exit 1 ;;
  *"State.Health"*) cat "$FAKE/health" 2>/dev/null || echo healthy ;;
  *".Id}}|{{.State.StartedAt"*) nm="${*: -1}"; [ "$nm" = satlink ] && p="$FAKE/" || p="$FAKE/$nm."
    [ -e "$FAKE/no_$nm" ] && exit 1; echo "$(cat "${p}cid")|$(cat "${p}started")" ;;
  "logs --tail"*) [ -e "$FAKE/logs_broken" ] && exit 1; echo "$CANARY" ;;
  "logs"*) for i in 1 2 3; do echo "$CANARY"; done ;;
esac'

export CALLS_LOG="$CALLS" FAKE="$F" CANARY
export PATH="$BIN:$PATH" HOME="$T/home"
export DEPLOY_ROOT="$D" JOURNALD_ROLLOUT_DIR="$T/state" RUN_UNITS_DIR="$T/run"
export JOURNALD_DEST_DIR="$T/etc/jd" DOCKER_DEST_DIR="$T/etc/dk"
export JOURNALD_ROLLOUT_DEPLOY_POLL_MAX=2 JOURNALD_ROLLOUT_DEPLOY_POLL_GAP=1 JOURNALD_ROLLOUT_MERGE_POLL_MAX=2
export JOURNALD_ROLLOUT_HEALTHY_MAX=2

reset_fake() {
  rm -rf "$F"/* "$T/etc/jd/"* "$T/etc/dk/"* "$T/run/"* "$T/state"; mkdir -p "$F"; : >"$CALLS"
  echo "2.7G" >"$F/disk"; echo 1750000000 >"$F/oldest"
  echo 4000000000 >"$F/jstart"; : >"$F/eff_burst"; : >"$F/eff_interval"
  echo 0 >"$F/suppressed"
  echo OPEN >"$F/gh_state"
  echo '{"state":"MERGED","baseRefName":"main","mergeCommit":{"oid":"abcdef0123456789abcdef0123456789abcdef01"}}' >"$F/gh_pr"
  echo '[{"status":"completed","conclusion":"success","databaseId":42}]' >"$F/gh_run"
  echo MERGED >"$F/gh_revert"
  printf 'LYCEUM_TAG=1.13\n' >"$F/main_versions"
  echo '{"services":{"lyceum":{"image":"ghcr.io/einlanzerous/lyceum:1.13"},"satlink":{"image":"ghcr.io/einlanzerous/satlink:0.5.0"}}}' >"$F/config.json"
  printf 'c1|lyceum|ghcr.io/einlanzerous/lyceum:1.13|sha256:img1\nc2|satlink|ghcr.io/einlanzerous/satlink:0.5.0|sha256:img2\n' >"$F/containers.txt"
  printf 'ghcr.io/einlanzerous/lyceum:1.13 sha256:aaa\nghcr.io/einlanzerous/satlink:0.5.0 sha256:bbb\n' >"$F/registry.txt"
  printf 'sha256:img1 ghcr.io/einlanzerous/lyceum@sha256:aaa\nsha256:img2 ghcr.io/einlanzerous/satlink@sha256:bbb\n' >"$F/imgdigests.txt"
  echo json-file >"$F/drv_satlink"; echo json-file >"$F/drv_plimsoll"; echo json-file >"$F/drv_plimsoll-llm"; echo json-file >"$F/drv_traefik"
  echo "oldcontainerid00000000000000000000000000000000000000000000000000001" >"$F/cid"; echo oldcontainer >"$F/jid"
  echo "2026-11-14T01:00:00.000000000Z" >"$F/started"
  echo 40 >"$F/count"
  # wave B services (purser, cf-access-guard): same shape, files named <svc>.<what>
  local w; for w in purser cf-access-guard switchyard; do
    echo json-file >"$F/drv_$w"
    echo "old${w}container000000000000000000000000000000000000000000000000001" >"$F/$w.cid"; cut -c1-12 "$F/$w.cid" >"$F/$w.jid"
    echo "2026-11-14T01:00:00.000000000Z" >"$F/$w.started"; echo 3 >"$F/$w.count"
  done
}
# the world as it is after the merge deploy: satlink on journald, the journald drop-in installed and effective
post_merge() {
  echo journald >"$F/drv_satlink"; echo 50000 >"$F/eff_burst"; echo 30s >"$F/eff_interval"
  cp "$R/ansible/roles/server/files/journald/$JDF" "$T/etc/jd/$JDF"
}
# wave C world: switchyard on journald on top of the wave A host state
post_merge_c() { post_merge; echo journald >"$F/drv_switchyard"; }
# wave B world: purser and cf-access-guard on journald, the host drop-in installed and effective
post_merge_b() { post_merge; echo journald >"$F/drv_purser"; echo journald >"$F/drv_cf-access-guard"; }
# the world once the journald drop-in is effective (what dropin --apply needs the host to look like after the restart)
effective() { echo 50000 >"$F/eff_burst"; echo 30s >"$F/eff_interval"; }
# preflight state as the owner would have it (verify and evidence need the baseline)
baseline() { go preflight >/dev/null; }
go() { local rc=0; rm -f "$T/rec.md"; setsid -w bash "$S" --record "$T/rec.md" "$@" >"$T/out.txt" 2>&1 </dev/null || rc=$?; cat "$T/rec.md" "$T/out.txt" >>"$T/all.log" 2>/dev/null || true; return $rc; }
rc_of() { local rc=0; "$@" || rc=$?; echo "$rc"; }

echo "dry-run: only plans, changes nothing"
reset_fake
for ph in dropin merge-gate canary rollback; do
  expect "dry-run $ph exits 0" '[ "$(rc_of go $ph)" = 0 ]'
  expect "dry-run $ph says DRY-RUN" 'grep -q "DRY-RUN" "$T/rec.md"'
done
expect "dry-run invoked no sudo/make/systemctl" '! grep -Eq "^sudo|^make .*recreate|systemctl (restart|daemon-reload)" "$CALLS"'
expect "dry-run installed nothing" '[ -z "$(find "$T/etc" -type f)" ]'
expect "no phase flag is a usage error" '[ "$(rc_of go)" = 2 ]'
expect "dry-run all: preflight real, the rest plans, no sudo/make" '[ "$(rc_of go all)" = 0 ] && ! grep -Eq "^sudo|systemctl (restart|daemon-reload)|force-recreate" "$CALLS"'

echo "preflight: pass path"
reset_fake
expect "preflight exits 0" '[ "$(rc_of go preflight)" = 0 ]'
expect "preflight: nine PASS lines, no FAIL" '[ "$(grep -c "PASS" "$T/rec.md")" = 9 ] && ! grep -q "FAIL" "$T/rec.md"'
expect "preflight recorded baseline, drivers, satlink and PR state" 'grep -q "^pf_disk_bytes=" "$T/state/state.kv" && grep -q "^pf_oldest_epoch=1750000000" "$T/state/state.kv" && grep -q "^pf_ctr_jsonfile=4" "$T/state/state.kv" && grep -q "^pf_satlink_driver=json-file" "$T/state/state.kv" && grep -q "^pf_pr_state=OPEN" "$T/state/state.kv"'
expect "preflight dropins absent are recorded" 'grep -q "pf_dropin_journald=absent" "$T/state/state.kv"'
expect "preflight needs no sudo and made no mutating call" '! grep -Eq "^sudo|recreate|install|restart" "$CALLS"'
reset_fake; post_merge
expect "dropin present and identical passes preflight, legacy docker drop-in absent" '[ "$(rc_of go preflight)" = 0 ] && grep -q "pf_dropin_journald=identical" "$T/state/state.kv" && grep -q "pf_dropin_docker=absent" "$T/state/state.kv"'
reset_fake; cp "$R/ansible/roles/server/files/journald/$JDF" "$T/etc/jd/$JDF"; printf '[Service]\n' >"$T/etc/dk/$DKF"
expect "a leftover legacy docker.service drop-in is recorded, not a failure" '[ "$(rc_of go preflight)" = 0 ] && grep -q "pf_dropin_docker=present" "$T/state/state.kv"'
reset_fake; echo "[Journal]" >"$T/etc/jd/$JDF"
expect "a dropin present but NOT byte-identical FAILS preflight" '[ "$(rc_of go preflight)" = 1 ] && grep -q "FAIL.*byte-identical" "$T/rec.md"'
reset_fake; echo 7 >"$F/check_rc"
expect "journald-check that did not run (missing dependency) FAILS preflight" '[ "$(rc_of go preflight)" = 1 ]'
reset_fake; echo 1 >"$F/check_rc"
expect "a RED journald-check that ran (satlink still json-file) is only a baseline: preflight passes" '[ "$(rc_of go preflight)" = 0 ] && grep -q "^pf_check_rc=2" "$T/state/state.kv"'
reset_fake; echo sha256:zzz >"$F/x"; sed -i 's/aaa/zzz/' "$F/registry.txt"
expect "digest drift is listed, dry-run does not wait" '[ "$(rc_of go preflight)" = 0 ] && grep -q "PENDING:.*lyceum(digest)" "$T/rec.md"'
expect "--apply with no terminal PAUSES on drift (exit 3)" '[ "$(rc_of go preflight --apply)" = 3 ] && grep -q "PAUSED" "$T/rec.md"'
expect "--confirm-apply proceeds past the drift pause" '[ "$(rc_of go preflight --apply --confirm-apply)" = 0 ]'

echo "dropin"
reset_fake; effective
expect "dropin --apply passes" '[ "$(rc_of go dropin --apply)" = 0 ] && ! grep -q FAIL "$T/rec.md"'
expect "dropin: the installed file equals the repo copy; no docker.service drop-in is installed" 'cmp -s "$R/ansible/roles/server/files/journald/$JDF" "$T/etc/jd/$JDF" && [ ! -e "$T/etc/dk/$DKF" ]'
expect "dropin: sudo -v first, then install -d, one install, restart journald (no legacy file: no daemon-reload)" \
  '[ "$(grep -n "" "$CALLS" | grep -E "sudo -v|sudo install -d|sudo install -m|systemctl daemon-reload|systemctl restart systemd-journald" | sed "s/^[0-9]*://" | head -1)" = "sudo -v" ] && [ "$(grep -c "^sudo install -m 0644" "$CALLS")" = 1 ] && grep -q "^sudo install -d" "$CALLS" && ! grep -q "^systemctl daemon-reload" "$CALLS" && grep -q "^systemctl restart systemd-journald" "$CALLS"'
expect "dropin records the effective burst/interval and that journald restarted after the file" 'grep -q "^dropin_burst=50000" "$T/state/state.kv" && grep -q "^dropin_interval=30s" "$T/state/state.kv" && grep -q "^ratelimit_ok=1" "$T/state/state.kv" && grep -q "PASS.*HOST-WIDE rate limit" "$T/rec.md"'
expect "dropin never restarts dockerd or a container" '! grep -Eq "restart docker|docker (restart|stop|kill)|compose (restart|up)|force-recreate" "$CALLS"'
: >"$CALLS"
expect "dropin rerun is idempotent (install skipped)" '[ "$(rc_of go dropin --apply)" = 0 ] && grep -q "install skipped" "$T/rec.md" && ! grep -q "^sudo install -m" "$CALLS"'
reset_fake; effective; printf '[Service]\n' >"$T/etc/dk/$DKF"
expect "the legacy docker.service drop-in is removed, with daemon-reload only; dockerd untouched" \
  '[ "$(rc_of go dropin --apply)" = 0 ] && [ ! -e "$T/etc/dk/$DKF" ] && grep -q "^sudo rm -f .*$DKF" "$CALLS" && grep -q "^systemctl daemon-reload" "$CALLS" && ! grep -Eq "restart docker|docker (restart|stop|kill)" "$CALLS"'
reset_fake; effective; touch "$F/corrupt_install"
expect "an installed copy that differs FAILS byte-for-byte" '[ "$(rc_of go dropin --apply)" = 1 ] && grep -q "FAIL.*byte for byte" "$T/rec.md"'
reset_fake; effective; touch "$F/vacuum_usage"
expect "usage shrinking after the restart (a vacuum) FAILS" '[ "$(rc_of go dropin --apply)" = 1 ] && grep -q "FAIL.*nothing vacuumed" "$T/rec.md"'
reset_fake; effective; touch "$F/vacuum_oldest"
expect "the oldest entry moving (a vacuum) FAILS" '[ "$(rc_of go dropin --apply)" = 1 ] && grep -q "oldest entry moved" "$T/rec.md"'
reset_fake
expect "a global limit that is not in the effective config FAILS (hard, not a later blocker)" '[ "$(rc_of go dropin --apply)" = 1 ] && grep -q "FAIL.*HOST-WIDE rate limit" "$T/rec.md" && grep -q "effective limit is not 50000 per 30s" "$T/rec.md" && ! grep -q "^ratelimit_ok" "$T/state/state.kv"'
reset_fake; echo 10000 >"$F/eff_burst"; echo 30s >"$F/eff_interval"
expect "an effective burst of 10000 FAILS" '[ "$(rc_of go dropin --apply)" = 1 ] && grep -q "FAIL.*HOST-WIDE" "$T/rec.md"'
reset_fake; echo 50000 >"$F/eff_burst"; echo 10s >"$F/eff_interval"
expect "a wrong interval FAILS" '[ "$(rc_of go dropin --apply)" = 1 ]'
reset_fake; effective; echo 1 >"$F/jstart"
expect "journald started BEFORE the file was written (not restarted) FAILS" '[ "$(rc_of go dropin --apply)" = 1 ] && grep -q "started BEFORE the file was written" "$T/rec.md"'
reset_fake; effective; echo >"$F/jstart"
expect "an unreadable journald start time FAILS" '[ "$(rc_of go dropin --apply)" = 1 ]'
reset_fake; effective; echo 1 >"$F/sudo_rc"
expect "no sudo (wrong password) stops before anything is installed" '[ "$(rc_of go dropin --apply)" = 1 ] && [ -z "$(find "$T/etc" -type f)" ]'

echo "merge-gate"
reset_fake; post_merge
expect "merge-gate passes: merged, deploy green, satlink journald, plimsoll json-file" '[ "$(rc_of go merge-gate --apply --confirm-apply)" = 0 ] && ! grep -q FAIL "$T/rec.md" && grep -q "^mg_satlink_driver=journald" "$T/state/state.kv"'
expect "merge-gate with no terminal pauses for the owner (exit 3)" '[ "$(rc_of go merge-gate --apply)" = 3 ]'
expect "merge-gate never merges" '! grep -q "pr merge" "$CALLS"'
reset_fake; post_merge; echo journald >"$F/drv_plimsoll"
expect "plimsoll switched to journald FAILS" '[ "$(rc_of go merge-gate --apply --confirm-apply)" = 1 ] && grep -q "FAIL.*still json-file" "$T/rec.md"'
reset_fake; post_merge; echo journald >"$F/drv_plimsoll-llm"
expect "plimsoll-llm switched to journald FAILS" '[ "$(rc_of go merge-gate --apply --confirm-apply)" = 1 ]'
reset_fake; post_merge; echo json-file >"$F/drv_satlink"
expect "satlink still json-file after the deploy FAILS" '[ "$(rc_of go merge-gate --apply --confirm-apply)" = 1 ]'
reset_fake; post_merge; echo '[{"status":"completed","conclusion":"failure","databaseId":42}]' >"$F/gh_run"
expect "a red deploy run FAILS" '[ "$(rc_of go merge-gate --apply --confirm-apply)" = 1 ] && grep -q "FAIL.*finished green" "$T/rec.md"'
reset_fake; post_merge; echo '[{"status":"in_progress","conclusion":"","databaseId":42}]' >"$F/gh_run"
expect "a deploy that never finishes FAILS after the bounded poll" '[ "$(rc_of go merge-gate --apply --confirm-apply)" = 1 ] && grep -q "did not finish" "$T/rec.md"'
reset_fake; post_merge; echo '{"state":"OPEN","baseRefName":"main","mergeCommit":null}' >"$F/gh_pr"
expect "an unmerged PR FAILS after the bounded poll" '[ "$(rc_of go merge-gate --apply --confirm-apply)" = 1 ]'

echo "canary"
reset_fake; post_merge
expect "canary passes" '[ "$(rc_of go canary --apply)" = 0 ] && ! grep -q FAIL "$T/rec.md"'
expect "canary recorded BEFORE 40, AFTER 46, old container lines 40" 'grep -q "^canary_before=40" "$T/state/state.kv" && grep -q "^canary_after=46" "$T/state/state.kv" && grep -q "^canary_old_lines=40" "$T/state/state.kv" && grep -q "^canary_old_id=oldcontainer" "$T/state/state.kv"'
expect "canary used force-recreate svc=satlink from the deploy root, never plain recreate" 'grep -q "^make -C $D force-recreate svc=satlink" "$CALLS" && ! grep -Eq "^make -C $D recreate" "$CALLS"'
expect "canary never touched dockerd or another container" '! grep -Eq "restart docker|docker (restart|stop|kill)|svc=(plimsoll|traefik)" "$CALLS"'
reset_fake; post_merge; touch "$F/recreate_noop"
expect "a make that exits 0 but leaves the container running FAILS (the traefik no-op lesson)" '[ "$(rc_of go canary --apply)" = 1 ] && grep -q "FAIL.*really restarted" "$T/rec.md"'
reset_fake; post_merge; touch "$F/lines_lost"
expect "pre-recreate lines missing (AFTER < BEFORE) FAILS" '[ "$(rc_of go canary --apply)" = 1 ] && grep -q "FAIL.*pre-recreate lines survived" "$T/rec.md"'
reset_fake; post_merge; touch "$F/old_absent"
expect "no lines for the old container id FAILS" '[ "$(rc_of go canary --apply)" = 1 ] && grep -q "FAIL.*old container id" "$T/rec.md"'
reset_fake; post_merge; echo 3 >"$F/suppressed"
expect "Suppressed > 0 in the window FAILS" '[ "$(rc_of go canary --apply)" = 1 ] && grep -q "FAIL.*Suppressed" "$T/rec.md"'
reset_fake; post_merge; touch "$F/logs_broken"
expect "docker logs failing FAILS" '[ "$(rc_of go canary --apply)" = 1 ] && grep -q "FAIL.*docker logs" "$T/rec.md"'
reset_fake; post_merge; echo unhealthy >"$F/health"
expect "satlink not healthy after the recreate FAILS after the bound" '[ "$(rc_of go canary --apply)" = 1 ] && grep -q "FAIL.*healthy" "$T/rec.md"'
reset_fake; post_merge; echo json-file >"$F/drv_satlink"
expect "canary refuses while satlink is not on journald (and recreates nothing)" '[ "$(rc_of go canary --apply)" = 1 ] && ! grep -q "force-recreate" "$CALLS"'
reset_fake; post_merge; echo 0 >"$F/count"
expect "no journal lines before the recreate FAILS (nothing to prove)" '[ "$(rc_of go canary --apply)" = 1 ] && ! grep -q "force-recreate" "$CALLS"'
reset_fake; post_merge; echo otherid00000 >"$F/jid"
expect "a journal CONTAINER_ID that is not the running container FAILS" '[ "$(rc_of go canary --apply)" = 1 ] && ! grep -q "force-recreate" "$CALLS"'


echo "wave B: --svc purser,cf-access-guard"
W=purser,cf-access-guard
reset_fake; post_merge_b
expect "--svc with a service outside the waves is a usage error (plimsoll, postgres, unknown)" '[ "$(rc_of go canary --svc plimsoll)" = 2 ] && [ "$(rc_of go canary --svc purser,postgres)" = 2 ] && [ "$(rc_of go canary --svc nonesuch)" = 2 ] && [ "$(rc_of go canary --svc plimsoll-llm)" = 2 ]'
expect "dry-run canary for the wave prints each outage and recreates nothing" '[ "$(rc_of go canary --svc $W)" = 0 ] && grep -q "DRY-RUN" "$T/rec.md" && grep -q "outage of the purser recreate" "$T/rec.md" && grep -q "outage of the cf-access-guard recreate: every tunneled host.*500s" "$T/rec.md" && ! grep -q force-recreate "$CALLS"'
expect "the wave canary pauses before each recreate (outage named) and, with no terminal, stops before the first" '[ "$(rc_of go canary --svc $W --apply)" = 3 ] && grep -q "PAUSE: next canary: force-recreate purser" "$T/rec.md" && ! grep -q force-recreate "$CALLS"'
expect "the wave canary passes: both force-recreated, in order, from the deploy root, nothing else touched" '[ "$(rc_of go canary --svc $W --apply --yes)" = 0 ] && ! grep -q FAIL "$T/rec.md" && [ "$(tr "\n" " " <"$F/recreated")" = "purser cf-access-guard " ] && grep -q "^make -C $D force-recreate svc=purser" "$CALLS" && grep -q "^make -C $D force-recreate svc=cf-access-guard" "$CALLS" && ! grep -Eq "^make -C $D recreate|svc=(satlink|plimsoll|traefik|switchyard|postgres)|restart docker" "$CALLS"'
expect "per-service canary keys are recorded; satlink keys are not touched" 'grep -q "^canary_purser_before=3" "$T/state/state.kv" && grep -q "^canary_purser_after=9" "$T/state/state.kv" && grep -q "^canary_purser_old_lines=3" "$T/state/state.kv" && grep -q "^canary_cf_access_guard_old_lines=3" "$T/state/state.kv" && grep -q "^canary_cf_access_guard_ok=1" "$T/state/state.kv" && ! grep -q "^canary_before=" "$T/state/state.kv"'
expect "the wave evidence names each service" 'bash "$S" --print-evidence --svc $W >"$T/evidence.md" 2>&1 && grep -q "purser: BEFORE 3 lines, AFTER 9 lines, old container" "$T/evidence.md" && grep -q "cf-access-guard: BEFORE 3 lines" "$T/evidence.md"; cat "$T/evidence.md" >>"$T/all.log"'
reset_fake; post_merge_b; echo 0 >"$F/cf-access-guard.count"
expect "a quiet service with no journal lines fails BEFORE it is recreated; the first service was already done" '[ "$(rc_of go canary --svc $W --apply --yes)" = 1 ] && grep -q "nothing to prove" "$T/rec.md" && [ "$(tr "\n" " " <"$F/recreated")" = "purser " ]'
reset_fake; post_merge_b; echo json-file >"$F/drv_cf-access-guard"
expect "a wave service still on json-file refuses to canary" '[ "$(rc_of go canary --svc $W --apply --yes)" = 1 ] && grep -q "FAIL.*cf-access-guard is on the journald driver" "$T/rec.md"'
reset_fake; post_merge_b; touch "$F/recreate_noop"
expect "a no-op make for a wave service FAILS (the traefik lesson holds per service)" '[ "$(rc_of go canary --svc $W --apply --yes)" = 1 ] && grep -q "FAIL.*purser really restarted" "$T/rec.md"'
reset_fake; post_merge_b; echo 3 >"$F/suppressed"
expect "Suppressed > 0 FAILS a wave service too" '[ "$(rc_of go canary --svc $W --apply --yes)" = 1 ] && grep -q "FAIL.*Suppressed" "$T/rec.md"'
reset_fake; post_merge_b
expect "merge-gate for the wave: both journald, plimsoll json-file" '[ "$(rc_of go merge-gate --svc $W --apply --confirm-apply)" = 0 ] && grep -q "^mg_purser_driver=journald" "$T/state/state.kv" && grep -q "^mg_cf_access_guard_driver=journald" "$T/state/state.kv"'
reset_fake; post_merge_b; echo json-file >"$F/drv_purser"
expect "merge-gate fails when one wave service is not on journald" '[ "$(rc_of go merge-gate --svc $W --apply --confirm-apply)" = 1 ]'
reset_fake; baseline; post_merge_b
expect "verify for the wave passes" '[ "$(rc_of go verify --svc $W --confirm-dozzle)" = 0 ] && grep -q "^v_purser_driver=journald" "$T/state/state.kv"'
reset_fake; baseline; post_merge_b; echo json-file >"$F/drv_cf-access-guard"
expect "verify fails when a wave service is on json-file" '[ "$(rc_of go verify --svc $W)" = 1 ]'
reset_fake; post_merge_b; touch "$F/rollback_flips"; echo '{"services":{"purser":{},"cf-access-guard":{}}}' >"$F/config.json"
expect "wave rollback: each recreated, json-file, journal still queryable" '[ "$(rc_of go rollback --svc $W --apply --confirm-rollback)" = 0 ] && [ "$(tr "\n" " " <"$F/recreated")" = "purser cf-access-guard " ] && grep -q "^rb_purser_journal_lines=9" "$T/state/state.kv"'

echo "wave C: --svc switchyard"
WC=switchyard
reset_fake; post_merge_c
expect "dry-run canary names the switchyard outage (API, MCP, webhook) and recreates nothing" '[ "$(rc_of go canary --svc $WC)" = 0 ] && grep -q "outage of the switchyard recreate: the Switchyard API and the MCP server" "$T/rec.md" && ! grep -q force-recreate "$CALLS"'
expect "the wave C canary passes: only switchyard force-recreated, from the deploy root" '[ "$(rc_of go canary --svc $WC --apply --yes)" = 0 ] && ! grep -q FAIL "$T/rec.md" && [ "$(tr "\n" " " <"$F/recreated")" = "switchyard " ] && grep -q "^make -C $D force-recreate svc=switchyard" "$CALLS" && ! grep -Eq "^make -C $D recreate|svc=(satlink|purser|cf-access-guard|interlock-worker|postgres|traefik|plimsoll)|restart docker" "$CALLS"'
expect "switchyard canary keys recorded and the wave evidence names it" 'grep -q "^canary_switchyard_before=3" "$T/state/state.kv" && bash "$S" --print-evidence --svc $WC >"$T/evidence.md" 2>&1 && grep -q "switchyard: BEFORE 3 lines" "$T/evidence.md"; cat "$T/evidence.md" >>"$T/all.log"'
reset_fake; post_merge_c; echo 0 >"$F/switchyard.count"
expect "switchyard with no journal lines fails BEFORE it is recreated (BEFORE>0 precondition)" '[ "$(rc_of go canary --svc $WC --apply --yes)" = 1 ] && grep -q "nothing to prove" "$T/rec.md" && [ ! -s "$F/recreated" ]'
reset_fake; post_merge_c; echo 3 >"$F/suppressed"
expect "Suppressed > 0 FAILS the switchyard canary (the 24 h rate-limit check)" '[ "$(rc_of go canary --svc $WC --apply --yes)" = 1 ] && grep -q "FAIL.*Suppressed" "$T/rec.md"'
reset_fake; baseline; post_merge_c; echo json-file >"$F/drv_switchyard"
expect "merge-gate fails while switchyard is still json-file" '[ "$(rc_of go merge-gate --svc $WC --apply --confirm-apply)" = 1 ]'
reset_fake; baseline; post_merge_c
expect "verify for wave C passes" '[ "$(rc_of go verify --svc $WC --confirm-dozzle)" = 0 ] && grep -q "^v_switchyard_driver=journald" "$T/state/state.kv"'

echo "verify"
reset_fake; baseline; post_merge
expect "verify passes; Dozzle is PAUSE (pending), never an auto-PASS" '[ "$(rc_of go verify)" = 0 ] && grep -q "PAUSE: Dozzle" "$T/rec.md" && ! grep -q "PASS.*Dozzle" "$T/rec.md" && grep -q "^dozzle=pending" "$T/state/state.kv"'
expect "verify with --confirm-dozzle records owner-confirmed" '[ "$(rc_of go verify --confirm-dozzle)" = 0 ] && grep -q "PASS (owner-confirmed.*Dozzle" "$T/rec.md" && grep -q "^dozzle=confirmed" "$T/state/state.kv"'
expect "verify made no mutating call" '! grep -Eq "^sudo|recreate|install|restart" "$CALLS"'
reset_fake; baseline; post_merge; echo 1 >"$F/check_rc"
expect "journald-check red FAILS verify" '[ "$(rc_of go verify)" = 1 ]'
reset_fake; baseline; post_merge; echo 1.0G >"$F/disk"
expect "usage reduced since the baseline FAILS verify" '[ "$(rc_of go verify)" = 1 ] && grep -q "FAIL.*nothing vacuumed" "$T/rec.md"'
reset_fake; baseline; post_merge; echo 1760000000 >"$F/oldest"
expect "oldest entry moved since the baseline FAILS verify" '[ "$(rc_of go verify)" = 1 ]'
reset_fake; baseline; post_merge; echo journald >"$F/drv_plimsoll"
expect "plimsoll on journald FAILS verify" '[ "$(rc_of go verify)" = 1 ] && grep -q "FAIL.*driver per service" "$T/rec.md"'
reset_fake; baseline; post_merge; echo 4 >"$F/suppressed"
expect "Suppressed above the baseline FAILS verify" '[ "$(rc_of go verify)" = 1 ]'
reset_fake; post_merge
expect "verify without a preflight baseline refuses" '[ "$(rc_of go verify)" = 1 ] && grep -q "run the preflight phase first" "$T/rec.md"'

echo "rollback"
reset_fake; post_merge; echo '{"services":{"satlink":{"logging":{"driver":"json-file"}}}}' >"$F/config.json"; touch "$F/rollback_flips"
expect "rollback with no terminal and no confirmation refuses" '[ "$(rc_of go rollback --apply)" = 1 ] && grep -q "needs a terminal" "$T/rec.md"'
expect "rollback: revert deployed, force-recreate, json-file, history still queryable; drop-ins left" \
  '[ "$(rc_of go rollback --apply --confirm-rollback --revert-pr 310)" = 0 ] && grep -q "^make -C $D force-recreate svc=satlink" "$CALLS" && grep -q "^rb_journal_lines=46" "$T/state/state.kv" && grep -q "left in place" "$T/rec.md" && [ -e "$T/etc/jd/$JDF" ] && ! grep -q "^sudo rm" "$CALLS"'
reset_fake; post_merge; touch "$F/rollback_flips"; echo '{"services":{"satlink":{"logging":{"driver":"journald"}}}}' >"$F/config.json"
expect "rollback before the revert is deployed (compose still journald) FAILS and recreates nothing" '[ "$(rc_of go rollback --apply --confirm-rollback)" = 1 ] && ! grep -q "force-recreate" "$CALLS"'
reset_fake; post_merge; echo '{"services":{"satlink":{"logging":{"driver":"json-file"}}}}' >"$F/config.json"; echo OPEN >"$F/gh_revert"
expect "an unmerged revert PR FAILS" '[ "$(rc_of go rollback --apply --confirm-rollback --revert-pr 310)" = 1 ]'
reset_fake; post_merge; touch "$F/rollback_flips"; echo '{"services":{"satlink":{"logging":{"driver":"json-file"}}}}' >"$F/config.json"
expect "--remove-dropins removes both files, daemon-reloads, restarts journald only; nothing else" \
  '[ "$(rc_of go rollback --apply --confirm-rollback --remove-dropins)" = 0 ] && [ ! -e "$T/etc/jd/$JDF" ] && [ ! -e "$T/etc/dk/$DKF" ] && grep -q "^systemctl restart systemd-journald" "$CALLS" && ! grep -Eq "restart docker" "$CALLS"'

echo "evidence"
reset_fake; post_merge; baseline; go dropin --apply >/dev/null || true; go merge-gate --apply --confirm-apply >/dev/null || true; go canary --apply >/dev/null || true; go verify --confirm-dozzle >/dev/null || true
bash "$S" --print-evidence >"$T/evidence.md" 2>&1 || fail "print-evidence exited non-zero"
cat "$T/evidence.md" >>"$T/all.log"; [ -n "${DBG:-}" ] && cat "$T/evidence.md"
expect "evidence block has canary counts, drivers, vacuum baseline and Dozzle" 'grep -q "SATL-25 / SATL-71" "$T/evidence.md" && grep -q "BEFORE 40 lines, AFTER 46 lines" "$T/evidence.md" && grep -q "old container oldcontainer lines 40" "$T/evidence.md" && grep -q "Dozzle (live tail + history): confirmed" "$T/evidence.md" && grep -q "canary passed: yes" "$T/evidence.md"'
rm -f "$T/state/state.kv"
expect "evidence with no state says so and exits non-zero" '! bash "$S" --print-evidence >/dev/null 2>&1'

echo "stale state"
rm -rf "$T/state"; reset_fake; baseline; post_merge
go verify --confirm-dozzle >/dev/null || true
expect "verify passes first: the evidence says verify passed" 'bash "$S" --print-evidence >"$T/evidence.md" 2>&1; cat "$T/evidence.md" >>"$T/all.log"; grep -q "verify passed: yes" "$T/evidence.md" && grep -q "Dozzle.*confirmed" "$T/evidence.md"'
echo 1 >"$F/check_rc"
go verify >/dev/null || true
expect "a later failing verify in the same state dir no longer reports passed or a stale Dozzle confirmation" 'bash "$S" --print-evidence >"$T/evidence.md" 2>&1; cat "$T/evidence.md" >>"$T/all.log"; grep -q "verify passed: no" "$T/evidence.md" && ! grep -q "verify passed: yes" "$T/evidence.md" && ! grep -q "^dozzle=confirmed" "$T/state/state.kv" && ! grep -q "^verify_ok" "$T/state/state.kv"'
rm -rf "$T/state"; reset_fake; baseline; post_merge
go merge-gate --apply --confirm-apply >/dev/null || true
expect "merge-gate records merge_sha and deploy_conclusion" 'grep -q "^merge_sha=" "$T/state/state.kv" && grep -q "^deploy_conclusion=success" "$T/state/state.kv"'
printf 'merge_gate_ok=1\nmerge_sha=oldsha\ndeploy_conclusion=failure\n' >>"$T/state/state.kv"
go merge-gate --apply >/dev/null 2>&1 || true
expect "a stale merge_sha, deploy_conclusion and merge_gate_ok are cleared when merge-gate starts (before it pauses)" '! grep -q "^merge_sha=oldsha" "$T/state/state.kv" && ! grep -q "^deploy_conclusion=failure" "$T/state/state.kv" && ! grep -q "^merge_gate_ok" "$T/state/state.kv"'

echo "per-wave state directories"
rm -rf "$T/home/.cache"; reset_fake; post_merge_b
( unset JOURNALD_ROLLOUT_DIR; go preflight >/dev/null || true; go preflight --svc $W >/dev/null || true; go verify --confirm-dozzle >/dev/null || true; go verify --svc $W --confirm-dozzle >/dev/null || true )
D_A="$T/home/.cache/journald-logging-rollout"; D_B="$T/home/.cache/journald-logging-rollout-purser-cf-access-guard"
expect "satlink-only keeps the original state path; another wave gets its own" '[ -s "$D_A/state.kv" ] && [ -s "$D_B/state.kv" ]'
expect "wave A state has no wave B keys and wave B has no wave A keys" '! grep -q "^v_purser_driver" "$D_A/state.kv" && grep -q "^v_purser_driver" "$D_B/state.kv" && grep -q "^v_satlink_driver" "$D_A/state.kv"'
( unset JOURNALD_ROLLOUT_DIR; rm -f "$D_B/state.kv"; bash "$S" --print-evidence --svc $W >"$T/evidence.md" 2>&1 ) && fail "wave B evidence read wave A's state" || ok "wave B evidence with no wave B state does not fall back to wave A's"
cat "$T/evidence.md" >>"$T/all.log"

echo "no log value anywhere"
expect "no canary in any record, stdout or evidence" '! grep -qF -f "$T/canaries" "$T/all.log"'
expect "no canary in any argv" '! grep -qF -f "$T/canaries" "$CALLS"'
expect "the all.log is not empty (the check above looked at something)" '[ -s "$T/all.log" ]'

echo
[ "$FAILS" -eq 0 ] && { echo "all passed"; exit 0; } || { echo "$FAILS failed"; exit 1; }
