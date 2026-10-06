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
BACKUP_DEST_BUDGET_SEC=${TEST_DEST_BUDGET-4}
BACKUP_DEST_PROBE_TIMEOUT_SEC=${TEST_DEST_PROBE-2}
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
BACKUP_DEST_BUDGET_SEC=${TEST_DEST_BUDGET-4}
BACKUP_DEST_PROBE_TIMEOUT_SEC=${TEST_DEST_PROBE-2}
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

# mock_log_on / mock_log_off — have the mock docker append one line per restic
# invocation to $SCRATCH/mock.log, with what state.json said about the
# destination's last attempt at that moment (SERV-224). Call after
# scenario_setup. mock_count <fixed-string> counts matching lines.
mock_log_on() {
  export MOCK_LOG="$SCRATCH/mock.log"
  export MOCK_STATE_FILE="$STATE_DIR/state.json"
  : >"$MOCK_LOG"
}
mock_log_off() { unset MOCK_LOG MOCK_STATE_FILE; }
mock_count() { grep -c -F -- "$1" "$SCRATCH/mock.log" || true; }

# start_backup_detached — the real script in the background, in its OWN
# session and process group, so a test can signal the whole group the way
# systemd signals a unit's cgroup. Sets RUN_PID (== the group id: a
# background job in a script is not a group leader, so setsid execs in place).
start_backup_detached() {
  PATH="$MOCK_BIN:$PATH" \
    MOCK_DOCKER_ROOT="${MOCK_DOCKER_ROOT:-/data}" \
    MOCK_DB_LIST="${MOCK_DB_LIST-}" \
    BACKUP_CONF="$CONF" BACKUP_ENV_FILE="$ENVFILE" \
    BACKUP_STATE_DIR="$STATE_DIR" BACKUP_DATA_DIR="$DATA_DIR" \
    setsid "$BACKUP_SCRIPT" run >"$SCRATCH/log" 2>&1 &
  RUN_PID=$!
}

# wait_for_mock_line <fixed-string> — up to 10s for the mock to have logged it.
wait_for_mock_line() {
  for _ in $(seq 1 100); do
    grep -q -F -- "$1" "$SCRATCH/mock.log" 2>/dev/null && return 0
    sleep 0.1
  done
  return 1
}

# budget_check <backup.conf> <role defaults.yml> — the unit's TimeoutStartSec
# must cover the worst case the config can produce (docs/backups.md,
# "Wall-clock bounds"):
#   preflight max + hub duration + (destinations × per-destination budget) + margin
# The hub and margin terms are that table's own figures, not config keys.
BUDGET_HUB_SEC=600
BUDGET_MARGIN_SEC=300
budget_check() {
  local conf="$1" defaults="$2" need have
  need="$(
    # shellcheck disable=SC1090
    . "$conf"
    n=0
    for d in "${BACKUP_DESTINATIONS[@]}"; do [ -n "$d" ] && n=$((n + 1)); done
    echo $(( BACKUP_PREFLIGHT_MAX_SEC + BUDGET_HUB_SEC + n * BACKUP_DEST_BUDGET_SEC + BUDGET_MARGIN_SEC ))
  )"
  have="$(sed -n 's/^construct_backup_timeout_start_sec:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$defaults")"
  BUDGET_NEED="$need"; BUDGET_HAVE="${have:-0}"
  [ "$BUDGET_HAVE" -ge "$BUDGET_NEED" ]
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

# ─── T16: a hung copy is bounded by the destination's budget, counted as ────
# ─── ONE miss, and not retried (SERV-224) ──────────────────────────────────
# Until SERV-224 this asserted only the exit status and the elapsed time. It
# passed for the whole of the 2026-10-02/03 outage, because "a timed-out call
# returns" was true — what was never asserted is what state.json says after.
head_ "T16: a hanging copy is cut off by the budget, recorded as one miss, and not retried"
scenario_setup
mock_log_on
write_conf '"desk:rest:http://mockhost:8000/construct/"'
export MOCK_DB_LIST=$'alpha\nbeta\ngamma'
export MOCK_COPY_HANG=1
write_dest_creds
start="$(date +%s)"
rc=0; run_backup || rc=$?
elapsed=$(( $(date +%s) - start ))
assert_status "run succeeds (below threshold, hang is a miss)" 0 "$rc"
[ "$elapsed" -lt 15 ] && ok "run bounded by the budget (${elapsed}s, not the mock's 30s sleep)" \
  || bad "run took ${elapsed}s — the destination budget did not bound the hang"
assert_eq "recorded as exactly one miss" "$(state_get '.destinations.desk.consecutive_misses')" "1"
assert_ne "last_attempt_at recorded" "$(state_get '.destinations.desk.last_attempt_at')" "null"
assert_eq "no success recorded" "$(state_get '.destinations.desk.last_success_at')" "null"
assert_eq "a copy that timed out is not retried (1 copy call)" "$(mock_count 'run copy dest')" "1"
grep -q "copy timed out after" "$SCRATCH/log" && ok "log says the copy timed out" || bad "log says the copy timed out"
unset MOCK_DB_LIST MOCK_COPY_HANG
mock_log_off
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

# ═══ SERV-224: a destination that HANGS ═════════════════════════════════════
# Everything above models a destination that refuses or lies. On 2026-10-02
# and 2026-10-03 the real one did neither: it accepted connections and never
# answered a listing, the run outlived the unit's TimeoutStartSec, and systemd
# killed it before the miss was written. T26 onward are that shape.
DEST='"desk:rest:http://mockhost:8000/construct/"'

# ─── T26: a destination whose probe hangs costs the probe bound, not the ───
# ─── budget, and no copy is ever attempted ─────────────────────────────────
head_ "T26: a hanging probe is one miss, with no copy attempted"
scenario_setup
mock_log_on
write_conf "$DEST"
export MOCK_DB_LIST=$'alpha\nbeta\ngamma'
export MOCK_PROBE_HANG=1
write_dest_creds
start="$(date +%s)"
rc=0; run_backup || rc=$?
elapsed=$(( $(date +%s) - start ))
assert_status "run succeeds (below threshold)" 0 "$rc"
[ "$elapsed" -lt 12 ] && ok "bounded by the probe timeout (${elapsed}s < 2s + 10s)" \
  || bad "run took ${elapsed}s — the probe timeout did not bound the hang"
assert_eq "no copy was attempted" "$(mock_count 'run copy dest')" "0"
assert_eq "recorded as exactly one miss" "$(state_get '.destinations.desk.consecutive_misses')" "1"
assert_ne "last_attempt_at recorded" "$(state_get '.destinations.desk.last_attempt_at')" "null"
assert_eq "last_success_at untouched" "$(state_get '.destinations.desk.last_success_at')" "null"
grep -q "probe failed .* timed out after 2s; no copy attempted" "$SCRATCH/log" && ok "log names the probe and the timeout" || bad "log names the probe and the timeout"
unset MOCK_DB_LIST MOCK_PROBE_HANG
mock_log_off
scenario_teardown

# ─── T27: a probe that fails fast is the same miss, said differently ───────
head_ "T27: a refused probe is one miss, with no copy attempted"
scenario_setup
mock_log_on
write_conf "$DEST"
export MOCK_DB_LIST=$'alpha\nbeta\ngamma'
export MOCK_PROBE_FAIL=1
write_dest_creds
rc=0; run_backup || rc=$?
assert_status "run succeeds (below threshold)" 0 "$rc"
assert_eq "no copy was attempted" "$(mock_count 'run copy dest')" "0"
assert_eq "recorded as exactly one miss" "$(state_get '.destinations.desk.consecutive_misses')" "1"
grep -q "probe failed .* exited 1; no copy attempted" "$SCRATCH/log" && ok "log names the probe and the exit status" || bad "log names the probe and the exit status"
unset MOCK_DB_LIST MOCK_PROBE_FAIL
mock_log_off
scenario_teardown

# ─── T28: two clusters, probe passes, every copy hangs — the DESTINATION ───
# ─── has one deadline, not one per call ────────────────────────────────────
# The pre-SERV-224 shape gave each of up to six calls its own timeout. Here
# the first cluster's copy uses the whole budget, and the second is skipped.
head_ "T28: two hanging clusters share one budget — the second is skipped, one miss total"
scenario_setup
mock_log_on
write_conf_two_clusters "$DEST"
export MOCK_DB_LIST=$'a1\na2\nb1\nb2'
export MOCK_COPY_HANG=1
write_dest_creds
start="$(date +%s)"
rc=0; run_backup || rc=$?
elapsed=$(( $(date +%s) - start ))
assert_status "run succeeds (below threshold)" 0 "$rc"
[ "$elapsed" -lt 14 ] && ok "bounded by the destination budget (${elapsed}s < 4s + 10s)" \
  || bad "run took ${elapsed}s — two clusters were not held to one budget"
grep -q "budget is spent — skipping cluster 'beta'" "$SCRATCH/log" && ok "log names the skipped cluster" || bad "log names the skipped cluster"
assert_eq "only the first cluster's copy ran" "$(mock_count 'run copy dest')" "1"
assert_eq "exactly one miss for the night, not one per cluster" "$(state_get '.destinations.desk.consecutive_misses')" "1"
unset MOCK_DB_LIST MOCK_COPY_HANG
mock_log_off
scenario_teardown

# ─── T29: the attempt is in state.json BEFORE the first network call ───────
# The mock logs what state.json said at the moment of each restic call. If
# last_attempt_at were still written after the copies, the probe would see
# null — and a run killed with SIGKILL would leave no trace of having tried.
head_ "T29: last_attempt_at is written before the destination is first contacted"
scenario_setup
mock_log_on
write_conf "$DEST"
export MOCK_DB_LIST=$'alpha\nbeta\ngamma'
write_dest_creds
rc=0; run_backup || rc=$?
assert_status "run succeeds" 0 "$rc"
first_dest_call="$(grep -F ' dest ' "$SCRATCH/mock.log" | head -1)"
case "$first_dest_call" in
  "run snapshots dest tag=- attempt_seen="*) ok "the first call against the destination is the untagged probe" ;;
  *) bad "the first call against the destination is the untagged probe (got: $first_dest_call)" ;;
esac
seen="${first_dest_call##*attempt_seen=}"
case "$seen" in
  20[0-9][0-9]-*T*Z) ok "the probe already sees last_attempt_at ($seen)" ;;
  *) bad "the probe already sees last_attempt_at (saw: '$seen')" ;;
esac
assert_eq "happy path still records a success" "$(state_get '.destinations.desk.consecutive_misses')" "0"
assert_ne "last_success_at recorded" "$(state_get '.destinations.desk.last_success_at')" "null"
unset MOCK_DB_LIST
mock_log_off
scenario_teardown

# ─── T30/T31/T32: the readback says what actually happened ─────────────────
# 2026-10-02: the readback timed out with stderr discarded and the log said
# "no snapshot at the destination matches" — a data finding for a transport
# failure. Unreadable and absent are both a miss; they are not the same line.
head_ "T30: a readback that exits non-zero is 'could not read', not 'no snapshot matches'"
scenario_setup
write_conf "$DEST"
export MOCK_DB_LIST=$'alpha\nbeta\ngamma'
export MOCK_READBACK_FAIL=1
write_dest_creds
rc=0; run_backup || rc=$?
assert_status "run succeeds (below threshold)" 0 "$rc"
grep -q "could not read the destination to confirm 'svc' (restic exit 1)" "$SCRATCH/log" && ok "log says the destination could not be read, with the exit status" || bad "log says the destination could not be read, with the exit status"
grep -q "no snapshot at the destination matches" "$SCRATCH/log" && bad "the absent-snapshot message is NOT logged" || ok "the absent-snapshot message is NOT logged"
assert_eq "recorded as a miss" "$(state_get '.destinations.desk.consecutive_misses')" "1"
unset MOCK_DB_LIST MOCK_READBACK_FAIL
scenario_teardown

head_ "T31: a readback that hangs is 'could not read ... timed out', and still one miss"
scenario_setup
write_conf "$DEST"
export MOCK_DB_LIST=$'alpha\nbeta\ngamma'
export MOCK_READBACK_HANG=1
write_dest_creds
start="$(date +%s)"
rc=0; run_backup || rc=$?
elapsed=$(( $(date +%s) - start ))
assert_status "run succeeds (below threshold)" 0 "$rc"
[ "$elapsed" -lt 14 ] && ok "bounded by the destination budget (${elapsed}s)" || bad "run took ${elapsed}s"
grep -q "could not read the destination to confirm 'svc' (timed out after" "$SCRATCH/log" && ok "log says the readback timed out" || bad "log says the readback timed out"
grep -q "no snapshot at the destination matches" "$SCRATCH/log" && bad "the absent-snapshot message is NOT logged" || ok "the absent-snapshot message is NOT logged"
assert_eq "recorded as a miss" "$(state_get '.destinations.desk.consecutive_misses')" "1"
unset MOCK_DB_LIST MOCK_READBACK_HANG
scenario_teardown

head_ "T32: a readback that succeeds and lacks tonight's snapshot keeps the absent-snapshot message"
scenario_setup
write_conf "$DEST"
export MOCK_DB_LIST=$'alpha\nbeta\ngamma'
export MOCK_SNAPSHOTS_EMPTY=1
write_dest_creds
rc=0; run_backup || rc=$?
assert_status "run succeeds (below threshold)" 0 "$rc"
grep -q "no snapshot at the destination matches tonight's hub snapshot for 'svc'" "$SCRATCH/log" && ok "absent-snapshot message logged" || bad "absent-snapshot message logged"
grep -q "could not read the destination" "$SCRATCH/log" && bad "the could-not-read message is NOT logged" || ok "the could-not-read message is NOT logged"
assert_eq "recorded as a miss" "$(state_get '.destinations.desk.consecutive_misses')" "1"
unset MOCK_DB_LIST MOCK_SNAPSHOTS_EMPTY
scenario_teardown

# ─── T33: a copy that fails FAST is still retried once ─────────────────────
# The counterpart of T16's "a timed-out copy is not retried".
head_ "T33: a copy that fails fast is retried once (2 copy calls), then a miss"
scenario_setup
mock_log_on
write_conf "$DEST"
export MOCK_DB_LIST=$'alpha\nbeta\ngamma'
export MOCK_COPY_FAIL=1
write_dest_creds
rc=0; run_backup || rc=$?
assert_status "run succeeds (below threshold)" 0 "$rc"
assert_eq "two copy calls: the attempt and its one retry" "$(mock_count 'run copy dest')" "2"
assert_eq "recorded as exactly one miss" "$(state_get '.destinations.desk.consecutive_misses')" "1"
unset MOCK_DB_LIST MOCK_COPY_FAIL
mock_log_off
scenario_teardown

# ─── T34/T35: a run killed from outside mid-copy is a miss (ruling 3) ──────
# T34 signals the whole process group, as systemd signals a unit's cgroup.
# T35 signals ONLY the script: that is the case a foreground `docker run`
# would have failed, since bash defers a trap until its foreground child
# exits — for a hung copy, the whole budget later. The budget here is 25s, so
# "exited within 5s of the signal" can only be the trap, never the deadline.
for kill_mode in group pid; do
  if [ "$kill_mode" = group ]; then
    head_ "T34: SIGTERM to the process group mid-copy — one miss, exit 143, staging removed"
  else
    head_ "T35: SIGTERM to the script alone mid-copy — the trap still runs at once"
  fi
  scenario_setup
  mock_log_on
  TEST_DEST_BUDGET=25 write_conf "$DEST"
  export MOCK_DB_LIST=$'alpha\nbeta\ngamma'
  export MOCK_COPY_HANG=1
  write_dest_creds
  start_backup_detached
  if wait_for_mock_line 'run copy dest'; then
    ok "the run reached the hanging copy"
  else
    bad "the run reached the hanging copy"
  fi
  assert_eq "nothing counted yet while the copy is in flight" "$(state_get '.destinations.desk.consecutive_misses')" "0"
  killed_at="$(date +%s)"
  if [ "$kill_mode" = group ]; then kill -TERM -- "-$RUN_PID"; else kill -TERM "$RUN_PID"; fi
  rc=0; wait "$RUN_PID" || rc=$?
  took=$(( $(date +%s) - killed_at ))
  assert_status "exits 143" 143 "$rc"
  [ "$took" -lt 5 ] && ok "exited ${took}s after the signal (budget was 25s)" || bad "took ${took}s after the signal — the trap waited for the copy"
  assert_eq "exactly one miss recorded" "$(state_get '.destinations.desk.consecutive_misses')" "1"
  assert_eq "no success recorded" "$(state_get '.destinations.desk.last_success_at')" "null"
  grep -q "desk: run killed mid-flight — recorded as a miss" "$SCRATCH/log" && ok "log says the kill was recorded as a miss" || bad "log says the kill was recorded as a miss"
  [ ! -e "$DATA_DIR/staging" ] && ok "staging directory removed on the way out" || bad "staging directory removed on the way out"
  # The next night must count from the recorded miss, not double it.
  unset MOCK_COPY_HANG
  export MOCK_COPY_FAIL=1
  rc=0; run_backup || rc=$?
  assert_eq "the following night's miss makes 2, not 3" "$(state_get '.destinations.desk.consecutive_misses')" "2"
  unset MOCK_DB_LIST MOCK_COPY_FAIL
  mock_log_off
  pkill -s "$RUN_PID" sleep 2>/dev/null || true
  scenario_teardown
done

# ─── T36: a kill OUTSIDE fan-out touches no destination's counter ──────────
head_ "T36: SIGTERM during the dump phase exits 143 and records no miss"
scenario_setup
mock_log_on
write_conf "$DEST"
export MOCK_DB_LIST=$'alpha\nbeta\ngamma'
export MOCK_DUMP_HANG_DB=beta
export MOCK_DUMP_HANG_SEC=3
write_dest_creds
MOCK_DUMP_HANG_DB="$MOCK_DUMP_HANG_DB" MOCK_DUMP_HANG_SEC="$MOCK_DUMP_HANG_SEC" start_backup_detached
sleep 1
kill -TERM -- "-$RUN_PID"
rc=0; wait "$RUN_PID" || rc=$?
[ "$rc" -ne 0 ] && ok "run did not exit 0 (exit $rc)" || bad "run did not exit 0"
assert_eq "no destination was ever recorded" "$(state_get '.destinations | length')" "0"
unset MOCK_DB_LIST MOCK_DUMP_HANG_DB MOCK_DUMP_HANG_SEC
mock_log_off
scenario_teardown

# ─── T37: the two bounds are config, and a bad one stops the run cold ──────
head_ "T37: an unset, empty, non-numeric, zero or inverted destination bound is refused before any dump"
refuse_case() { # <label> <expected-substring>
  rc=0; run_backup || rc=$?
  assert_status "$1: refuses" 1 "$rc"
  grep -q -F -- "$2" "$SCRATCH/log" && ok "$1: names the variable" || bad "$1: names the variable (log: $(head -1 "$SCRATCH/log"))"
  grep -q "dumped '" "$SCRATCH/log" && bad "$1: nothing was dumped first" || ok "$1: nothing was dumped first"
}
scenario_setup
export MOCK_DB_LIST=$'alpha\nbeta\ngamma'
write_dest_creds
TEST_DEST_BUDGET="" write_conf "$DEST";    refuse_case "empty budget" "BACKUP_DEST_BUDGET_SEC is unset, empty or not a positive integer"
TEST_DEST_BUDGET=abc write_conf "$DEST";   refuse_case "non-numeric budget" "BACKUP_DEST_BUDGET_SEC is unset, empty or not a positive integer"
TEST_DEST_BUDGET=0 write_conf "$DEST";     refuse_case "zero budget" "BACKUP_DEST_BUDGET_SEC is unset, empty or not a positive integer"
TEST_DEST_PROBE="" write_conf "$DEST";     refuse_case "empty probe timeout" "BACKUP_DEST_PROBE_TIMEOUT_SEC is unset, empty or not a positive integer"
write_conf "$DEST"; sed -i '/^BACKUP_DEST_BUDGET_SEC=/d' "$CONF"
refuse_case "unset budget" "BACKUP_DEST_BUDGET_SEC is unset, empty or not a positive integer"
write_conf "$DEST"; sed -i '/^BACKUP_DEST_PROBE_TIMEOUT_SEC=/d' "$CONF"
refuse_case "unset probe timeout" "BACKUP_DEST_PROBE_TIMEOUT_SEC is unset, empty or not a positive integer"
TEST_DEST_BUDGET=2 TEST_DEST_PROBE=5 write_conf "$DEST"
refuse_case "probe longer than the budget" "BACKUP_DEST_PROBE_TIMEOUT_SEC (5) exceeds BACKUP_DEST_BUDGET_SEC (2)"
unset MOCK_DB_LIST
scenario_teardown

# ─── T38: hub calls keep their OWN bound — the destination budget is not ───
# ─── a new global timeout ──────────────────────────────────────────────────
# Budget 25s, per-call bound 2s: a hung hub backup must end at ~2s.
head_ "T38: a hanging hub backup is bounded by BACKUP_RESTIC_TIMEOUT_SEC, not the destination budget"
scenario_setup
TEST_DEST_BUDGET=25 write_conf "$DEST"
export MOCK_DB_LIST=$'alpha\nbeta\ngamma'
export MOCK_HUB_BACKUP_HANG=1
write_dest_creds
start="$(date +%s)"
rc=0; run_backup || rc=$?
elapsed=$(( $(date +%s) - start ))
assert_status "run fails (a hub failure exits immediately)" 1 "$rc"
[ "$elapsed" -lt 10 ] && ok "bounded by the 2s per-call timeout (${elapsed}s, budget was 25s)" || bad "run took ${elapsed}s — the hub call was not held to its own bound"
assert_eq "destination never attempted" "$(state_get '.destinations | length')" "0"
unset MOCK_DB_LIST MOCK_HUB_BACKUP_HANG
scenario_teardown

# ─── T39: the unit's TimeoutStartSec covers what the REAL config can cost ──
# The arithmetic the 2026-10 outage broke, checked against the tracked files
# rather than restated in a doc table: add a destination, or raise the budget,
# without raising construct_backup_timeout_start_sec, and this goes red.
head_ "T39: TimeoutStartSec >= preflight + hub + destinations x budget + margin, from the tracked files"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REAL_CONF="$REPO_ROOT/config/backup/backup.conf"
REAL_DEFAULTS="$REPO_ROOT/ansible/roles/construct_backup/defaults/main.yml"
if budget_check "$REAL_CONF" "$REAL_DEFAULTS"; then
  ok "tracked config fits the unit: needs ${BUDGET_NEED}s, TimeoutStartSec is ${BUDGET_HAVE}s"
else
  bad "tracked config does NOT fit the unit: needs ${BUDGET_NEED}s, TimeoutStartSec is ${BUDGET_HAVE}s"
fi
# ...and prove the check can fail: the same config with a second destination.
scenario_setup
cp "$REAL_CONF" "$SCRATCH/two-dest.conf"
cat >>"$SCRATCH/two-dest.conf" <<'CONF'
BACKUP_DESTINATIONS+=("second:rest:http://example.invalid:8000/construct/")
CONF
if budget_check "$SCRATCH/two-dest.conf" "$REAL_DEFAULTS"; then
  bad "a second destination at the current unit value is refused (needs ${BUDGET_NEED}s, has ${BUDGET_HAVE}s)"
else
  ok "a second destination at the current unit value is refused (needs ${BUDGET_NEED}s, has ${BUDGET_HAVE}s)"
fi
scenario_teardown

head_ "Summary: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
