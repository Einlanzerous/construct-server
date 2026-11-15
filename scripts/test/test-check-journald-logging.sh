#!/usr/bin/env bash
# test-check-journald-logging.sh — run scripts/check-journald-logging.sh against fake
# `docker` and `journalctl` binaries. Proves: it reports the driver per service, exits 1 on a
# wrong driver or a missing container, prints counts only (a canary planted in the fake journal
# never reaches stdout), and never calls anything but read-only subcommands.
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/check-journald-logging.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
BIN="$T/bin"; mkdir -p "$BIN"
CANARY='LOGLINE-CANARY-9f3a1c77'
CALLS="$T/calls.log"; : >"$CALLS"
FAILS=0
ok()   { echo "  ok    $1"; }
fail() { echo "  FAIL  $1"; FAILS=$((FAILS + 1)); }
expect() { if eval "$2"; then ok "$1"; else fail "$1"; fi; }

# Driver per container comes from DRV_<name with - as _>; unset means "not found".
cat >"$BIN/docker" <<'STUB'
#!/usr/bin/env bash
echo "docker $*" >>"$CALLS_LOG"
[ "$1" = inspect ] || exit 99
name="${*: -1}"; var="DRV_${name//-/_}"
[ -n "${!var:-}" ] || exit 1
echo "${!var}"
STUB
cat >"$BIN/journalctl" <<'STUB'
#!/usr/bin/env bash
echo "journalctl $*" >>"$CALLS_LOG"
case "$*" in
  *--disk-usage*) echo "Archived and active journals take up 2.7G in the file system." ;;
  *CONTAINER_NAME=*)
    [ "${JOURNAL_DOWN:-0}" = 1 ] && exit 1
    printf '%s secret health reading\n' "$CANARY"; echo second line; echo third line ;;
  *"-u systemd-journald"*) printf 'Suppressed 12 messages from docker.service\nunrelated\n' ;;
esac
STUB
chmod +x "$BIN/docker" "$BIN/journalctl"
export CALLS_LOG="$CALLS" CANARY PATH="$BIN:$PATH"
export DRV_satlink=journald DRV_plimsoll_llm=json-file DRV_plimsoll=json-file

echo "all expected"
rc=0; bash "$SCRIPT" >"$T/out" 2>&1 || rc=$?
expect "exits 0" '[ "$rc" = 0 ]'
expect "driver per service printed" 'grep -q "ok    satlink: journald" "$T/out" && grep -q "ok    plimsoll-llm: json-file" "$T/out" && grep -q "ok    plimsoll: json-file" "$T/out"'
expect "journal count printed (3 lines)" 'grep -q "satlink: 3 lines" "$T/out"'
expect "disk usage printed" 'grep -q "take up 2.7G" "$T/out"'
expect "suppressed count printed (1)" 'grep -q "docker.service: 1" "$T/out"'
expect "no log line in stdout" '! grep -qF -e "$CANARY" -e "second line" -e "secret health" "$T/out"'
expect "only read-only calls" '! grep -E "docker (rm|run|restart|stop|compose|logs|exec)|journalctl.*(--vacuum|--rotate|--flush)" "$CALLS"'

echo "wrong driver"
rc=0; DRV_satlink=json-file bash "$SCRIPT" >"$T/out" 2>&1 || rc=$?
expect "exits 1" '[ "$rc" = 1 ]'
expect "names the mismatch" 'grep -q "FAIL  satlink: json-file (expected journald)" "$T/out"'

echo "plimsoll on journald"
rc=0; DRV_plimsoll=journald bash "$SCRIPT" >"$T/out" 2>&1 || rc=$?
expect "exits 1" '[ "$rc" = 1 ]'

echo "container missing"
rc=0; env -u DRV_satlink bash "$SCRIPT" >"$T/out" 2>&1 || rc=$?
expect "exits 1 and says not found" '[ "$rc" = 1 ] && grep -q "satlink: container not found" "$T/out"'

echo "journal unreadable"
rc=0; JOURNAL_DOWN=1 bash "$SCRIPT" >"$T/out" 2>&1 || rc=$?
expect "exits 1" '[ "$rc" = 1 ]'

echo "override list"
rc=0; DRV_purser=journald JOURNALD_SERVICES="satlink purser" bash "$SCRIPT" >"$T/out" 2>&1 || rc=$?
expect "purser checked" '[ "$rc" = 0 ] && grep -q "ok    purser: journald" "$T/out"'

echo
if [ "$FAILS" -ne 0 ]; then echo "FAILED: $FAILS"; exit 1; fi
echo "OK: all check-journald-logging cases pass."
