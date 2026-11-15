#!/usr/bin/env bash
# check-journald-logging.sh — read-only status of container journald logging (SATL-25).
#
# Prints, and only prints:
#   1. the log driver of each service, against what it is expected to use;
#   2. the number of journal lines per CONTAINER_NAME, for the services expected on journald;
#   3. `journalctl --disk-usage`;
#   4. the count of 'Suppressed ... messages from docker.service' notices in the last 24 h
#      (journald's rate limit dropping lines; expect 0).
#
# It NEVER prints a log line: journal output is piped into `wc -l`/`grep -c` and only the
# number survives. Switchyard is shown to others and container logs can hold health data.
# It changes nothing and needs no sudo (the owner reads the journal through the adm group).
#
# JOURNALD services are the adopters (wave A: satlink; wave B: purser, cf-access-guard; wave C: switchyard). A later wave adds its service to the
# list below in the same PR that adds `logging: *journald-logging`. JSONFILE services must
# stay on json-file: plimsoll-llm and plimsoll (PLIM-14, check-plimsoll-llm-canary.sh).
#
# Usage:
#   scripts/check-journald-logging.sh        (or: make journald-check)
#   JOURNALD_SERVICES="satlink purser" scripts/check-journald-logging.sh
#
# Exit codes:
#   0  every container is on its expected driver
#   1  a driver is not the expected one, or the journal is unreadable
#   2  missing dependency

set -euo pipefail

read -r -a JOURNALD <<<"${JOURNALD_SERVICES:-satlink purser cf-access-guard switchyard}"
read -r -a JSONFILE <<<"${JSONFILE_SERVICES:-plimsoll-llm plimsoll}"

command -v docker >/dev/null 2>&1 || { echo "ERROR: docker not found in PATH" >&2; exit 2; }
command -v journalctl >/dev/null 2>&1 || { echo "ERROR: journalctl not found in PATH" >&2; exit 2; }

fail=0
echo "== log driver per service =="
check_driver() {   # check_driver NAME EXPECTED
	local driver
	if ! driver="$(docker inspect -f '{{.HostConfig.LogConfig.Type}}' "$1" 2>/dev/null)" || [[ -z "$driver" ]]; then
		echo "FAIL  $1: container not found (expected $2)"
		fail=1
	elif [[ "$driver" != "$2" ]]; then
		echo "FAIL  $1: $driver (expected $2)"
		fail=1
	else
		echo "ok    $1: $driver"
	fi
}
for c in "${JOURNALD[@]}"; do check_driver "$c" journald; done
for c in "${JSONFILE[@]}"; do check_driver "$c" json-file; done

echo
echo "== journal lines per CONTAINER_NAME (counts only) =="
for c in "${JOURNALD[@]}"; do
	if ! n="$(journalctl "CONTAINER_NAME=$c" --no-pager -q -o cat 2>/dev/null | wc -l)"; then
		echo "FAIL  $c: journal unreadable"
		fail=1
	else
		echo "$c: $n lines"
	fi
done

echo
echo "== journal disk usage =="
journalctl --disk-usage 2>&1 || { echo "FAIL  journal disk usage unreadable"; fail=1; }

echo
echo "== rate-limit drops, last 24 h (expect 0) =="
# grep -c prints the count and exits 1 on zero matches, which is the good case.
drops="$(journalctl -u systemd-journald --since -24h --no-pager -q -o cat 2>/dev/null | grep -c 'Suppressed .* messages from docker.service' || true)"
echo "Suppressed notices for docker.service: $drops"

echo
if [[ $fail -ne 0 ]]; then
	echo "FAIL: a service is not on its expected log driver (or the journal is unreadable)."
	exit 1
fi
echo "OK: drivers as expected."
