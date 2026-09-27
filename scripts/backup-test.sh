#!/usr/bin/env bash
# backup-test.sh — fault-injection suite for scripts/backup-nightly.sh (SERV-43).
#
# Runs the REAL script against a mock docker/tailscale (scripts/test/mock-bin/)
# and scratch state/data directories — never against a real container, real
# Postgres, or the real append-only receiver. The one thing this suite
# deliberately does NOT cover is the append-only proof against a real probe
# repository: that runs rarely, by hand, against the live desktop receiver
# (SERV-215), precisely so a suite run this often never touches real state on
# someone else's host.
#
# Usage: ./backup-test.sh   (or: make backup-test)
#
# `check && ok "..." || bad "..."` is deliberate throughout: ok()/bad() only
# printf and increment a counter, so they cannot fail — the one case SC2015's
# "not if-then-else" warning doesn't apply to.
# shellcheck disable=SC2015
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_SCRIPT="$SCRIPT_DIR/backup-nightly.sh"
MOCK_BIN="$SCRIPT_DIR/test/mock-bin"

PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); printf '  \033[32mok\033[0m   %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$*"; }

assert_status() { # <label> <expected> <actual>
  if [ "$3" -eq "$2" ]; then ok "$1 (exit $3)"; else bad "$1 (expected exit $2, got $3)"; fi
}
assert_eq() { [ "$2" = "$3" ] && ok "$1" || bad "$1 (expected '$3', got '$2')"; }
assert_ne() { [ "$2" != "$3" ] && ok "$1" || bad "$1 (expected something other than '$3')"; }
assert_dir_empty() { [ -z "$(ls -A "$2" 2>/dev/null)" ] && ok "$1" || bad "$1 (not empty: $2)"; }

SCRATCH=""
DATA_DIR="" ; STATE_DIR="" ; CONF="" ; ENVFILE=""

scenario_setup() {
  SCRATCH="$(mktemp -d)"
  DATA_DIR="$SCRATCH/data"
  STATE_DIR="$SCRATCH/state"
  CONF="$SCRATCH/backup.conf"
  ENVFILE="$SCRATCH/backup.env"
  mkdir -p "$DATA_DIR" "$STATE_DIR"
  echo "RESTIC_PASSWORD_HUB=testpw" >"$ENVFILE"
  # backup-nightly.sh now refuses to source anything but a 0600 file (SERV-214
  # — signet render does not enforce this itself, measured directly).
  chmod 0600 "$ENVFILE"
}

scenario_teardown() { rm -rf "$SCRATCH"; }

# write_conf [destinations-array-literal]
# $DATA_DIR sits under /tmp, which shares a device with /  — /data is a
# genuinely separate device on this box, so pointing the mock docker root at
# it (the default) makes the preflight's device-separation check pass for
# free, without fabricating a second filesystem.
write_conf() {
  cat >"$CONF" <<CONF
RESTIC_IMAGE="restic/restic:0.18.1@sha256:39d9072fb5651c80d75c7a811612eb60b4c06b32ffe87c2e9f3c7222e1797e76"
BACKUP_CLUSTERS=("mockpg:svc")
BACKUP_EXCLUDE_PATTERNS=("swy*" "*_test")
BACKUP_MUST_DUMP_SVC=(alpha beta gamma)
BACKUP_RETENTION_DAILY=14
BACKUP_RETENTION_WEEKLY=8
BACKUP_DESTINATIONS=(${1:-})
BACKUP_CONSECUTIVE_MISS_THRESHOLD=3
BACKUP_PG_DUMP_TIMEOUT_SEC=30
BACKUP_RESTIC_TIMEOUT_SEC=2
BACKUP_PREFLIGHT_MAX_SEC=5
CONF
}

# write_conf_two_clusters [destinations-array-literal] — for the two findings
# that a single-cluster conf structurally cannot exercise (PR review findings
# #2 and #3, which the original T13/T14/T15 all used one cluster for).
write_conf_two_clusters() {
  cat >"$CONF" <<CONF
RESTIC_IMAGE="restic/restic:0.18.1@sha256:39d9072fb5651c80d75c7a811612eb60b4c06b32ffe87c2e9f3c7222e1797e76"
BACKUP_CLUSTERS=("mockpg1:alpha" "mockpg2:beta")
BACKUP_EXCLUDE_PATTERNS=("swy*" "*_test")
BACKUP_MUST_DUMP_ALPHA=(a1 a2)
BACKUP_MUST_DUMP_BETA=(b1 b2)
BACKUP_RETENTION_DAILY=14
BACKUP_RETENTION_WEEKLY=8
BACKUP_DESTINATIONS=(${1:-})
BACKUP_CONSECUTIVE_MISS_THRESHOLD=3
BACKUP_PG_DUMP_TIMEOUT_SEC=30
BACKUP_RESTIC_TIMEOUT_SEC=2
BACKUP_PREFLIGHT_MAX_SEC=5
CONF
}

# run_backup [cmd] — real MOCK_* env vars are whatever the caller already
# exported; this only supplies the paths and the mock PATH.
run_backup() {
  local rc=0
  PATH="$MOCK_BIN:$PATH" \
    MOCK_DOCKER_ROOT="${MOCK_DOCKER_ROOT:-/data}" \
    MOCK_DB_LIST="${MOCK_DB_LIST-}" \
    BACKUP_CONF="$CONF" BACKUP_ENV_FILE="$ENVFILE" \
    BACKUP_STATE_DIR="$STATE_DIR" BACKUP_DATA_DIR="$DATA_DIR" \
    "$BACKUP_SCRIPT" "${1:-run}" >"$SCRATCH/log" 2>&1 || rc=$?
  return $rc
}

state_get() { jq -r "$1" "$STATE_DIR/state.json"; }

# write_dest_creds — appends the mock "desk" destination's credentials to the
# scenario's backup.env in one shot (SC2129: one redirect, not three).
write_dest_creds() {
  cat >>"$ENVFILE" <<'ENV'
RESTIC_PASSWORD_DESK=destpw
REST_USER_DESK=u
REST_PASSWORD_DESK=p
ENV
}

# ─── T1: happy path — floor covered, an extra un-listed db, one excluded ────
head_ "T1: happy path (floor + a new db + an excluded scratch db)"
scenario_setup
write_conf
export MOCK_DB_LIST=$'alpha\nbeta\ngamma\nnewservice\nswy_scratch\ncentrifuge_test'
rc=0; run_backup || rc=$?
assert_status "run succeeds" 0 "$rc"
# Staging is cleaned via an EXIT trap before run_backup returns — verified
# separately below — so "was it dumped" is read from the run's own log, the
# same record a real deploy would have via journald, not from a leftover file.
for db in alpha beta gamma newservice; do
  grep -q "dumped '$db'" "$SCRATCH/log" && ok "dumped '$db'" || bad "dumped '$db'"
done
assert_dir_empty "staging cleaned after a clean run" "$DATA_DIR/staging"
for db in swy_scratch centrifuge_test; do
  grep -q "dumped '$db'" "$SCRATCH/log" && bad "'$db' unexpectedly dumped (should be excluded)" || ok "'$db' not dumped (excluded)"
done
grep -q "excluded 'swy_scratch'" "$SCRATCH/log" && ok "excluded name logged with size" || bad "excluded name logged with size"
unset MOCK_DB_LIST
scenario_teardown

# ─── T2: must-dump floor not covered ────────────────────────────────────────
head_ "T2: must-dump floor missing a database"
scenario_setup
write_conf
export MOCK_DB_LIST=$'alpha\nbeta'   # gamma is gone
rc=0; run_backup || rc=$?
assert_status "run fails" 1 "$rc"
grep -q "floor not covered: gamma" "$SCRATCH/log" && ok "missing floor db named" || bad "missing floor db named"
unset MOCK_DB_LIST
scenario_teardown

# ─── T3: one pg_dump fails; the rest still get snapshotted ──────────────────
head_ "T3: one database's pg_dump fails"
scenario_setup
write_conf
export MOCK_DB_LIST=$'alpha\nbeta\ngamma'
export MOCK_FAIL_DB=beta
rc=0; run_backup || rc=$?
assert_status "run fails overall" 1 "$rc"
grep -q "FAILED to dump 'beta'" "$SCRATCH/log" && ok "failed db named" || bad "failed db named"
unset MOCK_DB_LIST MOCK_FAIL_DB
scenario_teardown

# ─── T4: an empty dump file counts as a failure, same as a hard failure ────
head_ "T4: pg_dump exits 0 but produces an empty file"
scenario_setup
write_conf
export MOCK_DB_LIST=$'alpha\nbeta\ngamma'
export MOCK_EMPTY_DB=gamma
rc=0; run_backup || rc=$?
assert_status "run fails overall" 1 "$rc"
grep -q "FAILED to dump 'gamma'" "$SCRATCH/log" && ok "empty dump treated as failure" || bad "empty dump treated as failure"
unset MOCK_DB_LIST MOCK_EMPTY_DB
scenario_teardown

# ─── T5: kill -9 mid-run leaves no staging leftovers for the next run ──────
head_ "T5: kill -9 mid-run, then a fresh run"
scenario_setup
write_conf
export MOCK_DB_LIST=$'alpha\nbeta\ngamma'
PATH="$MOCK_BIN:$PATH" MOCK_DOCKER_ROOT=/data MOCK_DB_LIST="$MOCK_DB_LIST" \
  BACKUP_CONF="$CONF" BACKUP_ENV_FILE="$ENVFILE" \
  BACKUP_STATE_DIR="$STATE_DIR" BACKUP_DATA_DIR="$DATA_DIR" \
  "$BACKUP_SCRIPT" run >"$SCRATCH/log.killed" 2>&1 &
bg_pid=$!
sleep 1
kill -9 "$bg_pid" 2>/dev/null || true
wait "$bg_pid" 2>/dev/null || true
[ -d "$DATA_DIR/staging" ] && ok "killed run left staging behind, as expected (trap can't run on SIGKILL)" \
  || ok "killed run's staging already gone (fast enough to finish before the kill landed)"
rc=0; run_backup || rc=$?
assert_status "fresh run after a kill still succeeds" 0 "$rc"
assert_dir_empty "staging clean after the fresh run" "$DATA_DIR/staging"
unset MOCK_DB_LIST
scenario_teardown

# ─── T6: hub and Docker root on the same device — refused ──────────────────
head_ "T6: hub on the same block device as Docker's root"
scenario_setup
write_conf
export MOCK_DB_LIST=$'alpha\nbeta\ngamma'
export MOCK_DOCKER_ROOT=/tmp   # same device as $DATA_DIR, which mktemp put under /tmp too
rc=0; run_backup || rc=$?
assert_status "run refuses" 1 "$rc"
grep -q "same block device" "$SCRATCH/log" && ok "refusal names the reason" || bad "refusal names the reason"
unset MOCK_DB_LIST MOCK_DOCKER_ROOT
scenario_teardown

# ─── T7: restic image pin without a digest is refused before anything runs ─
head_ "T7: RESTIC_IMAGE has no @sha256: digest"
scenario_setup
write_conf
sed -i 's|@sha256:[0-9a-f]*||' "$CONF"
rc=0; run_backup || rc=$?
assert_status "run refuses" 1 "$rc"
grep -q "no @sha256: digest" "$SCRATCH/log" && ok "refusal names the reason" || bad "refusal names the reason"
scenario_teardown

# ─── T8: weekly check + monthly read-data-subset fire on a fresh state, ────
# ─── and do NOT fire again immediately after ────────────────────────────────
head_ "T8: hub check + read-data-subset scheduling"
scenario_setup
write_conf
export MOCK_DB_LIST=$'alpha\nbeta\ngamma'
rc=0; run_backup || rc=$?
assert_status "first run succeeds" 0 "$rc"
grep -q "restic .*check\b" "$SCRATCH/log" >/dev/null 2>&1 || true  # informational only
first_check="$(state_get '.hub.last_check_at')"
first_readdata="$(state_get '.hub.last_readdata_at')"
first_cursor="$(state_get '.hub.read_data_cursor')"
[ "$first_check" != "null" ] && ok "last_check_at set on first run" || bad "last_check_at set on first run"
[ "$first_readdata" != "null" ] && ok "last_readdata_at set on first run" || bad "last_readdata_at set on first run"
assert_eq "cursor advanced 1 -> 2 on success" "$first_cursor" "2"

rc=0; run_backup || rc=$?
assert_status "second run (same day) succeeds" 0 "$rc"
second_check="$(state_get '.hub.last_check_at')"
second_readdata="$(state_get '.hub.last_readdata_at')"
assert_eq "weekly check NOT re-run same day" "$second_check" "$first_check"
assert_eq "monthly read-data NOT re-run same month" "$second_readdata" "$first_readdata"
unset MOCK_DB_LIST
scenario_teardown

# ─── T9: a failed read-data-subset does not advance the cursor ─────────────
head_ "T9: read-data-subset failure leaves the cursor where it was"
scenario_setup
write_conf
export MOCK_DB_LIST=$'alpha\nbeta\ngamma'
export MOCK_HUB_READDATA_FAIL=1
rc=0; run_backup || rc=$?
assert_status "run fails (hub failure exits immediately)" 1 "$rc"
cursor="$(state_get '.hub.read_data_cursor')"
readdata_at="$(state_get '.hub.last_readdata_at')"
assert_eq "cursor unchanged after a failed check" "$cursor" "1"
assert_eq "last_readdata_at unchanged after a failed check" "$readdata_at" "null"
unset MOCK_DB_LIST MOCK_HUB_READDATA_FAIL
scenario_teardown

# ─── T10: cursor wraps 12 -> 1 ──────────────────────────────────────────────
head_ "T10: read-data-subset cursor wraps from 12 back to 1"
scenario_setup
write_conf
export MOCK_DB_LIST=$'alpha\nbeta\ngamma'
mkdir -p "$STATE_DIR"
cat >"$STATE_DIR/state.json" <<'JSON'
{"hub": {"read_data_cursor": 12, "last_check_at": null, "last_readdata_at": null}, "preflight_failed_count": 0, "destinations": {}}
JSON
rc=0; run_backup || rc=$?
assert_status "run succeeds" 0 "$rc"
assert_eq "cursor wraps to 1" "$(state_get '.hub.read_data_cursor')" "1"
unset MOCK_DB_LIST
scenario_teardown

# ─── T11: no destinations configured — hub-only run succeeds ───────────────
head_ "T11: empty destinations list"
scenario_setup
write_conf
export MOCK_DB_LIST=$'alpha\nbeta\ngamma'
rc=0; run_backup || rc=$?
assert_status "run succeeds with no destinations" 0 "$rc"
assert_eq "no destinations recorded in state" "$(state_get '.destinations | length')" "0"
unset MOCK_DB_LIST
scenario_teardown

# ─── T12: hub failure exits immediately, before ANY destination is attempted ─
head_ "T12: a hub backup failure skips fan-out entirely"
scenario_setup
write_conf '"desk:rest:http://mockhost:8000/construct/"'
export MOCK_DB_LIST=$'alpha\nbeta\ngamma'
export MOCK_HUB_BACKUP_FAIL=1
write_dest_creds
rc=0; run_backup || rc=$?
assert_status "run fails immediately" 1 "$rc"
assert_eq "destination never attempted" "$(state_get '.destinations | length')" "0"
unset MOCK_DB_LIST MOCK_HUB_BACKUP_FAIL
scenario_teardown

# ─── T13: miss semantics — retry once, then move on; threshold trips the ───
# ─── run only on the Nth consecutive miss, never sooner ─────────────────────
head_ "T13: consecutive misses trip the threshold on the 3rd, not before"
scenario_setup
write_conf '"desk:rest:http://mockhost:8000/construct/"'
export MOCK_DB_LIST=$'alpha\nbeta\ngamma'
export MOCK_COPY_FAIL=1
write_dest_creds
rc=0; run_backup || rc=$?
assert_status "run 1: overall still succeeds (below threshold)" 0 "$rc"
assert_eq "run 1: consecutive_misses=1" "$(state_get '.destinations.desk.consecutive_misses')" "1"
rc=0; run_backup || rc=$?
assert_status "run 2: overall still succeeds (below threshold)" 0 "$rc"
assert_eq "run 2: consecutive_misses=2" "$(state_get '.destinations.desk.consecutive_misses')" "2"
rc=0; run_backup || rc=$?
assert_status "run 3: threshold reached, run fails" 1 "$rc"
assert_eq "run 3: consecutive_misses=3" "$(state_get '.destinations.desk.consecutive_misses')" "3"
unset MOCK_DB_LIST MOCK_COPY_FAIL
scenario_teardown

# ─── T14: a successful `copy` with nothing at the destination is a miss, ──
# ─── not a success — freshness is read from the destination, not the claim ─
head_ "T14: copy exits 0 but the destination shows no matching snapshot"
scenario_setup
write_conf '"desk:rest:http://mockhost:8000/construct/"'
export MOCK_DB_LIST=$'alpha\nbeta\ngamma'
export MOCK_SNAPSHOTS_EMPTY=1
write_dest_creds
rc=0; run_backup || rc=$?
assert_status "run succeeds (below threshold)" 0 "$rc"
assert_eq "no success recorded" "$(state_get '.destinations.desk.last_success_at')" "null"
assert_eq "recorded as a miss instead" "$(state_get '.destinations.desk.consecutive_misses')" "1"
unset MOCK_DB_LIST MOCK_SNAPSHOTS_EMPTY
scenario_teardown

# ─── T15: a genuine success is read back from the destination's own list ──
head_ "T15: a real copy success is recorded from the destination's snapshot list"
scenario_setup
write_conf '"desk:rest:http://mockhost:8000/construct/"'
export MOCK_DB_LIST=$'alpha\nbeta\ngamma'
write_dest_creds
rc=0; run_backup || rc=$?
assert_status "run succeeds" 0 "$rc"
assert_eq "success recorded" "$(state_get '.destinations.desk.consecutive_misses')" "0"
assert_ne "last_success_at recorded" "$(state_get '.destinations.desk.last_success_at')" "null"
unset MOCK_DB_LIST
scenario_teardown

# ─── T16: a hung copy is bounded by the per-call restic timeout ────────────
head_ "T16: a hanging copy is killed by the per-call timeout, not left running"
scenario_setup
write_conf '"desk:rest:http://mockhost:8000/construct/"'
export MOCK_DB_LIST=$'alpha\nbeta\ngamma'
export MOCK_COPY_HANG=1
write_dest_creds
start="$(date +%s)"
rc=0; run_backup || rc=$?
elapsed=$(( $(date +%s) - start ))
assert_status "run succeeds (below threshold, hang is a miss)" 0 "$rc"
[ "$elapsed" -lt 15 ] && ok "run bounded by the timeout (${elapsed}s, not the mock's 30s sleep)" \
  || bad "run took ${elapsed}s — the per-call timeout did not bound the hang"
unset MOCK_DB_LIST MOCK_COPY_HANG
scenario_teardown

# ─── T17: a concurrent run is refused, not raced against staging cleanup ──
# ─── (rev-1 bug: the lock was taken AFTER staging_setup had already wiped ──
# ─── the directory a first, in-progress run was using) ────────────────────
head_ "T17: a second invocation is refused while the first still holds the lock"
scenario_setup
write_conf
export MOCK_DB_LIST=$'alpha\nbeta\ngamma'
export MOCK_DUMP_HANG_DB=beta
export MOCK_DUMP_HANG_SEC=3
PATH="$MOCK_BIN:$PATH" MOCK_DOCKER_ROOT=/data MOCK_DB_LIST="$MOCK_DB_LIST" \
  MOCK_DUMP_HANG_DB="$MOCK_DUMP_HANG_DB" MOCK_DUMP_HANG_SEC="$MOCK_DUMP_HANG_SEC" \
  RESTIC_PASSWORD_HUB=testpw \
  BACKUP_CONF="$CONF" BACKUP_ENV_FILE="$ENVFILE" \
  BACKUP_STATE_DIR="$STATE_DIR" BACKUP_DATA_DIR="$DATA_DIR" \
  "$BACKUP_SCRIPT" run >"$SCRATCH/log.a" 2>&1 &
run_a_pid=$!
sleep 1
rc_b=0; run_backup || rc_b=$?
assert_status "second invocation refuses" 1 "$rc_b"
grep -q "another run is already in progress" "$SCRATCH/log" && ok "refusal names the reason" || bad "refusal names the reason"
wait "$run_a_pid"; rc_a=$?
assert_status "first invocation still succeeds, undisturbed" 0 "$rc_a"
for db in alpha beta gamma; do
  grep -q "dumped '$db'" "$SCRATCH/log.a" && ok "run A: '$db' dumped (not wiped by run B's staging_setup)" || bad "run A: '$db' dumped"
done
unset MOCK_DB_LIST MOCK_DUMP_HANG_DB MOCK_DUMP_HANG_SEC
scenario_teardown

# ─── T18: two clusters to one destination — one miss per NIGHT, not per ────
# ─── (cluster × destination) pair (rev-1 bug: threshold tripped on night 2) ─
head_ "T18: a destination serving two clusters gets one miss per night, not one per cluster"
scenario_setup
write_conf_two_clusters '"desk:rest:http://mockhost:8000/construct/"'
export MOCK_DB_LIST=$'a1\na2\nb1\nb2'
export MOCK_COPY_FAIL=1
write_dest_creds
rc=0; run_backup || rc=$?
assert_status "night 1: still below threshold" 0 "$rc"
assert_eq "night 1: exactly one miss, not two" "$(state_get '.destinations.desk.consecutive_misses')" "1"
rc=0; run_backup || rc=$?
assert_status "night 2: still below threshold" 0 "$rc"
assert_eq "night 2: exactly two misses, not four" "$(state_get '.destinations.desk.consecutive_misses')" "2"
rc=0; run_backup || rc=$?
assert_status "night 3: threshold reached" 1 "$rc"
assert_eq "night 3: exactly three misses" "$(state_get '.destinations.desk.consecutive_misses')" "3"
unset MOCK_DB_LIST MOCK_COPY_FAIL
scenario_teardown

# ─── T19: one cluster permanently failing must not be hidden behind another ─
# ─── that keeps succeeding (rev-1 bug: the second cluster's call reset the ─
# ─── whole destination to success every night) ─────────────────────────────
head_ "T19: a permanently failing cluster is not hidden by another that succeeds"
scenario_setup
write_conf_two_clusters '"desk:rest:http://mockhost:8000/construct/"'
export MOCK_DB_LIST=$'a1\na2\nb1\nb2'
export MOCK_COPY_FAIL_TAG=alpha
write_dest_creds
for _ in 1 2 3; do
  rc=0; run_backup || rc=$?
done
assert_status "night 3: threshold reached despite beta succeeding every night" 1 "$rc"
assert_eq "night 3: three misses, not reset to 0 by beta's successes" "$(state_get '.destinations.desk.consecutive_misses')" "3"
unset MOCK_DB_LIST MOCK_COPY_FAIL_TAG
scenario_teardown

# ─── T20: a stale snapshot sharing the tag is not mistaken for tonight's ──
# ─── (rev-1 bug: any snapshot with the right tag, of any age, counted) ─────
head_ "T20: a destination snapshot that shares the tag but isn't tonight's copy is a miss"
scenario_setup
write_conf '"desk:rest:http://mockhost:8000/construct/"'
export MOCK_DB_LIST=$'alpha\nbeta\ngamma'
export MOCK_DEST_SNAPSHOT_ORIGINAL="some-other-nights-snapshot-id"
write_dest_creds
rc=0; run_backup || rc=$?
assert_status "run succeeds (below threshold)" 0 "$rc"
assert_eq "not recorded as a success" "$(state_get '.destinations.desk.last_success_at')" "null"
assert_eq "recorded as a miss instead" "$(state_get '.destinations.desk.consecutive_misses')" "1"
unset MOCK_DB_LIST MOCK_DEST_SNAPSHOT_ORIGINAL
scenario_teardown

# ─── T21: an exhausted preflight on a FRESH state dir must not corrupt ─────
# ─── state.json — round-2 review finding: state_init_if_missing ran AFTER ──
# ─── preflight_retry_loop, so its failure path's state_update targeted a ──
# ─── file that did not exist yet, and jq's failure there still got moved ──
# ─── into place as a 0-byte file, silently disabling every later check ────
head_ "T21: an exhausted preflight on a fresh state dir leaves state.json valid"
scenario_setup
write_conf
export MOCK_DB_LIST=$'alpha\nbeta\ngamma'
export MOCK_DOCKER_DOWN=1
rc=0; run_backup || rc=$?
assert_status "run fails (preflight exhausted)" 1 "$rc"
[ -s "$STATE_DIR/state.json" ] && ok "state.json is non-empty after an exhausted preflight" || bad "state.json is non-empty after an exhausted preflight"
jq -e . "$STATE_DIR/state.json" >/dev/null 2>&1 && ok "state.json is still valid JSON" || bad "state.json is still valid JSON"
assert_eq "preflight_failed_count recorded" "$(state_get '.preflight_failed_count')" "1"
unset MOCK_DOCKER_DOWN
rc=0; run_backup || rc=$?
assert_status "second run, preflight now healthy, proceeds normally" 0 "$rc"
unset MOCK_DB_LIST
scenario_teardown

# ─── T22: a credential file that isn't 0600 is refused, not trusted ───────
# ─── (signet render does not enforce this itself — measured, not assumed) ──
head_ "T22: backup.env at the wrong mode is refused before it's ever sourced"
scenario_setup
write_conf
export MOCK_DB_LIST=$'alpha\nbeta\ngamma'
chmod 0644 "$ENVFILE"
rc=0; run_backup || rc=$?
assert_status "run refuses" 1 "$rc"
grep -q "is mode 644, not 600" "$SCRATCH/log" && ok "refusal names the actual mode" || bad "refusal names the actual mode"
unset MOCK_DB_LIST
scenario_teardown

# ─── T23/T24: verify-destination's argument validation (SERV-215) ──────────
# The real network/append-only proof this command makes is deliberately NOT
# exercised here — see this file's header. What IS testable without a real
# receiver is that it refuses cleanly before ever touching the network: no
# name given, or a name that isn't in BACKUP_DESTINATIONS.
head_ "T23: verify-destination with no name argument"
scenario_setup
write_conf '"desk:rest:http://mockhost:8000/construct/"'
write_dest_creds
rc=0; run_backup verify-destination || rc=$?
assert_status "refuses" 1 "$rc"
grep -q "needs a destination name" "$SCRATCH/log" && ok "refusal names the requirement" || bad "refusal names the requirement"
scenario_teardown

head_ "T24: verify-destination against an unconfigured name"
scenario_setup
write_conf '"desk:rest:http://mockhost:8000/construct/"'
write_dest_creds
rc=0; PATH="$MOCK_BIN:$PATH" MOCK_DOCKER_ROOT=/data \
  BACKUP_CONF="$CONF" BACKUP_ENV_FILE="$ENVFILE" \
  BACKUP_STATE_DIR="$STATE_DIR" BACKUP_DATA_DIR="$DATA_DIR" \
  "$BACKUP_SCRIPT" verify-destination nosuchdest >"$SCRATCH/log" 2>&1 || rc=$?
assert_status "refuses" 1 "$rc"
grep -q "no destination named 'nosuchdest'" "$SCRATCH/log" && ok "refusal names the unknown destination" || bad "refusal names the unknown destination"
scenario_teardown

# ─── T25: verify-destination is excluded by the SAME lock cmd_run holds ────
# ─── (PR #230 review: without this, a hand-run verify-destination during ──
# ─── the nightly window force-removes the real run's in-flight container) ─
head_ "T25: verify-destination refuses while a real run holds the lock, and can proceed once it's released"
scenario_setup
write_conf '"desk:rest:http://mockhost:8000/construct/"'
write_dest_creds
export MOCK_DB_LIST=$'alpha\nbeta\ngamma'
export MOCK_DUMP_HANG_DB=beta
export MOCK_DUMP_HANG_SEC=3
PATH="$MOCK_BIN:$PATH" MOCK_DOCKER_ROOT=/data MOCK_DB_LIST="$MOCK_DB_LIST" \
  MOCK_DUMP_HANG_DB="$MOCK_DUMP_HANG_DB" MOCK_DUMP_HANG_SEC="$MOCK_DUMP_HANG_SEC" \
  RESTIC_PASSWORD_HUB=testpw \
  BACKUP_CONF="$CONF" BACKUP_ENV_FILE="$ENVFILE" \
  BACKUP_STATE_DIR="$STATE_DIR" BACKUP_DATA_DIR="$DATA_DIR" \
  "$BACKUP_SCRIPT" run >"$SCRATCH/log.a" 2>&1 &
run_a_pid=$!
sleep 1
rc_b=0; PATH="$MOCK_BIN:$PATH" MOCK_DOCKER_ROOT=/data \
  BACKUP_CONF="$CONF" BACKUP_ENV_FILE="$ENVFILE" \
  BACKUP_STATE_DIR="$STATE_DIR" BACKUP_DATA_DIR="$DATA_DIR" \
  "$BACKUP_SCRIPT" verify-destination desk >"$SCRATCH/log.b" 2>&1 || rc_b=$?
assert_status "verify-destination refuses while the real run holds the lock" 1 "$rc_b"
grep -q "a nightly run is in progress" "$SCRATCH/log.b" && ok "refusal names the reason" || bad "refusal names the reason"
wait "$run_a_pid"; rc_a=$?
assert_status "the real run still succeeds, undisturbed" 0 "$rc_a"
unset MOCK_DB_LIST MOCK_DUMP_HANG_DB MOCK_DUMP_HANG_SEC
scenario_teardown

head_ "Summary: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
