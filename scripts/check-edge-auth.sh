#!/usr/bin/env bash
# check-edge-auth.sh — Assert the origin rejects a spoofed Host (SERV-106).
#
# Cloudflare Access is enforced at Cloudflare's EDGE. The origin used to re-check
# nothing, so anything that could open a connection to Traefik's `internal`
# entrypoint got the tunneled apps by naming one in a Host header:
#
#   curl -H "Host: switchyard.zerogravity.industries" http://traefik:9080/  -> 200
#
# unauthenticated production Switchyard. This script is that command, run against
# the live stack, asserting it now returns 403.
#
# It is deliberately BOTH a config check and a live probe, because they fail
# differently. The config half catches "someone added a tunneled router and did
# not attach the middleware" at review time. The live half catches everything
# else — a guard that is down, in audit mode, holding no signing keys, or wired
# to an address Traefik cannot reach. A config file that says the right thing
# while the origin serves 200 is the exact failure SERV-106 exists to close, and
# only the live probe sees it.
#
# WHAT IS CHECKED
#   1. Every router on the `internal` entrypoint carries the cf-access-jwt
#      middleware.
#   2. The guard's CF_ACCESS_AUD_MAP covers exactly those routers' hosts — no
#      unmapped host (which would be unreachable) and no dead entry.
#   3. Where a service validates the same assertion itself for SSO (switchyard,
#      lyceum), its CF_ACCESS_AUD agrees with the guard's entry for its host.
#   4. traefik.yml's `internal` address matches Traefik's ipv4_address in the
#      compose file — if they disagree, Traefik binds an address it does not hold
#      and every tunneled app goes dark.
#   5. LIVE: the guard reports healthy and is in `enforce` mode.
#   6. LIVE: a spoofed-Host request to the internal entrypoint returns 403, for
#      every tunneled host, from the HOST — which reaches container ports whether
#      or not they are published, and is the probe angle SERV-107's review asked
#      for.
#   7. LIVE: a host with no router at all does not get a 200 either.
#
# Usage:
#   ./scripts/check-edge-auth.sh                 # config + live (what deploy.yml runs)
#   ./scripts/check-edge-auth.sh --config-only   # config only, for a checkout with no stack
#
# Exit codes:
#   0  the origin authenticates
#   1  a property is violated
#   2  usage / missing dependency error

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd)"
ROUTERS="$REPO_ROOT/config/traefik/dynamic/routers.yml"
STATIC="$REPO_ROOT/config/traefik/traefik.yml"
COMPOSE="$REPO_ROOT/docker-compose.yml"
GUARD_CONTAINER="${GUARD_CONTAINER:-cf-access-guard}"
MIDDLEWARE="cf-access-jwt"

CONFIG_ONLY=0
case "${1:-}" in
  --config-only) CONFIG_ONLY=1 ;;
  "") ;;
  *) printf 'usage: check-edge-auth.sh [--config-only]\n' >&2; exit 2 ;;
esac

err() { printf '%s\n' "$*" >&2; }
for dep in python3; do
  command -v "$dep" >/dev/null 2>&1 || { err "ERROR: required dependency '$dep' not found in PATH"; exit 2; }
done
for f in "$ROUTERS" "$STATIC" "$COMPOSE"; do
  [ -f "$f" ] || { err "ERROR: $f not found"; exit 2; }
done

FAIL=0

# The config parse below also emits the live half's probe list, so both halves
# read one parse of one file and cannot disagree about which hosts are tunneled.
PROBES="$(mktemp)"
trap 'rm -f "$PROBES"' EXIT

echo "=== Edge auth (SERV-106) ==="
echo

# --- 1-4. Configuration ------------------------------------------------------
# Parsed structurally, not grepped: a grep for the middleware name would match it
# in a comment, and would not notice a router that lists it under the wrong key.
# The AUD map is read from the RAW compose file rather than `docker compose
# config` for the reason the wiki generator does the same (SERV-101) — the
# resolved view interpolates every variable, and this script has no business
# holding the deployed environment.
ROUTERS="$ROUTERS" STATIC="$STATIC" COMPOSE="$COMPOSE" MIDDLEWARE="$MIDDLEWARE" PROBE_OUT="$PROBES" \
python3 <<'PY' || FAIL=1
import os, re, sys, yaml

routers_file, static_file, compose_file = os.environ["ROUTERS"], os.environ["STATIC"], os.environ["COMPOSE"]
middleware = os.environ["MIDDLEWARE"]
fail = False

def bad(msg):
    global fail
    print(f"  FAIL  {msg}")
    fail = True

# Routers deliberately NOT behind the middleware. Every entry is a hole in origin
# auth, so this is an ALLOWLIST and not a pattern: an internal router that is
# neither gated nor named here fails the check. Adding to it is a reviewable diff
# in a security script, which is the point — the failure mode this whole ticket
# exists to prevent is an exemption nobody had to argue for.
EXEMPT = {
    "switchyard-github-webhook":
        "GitHub cannot authenticate to Access; the endpoint is HMAC-gated by GITHUB_WEBHOOK_SECRET",
}

routers = (yaml.safe_load(open(routers_file)) or {}).get("http", {}).get("routers", {}) or {}
internal = {n: r for n, r in routers.items() if "internal" in (r.get("entryPoints") or [])}

if not internal:
    bad("no routers on the `internal` entrypoint — this check would pass vacuously")
else:
    missing = sorted(n for n, r in internal.items()
                     if middleware not in (r.get("middlewares") or []) and n not in EXEMPT)
    if missing:
        bad(f"internal routers with no {middleware} middleware: {', '.join(missing)}")
        print(f"        Those hosts are served without any origin-side check of the")
        print(f"        Cloudflare Access assertion. Add `{middleware}` to each, or — if one")
        print(f"        genuinely cannot carry it — add it to EXEMPT in this script with a reason.")
    else:
        gated = len(internal) - len([n for n in EXEMPT if n in internal])
        print(f"  ok    all {gated} gated internal router(s) carry {middleware}")

# Named, never silent. An exemption that stops being printed is an exemption that
# stops being noticed.
for name, why in sorted(EXEMPT.items()):
    if name in internal:
        print(f"  ok    {name} is exempt by design — {why}")
    else:
        bad(f"EXEMPT names {name}, which is not an internal router — stale entry, remove it")

# Host(`x`) is the only rule form used on this entrypoint; anything else is a
# router this script cannot reason about and is reported rather than ignored.
hosts = {}
for name, r in internal.items():
    found = re.findall(r"Host\(`([^`]+)`\)", r.get("rule", ""))
    if not found:
        bad(f"router {name} has no Host(`...`) rule, so its audience cannot be checked")
    for h in found:
        hosts[h.lower()] = name

raw = open(compose_file).read()

def env_values(var):
    return re.findall(rf"^\s*-\s*{var}=(.*)$", raw, re.M)

aud_map_raw = env_values("CF_ACCESS_AUD_MAP")
if len(aud_map_raw) != 1:
    bad(f"expected exactly one CF_ACCESS_AUD_MAP in the compose file, found {len(aud_map_raw)}")
    aud_map = {}
else:
    aud_map = {}
    for entry in re.split(r"[,\s]+", aud_map_raw[0].strip()):
        if not entry:
            continue
        host, _, aud = entry.partition("=")
        aud_map[host.strip().lower()] = aud.strip()

unmapped = sorted(set(hosts) - set(aud_map))
dead = sorted(set(aud_map) - set(hosts))
if unmapped:
    bad(f"tunneled host(s) with no AUD registered: {', '.join(unmapped)}")
    print("        The guard refuses an unmapped host, so these are unreachable.")
if dead:
    bad(f"CF_ACCESS_AUD_MAP entries with no matching router: {', '.join(dead)}")
if not unmapped and not dead and aud_map:
    print(f"  ok    CF_ACCESS_AUD_MAP covers exactly the {len(hosts)} tunneled host(s)")

# Cross-check against the AUDs the apps carry for their own SSO sign-in. A
# mismatch means one of the two is stale, and the symptom would be "SSO works but
# the page 403s" — a confusing failure worth catching as a config diff instead.
service_auds = env_values("CF_ACCESS_AUD")
mapped_auds = set(aud_map.values())
for aud in service_auds:
    aud = aud.strip()
    if aud and aud not in mapped_auds:
        bad(f"a service carries CF_ACCESS_AUD={aud[:16]}… which is in no CF_ACCESS_AUD_MAP entry")
if service_auds and all(a.strip() in mapped_auds for a in service_auds if a.strip()):
    print(f"  ok    {len(service_auds)} service-side CF_ACCESS_AUD value(s) agree with the map")

# The address Traefik binds `internal` to must be an address Traefik holds.
static = yaml.safe_load(open(static_file)) or {}
addr = ((static.get("entryPoints") or {}).get("internal") or {}).get("address", "")
ip = addr.rsplit(":", 1)[0] if ":" in addr else ""
compose_doc = yaml.safe_load(raw) or {}
traefik_nets = ((compose_doc.get("services") or {}).get("traefik") or {}).get("networks") or {}
declared = ""
if isinstance(traefik_nets, dict):
    declared = ((traefik_nets.get("construct_edge_net") or {}) or {}).get("ipv4_address", "")
if ip and declared and ip != declared:
    bad(f"traefik.yml binds internal to {ip} but compose gives Traefik {declared} on construct_edge_net")
    print("        Traefik would bind an address it does not hold and every tunneled app goes dark.")
elif ip and declared:
    print(f"  ok    internal entrypoint {addr} matches Traefik's address on construct_edge_net")

# Emit the probe targets for the live half. Written before the exit below, so a
# failing config check still produces the list the live probes need — a config
# error and a live bypass are separate findings and the run should report both.
with open(os.environ["PROBE_OUT"], "w") as fh:
    fh.write(f"addr {addr}\n")
    for h in sorted(hosts):
        fh.write(f"host {h}\n")
    for name in sorted(EXEMPT):
        r = internal.get(name)
        if not r:
            continue
        eh = re.findall(r"Host\(`([^`]+)`\)", r.get("rule", ""))
        ep = re.findall(r"Path\(`([^`]+)`\)", r.get("rule", ""))
        if len(eh) == 1 and len(ep) == 1:
            fh.write(f"exempt {eh[0].lower()} {ep[0]}\n")
        else:
            # An exemption that is not exactly one host and one exact path is
            # broader than an exemption should be, and cannot be probed — so it
            # would sit here unverified. Refuse it.
            bad(f"{name} is exempt but its rule is not one Host + one exact Path; too broad to verify")

sys.exit(1 if fail else 0)
PY

if [ "$CONFIG_ONLY" -eq 1 ]; then
  echo
  echo "  NOTE  --config-only: the live probe did NOT run. A config that reads"
  echo "        correctly while the origin serves 200 is the failure this exists"
  echo "        to catch, so run without the flag on the box before believing it."
  echo
  [ "$FAIL" -eq 0 ] && { echo "Config checks passed."; exit 0; }
  echo "Config checks FAILED."; exit 1
fi

# --- Live probes -------------------------------------------------------------
for dep in docker curl; do
  command -v "$dep" >/dev/null 2>&1 || { err "ERROR: required dependency '$dep' not found in PATH"; exit 2; }
done

ADDR="$(awk '$1=="addr"{print $2}' "$PROBES")"
mapfile -t HOSTS < <(awk '$1=="host"{print $2}' "$PROBES")
mapfile -t EXEMPTS < <(awk '$1=="exempt"{print $2, $3}' "$PROBES")
if [ -z "$ADDR" ] || [ "${#HOSTS[@]}" -eq 0 ]; then
  err "ERROR: could not derive the internal entrypoint address or its hosts from the config"
  exit 2
fi

# Probed from the HOST, not from a container. The internal entrypoint is not
# published, and is reachable from the host regardless: on Linux the host routes
# to container addresses directly. That is the wider of the two angles and the one
# SERV-107's review flagged as still open.
#
# 5. The guard itself.
echo
GUARD_IP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$GUARD_CONTAINER" 2>/dev/null | awk '{print $1}')"
if [ -z "$GUARD_IP" ]; then
  echo "  FAIL  container '$GUARD_CONTAINER' is not running — nothing is validating the assertion"
  FAIL=1
else
  HEALTH="$(curl -sS --max-time 5 "http://$GUARD_IP:4020/healthz" 2>/dev/null || true)"
  case "$HEALTH" in
    "")            echo "  FAIL  $GUARD_CONTAINER is not answering /healthz"; FAIL=1 ;;
    mode=enforce*) echo "  ok    guard healthy and enforcing — $HEALTH" ;;
    mode=audit*)   echo "  FAIL  guard is in AUDIT mode: it logs rejections and allows them through"
                   echo "        $HEALTH"
                   echo "        Audit is a cutover aid, not a steady state. Unset CF_ACCESS_GUARD_MODE."
                   FAIL=1 ;;
    *)             echo "  FAIL  unexpected /healthz response: $HEALTH"; FAIL=1 ;;
  esac
fi

probe() {
  # Prints the status code, or `000` when curl could not connect at all — which must
  # never be read as a pass. "Could not connect" and "was rejected" are different
  # properties, and conflating them is how SERV-107 came to look like it closed this
  # ticket.
  #
  # `|| true` rather than `|| echo`: on a connection failure curl writes `000` AND
  # exits non-zero, so an `echo` on the right-hand side appends a SECOND line to a
  # value the caller compares as one string.
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "Host: $1" "http://$ADDR/" 2>/dev/null || true)"
  printf '%s\n' "${code:-000}"
}

# 6. The exploit, verbatim, per tunneled host.
echo
for host in "${HOSTS[@]}"; do
  code="$(probe "$host")"
  if [ "$code" = "403" ]; then
    echo "  ok    spoofed Host: $host -> 403"
  else
    echo "  FAIL  spoofed Host: $host -> $code (expected 403)"
    case "$code" in
      200) echo "        The origin served this host to an unauthenticated request. This is SERV-106." ;;
      000) echo "        Could not connect to $ADDR at all. That is not a pass: this asserts the"
           echo "        origin REJECTS the request, and an unreachable edge proves nothing about"
           echo "        what it does when reached. Check that traefik is up and bound correctly." ;;
    esac
    FAIL=1
  fi
done

# The exemptions, asserted in BOTH directions. The guard stamps X-Cf-Access-Guard
# on every response it produces, so its absence is proof the request never reached
# it — which is exactly what an exemption should look like from outside. The `/`
# probe above already covers the other direction: the same host, any other path, is
# still denied. Together they say the hole is real AND that it is only this wide.
guard_verdict() {
  local out
  out="$(curl -s -D- -o /dev/null --max-time 5 -H "Host: $1" "http://$ADDR$2" 2>/dev/null | tr -d '\r')" || true
  # A connection failure must not read as "the guard was bypassed".
  if ! printf '%s' "$out" | grep -qi '^HTTP/'; then printf 'unreachable\n'; return; fi
  printf '%s' "$out" | awk 'tolower($1)=="x-cf-access-guard:"{print $2; f=1} END{if(!f) print "none"}'
}

for entry in "${EXEMPTS[@]}"; do
  # shellcheck disable=SC2086
  set -- $entry
  verdict="$(guard_verdict "$1" "$2")"
  case "$verdict" in
    none) echo "  ok    exempt $1$2 bypasses the guard, as intended" ;;
    unreachable)
      echo "  FAIL  exempt $1$2 is unreachable — the exemption cannot be verified"; FAIL=1 ;;
    *)
      echo "  FAIL  exempt $1$2 was handled by the guard ($verdict) — the exemption is not in effect"
      echo "        If this is the GitHub webhook, external-ref updates and PR-merge"
      echo "        auto-close are silently failing right now (SERV-45)."
      FAIL=1 ;;
  esac
done

# 7. A host nobody routed. Not a 403 necessarily — Traefik has no catch-all on
# this entrypoint, so 404 is the honest answer — but never a 200.
code="$(probe "definitely-not-a-real-host.zerogravity.industries")"
if [ "$code" = "200" ]; then
  echo "  FAIL  an unrouted Host returned 200"
  FAIL=1
else
  echo "  ok    unrouted Host -> $code"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "The origin authenticates: every tunneled host rejects a request with no valid"
  echo "Cloudflare Access assertion, and the guard is healthy and enforcing."
  exit 0
fi
echo "FAILED — see above. The origin is not (or not fully) authenticating requests."
exit 1
