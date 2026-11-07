#!/usr/bin/env bash
# check-plimsoll-llm-isolation.sh — prove the running model sandbox is isolated (PLIM-14,
# criteria 0 and 2).
#
# check-plimsoll-sandbox.py proves the CONFIGURATION in git. This proves the running
# network does what that configuration claims, because attachment is a proxy for
# reachability and proxies are how SERV-25's deferral stayed hidden. It asserts:
#
#   0. `docker network inspect plimsoll_ai`: internal, gateway_mode_ipv4=isolated,
#      IPv6 off, and exactly two members — plimsoll and plimsoll-llm.
#   1. From a sidecar sharing plimsoll-llm's network namespace:
#        - there is no default route;
#        - external TCP fails (a public IP, by address, so DNS is not the reason);
#        - external DNS fails.
#   2. The HOST cannot connect to plimsoll-llm's address on plimsoll_ai. This is
#      the leg `internal: true` alone leaves open and the isolated gateway closes.
#   3. A throwaway container on the estate network (construct_net) cannot connect
#      to it, by address or by name.
#   4. plimsoll-llm logs through json-file.
#
# POSITIVE CONTROLS, because a probe that can reach nothing reports perfect
# isolation: the sidecar must reach Ollama on its own loopback, `plimsoll` must
# reach plimsoll-llm by name (the one path that should work), and the
# construct_net probe must reach the shared `ollama`. If a control fails, the
# negatives prove nothing and the run fails as UNTESTED.
#
# It starts two throwaway containers (`--rm`) and changes nothing else: no network
# is created, nothing joins plimsoll_ai, and no running container is restarted.
# Run it after every deploy that touches plimsoll, plimsoll-llm or the network, and
# attach the first run's output to the PR that introduced it.
#
# Usage:
#   scripts/check-plimsoll-llm-isolation.sh
#   make plimsoll-llm-isolation
#
# Exit codes:
#   0  isolation holds
#   1  an isolation property is violated, or a positive control failed
#   2  usage / missing dependency / sandbox not running

set -euo pipefail

NET="plimsoll_ai"
LLM="plimsoll-llm"
CLIENT="plimsoll"
ESTATE_NET="${ESTATE_NET:-construct_net}"
SHARED="${SHARED:-ollama}"
PORT=11434
# alpine 3.23, by digest: busybox nc, nslookup, ip and wget are all the probes need.
PROBE_IMAGE="${PROBE_IMAGE:-alpine:3.23@sha256:fd791d74b68913cbb027c6546007b3f0d3bc45125f797758156952bc2d6daf40}"
EXTERNAL_IP="${EXTERNAL_IP:-1.1.1.1}"

command -v docker >/dev/null 2>&1 || { echo "ERROR: docker not found in PATH" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq not found in PATH" >&2; exit 2; }
command -v timeout >/dev/null 2>&1 || { echo "ERROR: timeout not found in PATH" >&2; exit 2; }

[[ "$(docker inspect -f '{{.State.Running}}' "$LLM" 2>/dev/null)" == "true" ]] ||
	{ echo "ERROR: $LLM is not running" >&2; exit 2; }

fail=0
pass() { echo "ok    $*"; }
bad() { echo "FAIL: $*"; fail=1; }

# --- 0. the network, as Docker has it --------------------------------------------
net_json="$(docker network inspect "$NET" 2>/dev/null)" || { echo "ERROR: network $NET does not exist" >&2; exit 2; }
[[ "$(jq -r '.[0].Internal' <<<"$net_json")" == "true" ]] && pass "$NET is internal" || bad "$NET is not internal"
[[ "$(jq -r '.[0].Options["com.docker.network.bridge.gateway_mode_ipv4"] // ""' <<<"$net_json")" == "isolated" ]] &&
	pass "$NET gateway mode is isolated" || bad "$NET gateway mode is not isolated"
[[ "$(jq -r '.[0].EnableIPv6' <<<"$net_json")" == "false" ]] && pass "$NET has IPv6 off" || bad "$NET has IPv6 on"
members="$(jq -r '.[0].Containers | to_entries | map(.value.Name) | sort | join(",")' <<<"$net_json")"
[[ "$members" == "$CLIENT,$LLM" ]] && pass "$NET members are exactly $CLIENT and $LLM" ||
	bad "$NET members are [$members], want [$CLIENT,$LLM]"

llm_ip="$(docker inspect "$LLM" | jq -r --arg n "$NET" '.[0].NetworkSettings.Networks[$n].IPAddress // ""')"
[[ -n "$llm_ip" ]] || { bad "$LLM has no address on $NET"; llm_ip="0.0.0.0"; }
llm_nets="$(docker inspect "$LLM" | jq -r '.[0].NetworkSettings.Networks | keys | join(",")')"
[[ "$llm_nets" == "$NET" ]] && pass "$LLM is on $NET only" || bad "$LLM is on [$llm_nets]"
[[ "$(docker inspect -f '{{.HostConfig.LogConfig.Type}}' "$LLM")" == "json-file" ]] &&
	pass "$LLM logs through json-file" || bad "$LLM does not log through json-file"

# --- 1. from inside the sandbox's namespace ----------------------------------------
# Each probe prints one token, so the result is read, not inferred from an exit code
# that a missing tool would also produce.
inside="$(docker run --rm --network "container:$LLM" -e EXT="$EXTERNAL_IP" -e PORT="$PORT" "$PROBE_IMAGE" sh -c '
	if nc -z -w 3 127.0.0.1 "$PORT"; then echo control=ok; else echo control=fail; fi
	if ip route | grep -q "^default"; then echo route=present; else echo route=none; fi
	if nc -z -w 3 "$EXT" 443; then echo tcp=open; else echo tcp=closed; fi
	if timeout 5 nslookup example.com >/dev/null 2>&1; then echo dns=resolves; else echo dns=fails; fi
' 2>&1 || true)"
if grep -qx 'control=ok' <<<"$inside"; then
	pass "control: the sidecar reaches Ollama on loopback"
	grep -qx 'route=none' <<<"$inside" && pass "no default route" || bad "the sandbox has a default route"
	grep -qx 'tcp=closed' <<<"$inside" && pass "external TCP fails" || bad "external TCP to $EXTERNAL_IP:443 connects"
	grep -qx 'dns=fails' <<<"$inside" && pass "external DNS fails" || bad "external DNS resolves"
else
	bad "UNTESTED: the sidecar could not reach Ollama on loopback, so its negatives prove nothing ($inside)"
fi

# --- 2. from the host ------------------------------------------------------------
if timeout 4 bash -c "exec 3<>/dev/tcp/$llm_ip/$PORT" 2>/dev/null; then
	bad "the host connects to $LLM at its $NET address"
else
	pass "the host cannot connect to $LLM"
fi

# --- control for 3: plimsoll reaches the sandbox by name ---------------------------
if docker exec "$CLIENT" wget -q -T 5 -O /dev/null "http://$LLM:$PORT/api/version" 2>/dev/null; then
	pass "control: $CLIENT reaches $LLM by name"
else
	bad "control: $CLIENT cannot reach $LLM, so the sandbox is unusable (or $CLIENT has no wget)"
fi

# --- 3. from a container on the estate network --------------------------------------
estate="$(docker run --rm --network "$ESTATE_NET" -e IP="$llm_ip" -e PORT="$PORT" -e LLM="$LLM" -e SHARED="$SHARED" "$PROBE_IMAGE" sh -c '
	if nc -z -w 3 "$SHARED" "$PORT"; then echo control=ok; else echo control=fail; fi
	if nc -z -w 3 "$IP" "$PORT"; then echo ip=open; else echo ip=closed; fi
	if nc -z -w 3 "$LLM" "$PORT"; then echo name=open; else echo name=closed; fi
' 2>&1 || true)"
if grep -qx 'control=ok' <<<"$estate"; then
	pass "control: a $ESTATE_NET container reaches $SHARED"
	grep -qx 'ip=closed' <<<"$estate" && pass "$ESTATE_NET cannot connect to $LLM by address" ||
		bad "a $ESTATE_NET container connects to $LLM at $llm_ip"
	grep -qx 'name=closed' <<<"$estate" && pass "$ESTATE_NET cannot connect to $LLM by name" ||
		bad "a $ESTATE_NET container connects to $LLM by name"
else
	bad "UNTESTED: the $ESTATE_NET probe could not reach $SHARED, so its negatives prove nothing ($estate)"
fi

if [[ $fail -ne 0 ]]; then
	echo
	echo "The Plimsoll model sandbox is NOT shown isolated (PLIM-14)."
	exit 1
fi
echo
echo "OK: the Plimsoll model sandbox is isolated."
