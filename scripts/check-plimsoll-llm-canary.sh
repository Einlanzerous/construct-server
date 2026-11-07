#!/usr/bin/env bash
# check-plimsoll-llm-canary.sh — prove no prompt reached a container log (PLIM-14, criterion 3).
#
# A live Plimsoll evaluation plants a random canary string in a fact AND in the
# question, and drives the failure paths as well as the happy one: a schema
# failure, a client cancel, a timeout mid-generation, an unload during a request and
# a context-limit refusal. Prompt text that leaks does so on an error path far more
# often than on a 200. This then asserts:
#
#   1. plimsoll-llm and plimsoll both log through `json-file`, and nothing else — so
#      `docker logs` really is every place a log line went;
#   2. the canary appears ZERO times in either container's full log.
#
# It prints counts only. A hit means a prompt is in the log, so the matching line
# is never echoed; read it on the box with `docker logs <container> | grep -F`, and
# treat the log as holding health data until it rotates out or the container is
# recreated.
#
# Usage:
#   scripts/check-plimsoll-llm-canary.sh <canary>
#   make plimsoll-llm-canary CANARY=<canary>
#
# Exit codes:
#   0  zero hits in both, json-file in both
#   1  a hit, or a container logs somewhere else
#   2  usage / missing dependency / container not running

set -euo pipefail

CANARY="${1:-}"
CONTAINERS=(plimsoll-llm plimsoll)

command -v docker >/dev/null 2>&1 || { echo "ERROR: docker not found in PATH" >&2; exit 2; }
# A short canary can match ordinary text and prove nothing; the eval mints 32 hex chars.
if [[ ${#CANARY} -lt 16 ]]; then
	echo "usage: $0 <canary>   (at least 16 characters; the one the live eval printed)" >&2
	exit 2
fi

fail=0
for c in "${CONTAINERS[@]}"; do
	if ! driver="$(docker inspect -f '{{.HostConfig.LogConfig.Type}}' "$c" 2>/dev/null)"; then
		echo "ERROR: container $c not found" >&2
		exit 2
	fi
	if [[ "$driver" != "json-file" ]]; then
		echo "FAIL: $c logs through '$driver', not json-file"
		fail=1
	fi
	# grep -c prints the count; it exits 1 on zero matches, which is the good case.
	hits="$(docker logs "$c" 2>&1 | grep -cF -- "$CANARY" || true)"
	if [[ "$hits" != "0" ]]; then
		echo "FAIL: the canary appears $hits time(s) in $c's log"
		fail=1
	else
		echo "ok    $c: json-file, 0 canary hits"
	fi
done

if [[ $fail -ne 0 ]]; then
	echo
	echo "A prompt reached a container log (Plimsoll invariant 4). Lines not shown."
	exit 1
fi
echo "OK: no canary in either log."
