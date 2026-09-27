#!/usr/bin/env bash
# backup-status.sh — what `make backup-status` runs (SERV-43 / SERV-214).
#
# Answers the question `docker compose ps`-style checks can't: did last
# night's run actually happen, and did it actually land at every destination
# — not just "is the timer enabled". state.json is read directly rather than
# through backup-nightly.sh, so this never touches the lock or triggers a run.
set -euo pipefail

STATE_FILE="${BACKUP_STATE_DIR:-/var/lib/construct-backup}/state.json"

echo "== timer =="
systemctl list-timers construct-backup.timer --all --no-pager || true

echo
echo "== last run =="
systemctl status construct-backup.service --no-pager --lines=20 || true

echo
echo "== state =="
if [ ! -f "$STATE_FILE" ]; then
  echo "no state.json yet at $STATE_FILE — the timer hasn't fired, or the host wiring isn't applied yet"
  exit 0
fi

# never() <jq null-or-value string> — state.json stores "never happened" as
# JSON null; a fresh instance must not render that as a fault (SWY-408's own
# design rule, followed here even though the reporter itself is SERV-218).
never() { [ "$1" = "null" ] && echo "never" || echo "$1"; }

printf 'preflight_failed_count: %s\n' "$(jq -r '.preflight_failed_count' "$STATE_FILE")"
printf 'hub.last_check_at:      %s\n' "$(never "$(jq -r '.hub.last_check_at' "$STATE_FILE")")"
printf 'hub.last_readdata_at:   %s (cursor %s/12)\n' \
  "$(never "$(jq -r '.hub.last_readdata_at' "$STATE_FILE")")" \
  "$(jq -r '.hub.read_data_cursor' "$STATE_FILE")"

echo
echo "destinations:"
if [ "$(jq -r '.destinations | length' "$STATE_FILE")" -eq 0 ]; then
  echo "  (none configured)"
else
  jq -r '.destinations | to_entries[] | "  \(.key): last_attempt=\(.value.last_attempt_at // "never") last_success=\(.value.last_success_at // "never") consecutive_misses=\(.value.consecutive_misses)"' "$STATE_FILE"
fi
