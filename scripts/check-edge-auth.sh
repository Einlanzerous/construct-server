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
#   2. The guard's CF_ACCESS_AUD_MAP covers exactly the GATED routers' hosts — no
#      unmapped host (which would be unreachable) and no dead entry. A host whose
#      every router is exempt (placard) must NOT carry an AUD: an Access
#      application on a host the origin serves openly means the edge and the
#      origin disagree about whether it is open.
#   3. Where a service validates the same assertion itself for SSO (switchyard,
#      lyceum), its CF_ACCESS_AUD agrees with the guard's entry for its host.
#      This is a regex sweep over variable names ENDING in CF_ACCESS_AUD, which
#      is why 4 exists separately.
#   4. When switchyard-mcp is in the compose file, switchyard's CF_ACCESS_MCP_AUD
#      equals its MCP_CF_ACCESS_AUD (SERV-161). A different question from 3: that
#      one asks whether an audience is registered for a HOST, this asks whether
#      the API server will ACCEPT an assertion minted for the MCP application when
#      the MCP forwards it to POST /v1/auth/sso/cloudflare. It is here because it
#      is the only Access misconfiguration in this estate that fails silently and
#      green — see the block itself for what that looked like.
#   5. traefik.yml's `internal` address matches Traefik's ipv4_address in the
#      compose file — if they disagree, Traefik binds an address it does not hold
#      and every tunneled app goes dark.
#   6. LIVE: the guard reports healthy and is in `enforce` mode.
#   7. LIVE: a spoofed-Host request to the internal entrypoint returns 403, for
#      every tunneled host, from the HOST — which reaches container ports whether
#      or not they are published, and is the probe angle SERV-107's review asked
#      for.
#   8. LIVE: a host with no router at all does not get a 200 either.
#   9. LIVE: the entrypoint answers on its bound address and on NO OTHER address the
#      Traefik container holds. `address: "1.2.3.4:9080"` is the whole of what makes
#      the entrypoint unreachable from the app network (SERV-107) — and until this
#      check existed, nothing asserted it: every probe above aims at the bound
#      address, so a regression to `:9080` would pass all of them.
#
# TWO EDGES, ONE SCRIPT (SERV-93). `--dev` points every one of the checks above at
# the dev project's edge instead: config/traefik-dev/, docker-compose.dev.yml,
# cf-access-guard-dev, traefik-dev's address on construct_dev_edge_net. The dev edge
# is a second Traefik and a second tunnel rather than a leg of prod's, so there is
# nothing shared to get confused about — but the QUESTION is identical, and asking it
# with a second copy of this script is how the two would drift apart. The only
# difference in substance is the exemption allowlist: prod has two entries (the
# GitHub webhook's exact path, and placard's whole host — public by design,
# IDEA-22), dev has none and must keep having none.
#
# Usage:
#   ./scripts/check-edge-auth.sh                 # config + live (what deploy.yml runs)
#   ./scripts/check-edge-auth.sh --config-only   # config only, for a checkout with no stack
#   ./scripts/check-edge-auth.sh --dev           # the dev edge (make dev-edge-auth-check)
#   ./scripts/check-edge-auth.sh --dev --config-only
#
# Exit codes:
#   0  the origin authenticates
#   1  a property is violated
#   2  usage / missing dependency error

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd)"
MIDDLEWARE="cf-access-jwt"

CONFIG_ONLY=0
DEV=0
while [ $# -gt 0 ]; do
  case "$1" in
    --config-only) CONFIG_ONLY=1 ;;
    --dev)         DEV=1 ;;
    *) printf 'usage: check-edge-auth.sh [--dev] [--config-only]\n' >&2; exit 2 ;;
  esac
  shift
done

# Everything that differs between the two edges, gathered in one place so a reader can
# see the whole of the difference rather than hunting for it. The CHECKS below are
# identical for both.
if [ "$DEV" -eq 1 ]; then
  EDGE_LABEL="Dev edge auth (SERV-93)"
  ROUTERS="$REPO_ROOT/config/traefik-dev/dynamic/routers.yml"
  STATIC="$REPO_ROOT/config/traefik-dev/traefik.yml"
  COMPOSE="$REPO_ROOT/docker-compose.dev.yml"
  GUARD_CONTAINER="${GUARD_CONTAINER:-cf-access-guard-dev}"
  TRAEFIK_SERVICE="traefik-dev"
  EDGE_NET="construct_dev_edge_net"
  # No exemptions, and that is a property to keep. Prod exempts the GitHub webhook
  # because Access cannot authenticate GitHub and the endpoint is HMAC-gated instead;
  # dev holds no GITHUB_WEBHOOK_SECRET and must never receive a real webhook, so an
  # unauthenticated path into a tier running untested `latest` builds would buy
  # nothing. An empty allowlist here is what makes adding one a visible diff.
  EXEMPT_JSON='{}'
else
  EDGE_LABEL="Edge auth (SERV-106)"
  ROUTERS="$REPO_ROOT/config/traefik/dynamic/routers.yml"
  STATIC="$REPO_ROOT/config/traefik/traefik.yml"
  COMPOSE="$REPO_ROOT/docker-compose.yml"
  GUARD_CONTAINER="${GUARD_CONTAINER:-cf-access-guard}"
  TRAEFIK_SERVICE="traefik"
  EDGE_NET="construct_edge_net"
  # Routers deliberately NOT behind the middleware. Every entry is a hole in origin
  # auth, so this is an ALLOWLIST and not a pattern: an internal router that is
  # neither gated nor named here fails the check. Adding to it is a reviewable diff in
  # a security script, which is the point — the failure mode this exists to prevent is
  # an exemption nobody had to argue for.
  EXEMPT_JSON='{"switchyard-github-webhook": "GitHub cannot authenticate to Access; the endpoint is HMAC-gated by GITHUB_WEBHOOK_SECRET", "placard": "public by design (IDEA-22): every surface this host serves (mark mirror, front page, API) is contractually fetchable with no session — placard-host URLs are rendered sessionless in viewers browsers as launcher tiles and badges, and a gate turns them into silent login-HTML failures; content mirrors a public GitHub repo and the one write path is token-gated in the app"}'
fi

err() { printf '%s\n' "$*" >&2; }
for dep in python3; do
  command -v "$dep" >/dev/null 2>&1 || { err "ERROR: required dependency '$dep' not found in PATH"; exit 2; }
done
for f in "$ROUTERS" "$STATIC" "$COMPOSE"; do
  [ -f "$f" ] || { err "ERROR: $f not found"; exit 2; }
done

FAIL=0

# AN EMPTY AUD MAP IS PENDING SETUP, NOT A REGRESSION — but only while nothing is
# serving. The dev edge ships with CF_ACCESS_AUD_MAP empty because the AUDs come from
# Access applications that do not exist until someone creates them, and the guard
# refuses to start on an empty map, so an unconfigured dev edge cannot be serving
# anything. Reporting that as FAIL makes the ordinary pending state indistinguishable
# from a real fault and puts a permanent red in front of a check that should be usable
# in CI.
#
# Narrow on purpose. It applies only when the map is ENTIRELY empty, only in --dev, and
# only when the guard is not running. A map with some entries but not others is drift; a
# running guard means the edge IS serving and every host had better be mapped. Prod is
# never eligible.
AUD_PENDING_OK=0
if [ "$DEV" -eq 1 ]; then
  if ! command -v docker >/dev/null 2>&1 \
     || [ "$(docker inspect -f '{{.State.Running}}' "$GUARD_CONTAINER" 2>/dev/null || echo false)" != "true" ]; then
    AUD_PENDING_OK=1
  fi
fi

# The config parse below also emits the live half's probe list, so both halves
# read one parse of one file and cannot disagree about which hosts are tunneled.
PROBES="$(mktemp)"
trap 'rm -f "$PROBES"' EXIT

echo "=== $EDGE_LABEL ==="
echo

# --- 1-4. Configuration ------------------------------------------------------
# Parsed structurally, not grepped: a grep for the middleware name would match it
# in a comment, and would not notice a router that lists it under the wrong key.
# The AUD map is read from the RAW compose file rather than `docker compose
# config` for the reason the wiki generator does the same (SERV-101) — the
# resolved view interpolates every variable, and this script has no business
# holding the deployed environment.
ROUTERS="$ROUTERS" STATIC="$STATIC" COMPOSE="$COMPOSE" MIDDLEWARE="$MIDDLEWARE" PROBE_OUT="$PROBES" \
TRAEFIK_SERVICE="$TRAEFIK_SERVICE" EDGE_NET="$EDGE_NET" EXEMPT_JSON="$EXEMPT_JSON" \
AUD_PENDING_OK="$AUD_PENDING_OK" \
python3 <<'PY' || FAIL=1
import json, os, re, sys, yaml

routers_file, static_file, compose_file = os.environ["ROUTERS"], os.environ["STATIC"], os.environ["COMPOSE"]
middleware = os.environ["MIDDLEWARE"]
fail = False

def bad(msg):
    global fail
    print(f"  FAIL  {msg}")
    fail = True

# The exemption allowlist for whichever edge is being checked — set by the shell
# above, where both edges' values sit side by side. See there for why prod has one
# entry and dev has none.
EXEMPT = json.loads(os.environ["EXEMPT_JSON"])

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
# stops being noticed — and an edge with NO exemptions has to say so too, or "we
# checked and there are none" is indistinguishable from "we forgot to look".
if not EXEMPT:
    print("  ok    no router is exempt from origin auth on this edge")
for name, why in sorted(EXEMPT.items()):
    if name in internal:
        print(f"  ok    {name} is exempt by design — {why}")
    else:
        bad(f"EXEMPT names {name}, which is not an internal router — stale entry, remove it")

# Host(`x`) is the only rule form used on this entrypoint; anything else is a
# router this script cannot reason about and is reported rather than ignored.
hosts = {}
host_routers = {}
for name, r in internal.items():
    found = re.findall(r"Host\(`([^`]+)`\)", r.get("rule", ""))
    if not found:
        bad(f"router {name} has no Host(`...`) rule, so its audience cannot be checked")
    for h in found:
        hosts[h.lower()] = name
        host_routers.setdefault(h.lower(), []).append(name)

# A host whose EVERY router is exempt is open by design (placard). It needs no
# AUD — there is deliberately no Access application — and the live half asserts
# it SERVES rather than that it refuses. Computed per-host, not per-router,
# because switchyard's host carries both a gated router and the exempt webhook
# path and must stay in the gated set.
open_hosts = {h for h, names in host_routers.items() if all(n in EXEMPT for n in names)}

raw = open(compose_file).read()

def env_values(var):
    return re.findall(rf"^\s*-\s*{var}=(.*)$", raw, re.M)

# Parsed once, here, because two checks below need it: the entrypoint-bind check
# and the SERV-161 audience pair. RAW compose deliberately — never
# `docker compose config`, which interpolates every variable and would pull the
# rendered .env into this script's view (the same rule the wiki generator
# follows, SERV-101).
compose_doc = yaml.safe_load(raw) or {}

# Distinguishes "key not declared" from "declared with an empty/absent value".
_ABSENT = object()

def service_env(service):
    """A service's environment as a dict, whether compose spells it as a list
    of KEY=VALUE strings or as a mapping. Returns {} for a service that is not
    in the file, so a caller can ask about a service that may not be deployed."""
    spec = ((compose_doc.get("services") or {}).get(service) or {}).get("environment") or {}
    if isinstance(spec, dict):
        return {k: "" if v is None else str(v) for k, v in spec.items()}
    out = {}
    for item in spec:
        text = str(item)
        if "=" in text:
            k, _, v = text.partition("=")
            out[k.strip()] = v
        else:
            # Bare passthrough (`- FOO`), which compose fills from the env file.
            # None, not "", so a caller can tell "not declared here" from
            # "declared, value not visible in the tracked file" — the idiom is
            # live in this repo (SIGNET_API_TOKEN, AMBER_API_TOKEN,
            # PROMOTE_DISPATCH_TOKEN), and reporting it as absent would name a
            # specific, wrong cause on a check that gates the prod deploy.
            out[text.strip()] = None
    return out

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

unmapped = sorted(set(hosts) - set(aud_map) - open_hosts)
dead = sorted(set(aud_map) - set(hosts))
misgated = sorted(open_hosts & set(aud_map))
if misgated:
    bad(f"host(s) exempt from origin auth but carrying an AUD: {', '.join(misgated)}")
    print("        An AUD means a gated Access application exists for a host the origin")
    print("        serves openly — the edge and the origin disagree about whether it is")
    print("        open. For placard that gate breaks every launcher icon (IDEA-22):")
    print("        remove the Access application, or remove the exemption, not neither.")
pending = bool(unmapped) and not aud_map and os.environ.get("AUD_PENDING_OK") == "1"
if pending:
    # Not a failure, and not silent either. See the shell above for how narrow this is.
    print(f"  PEND  no AUD recorded yet for: {', '.join(unmapped)}")
    print("        The guard refuses to start on an empty map, so nothing is being served")
    print("        unauthenticated — this edge is not up. Create the Access applications")
    print("        and paste each AUD into CF_ACCESS_AUD_MAP; docs/dev-environment.md has")
    print("        the runbook.")
elif unmapped:
    bad(f"tunneled host(s) with no AUD registered: {', '.join(unmapped)}")
    print("        The guard refuses an unmapped host, so these are unreachable.")
if dead:
    bad(f"CF_ACCESS_AUD_MAP entries with no matching router: {', '.join(dead)}")
if not unmapped and not dead and not misgated and aud_map:
    gated_hosts = len(hosts) - len(open_hosts)
    print(f"  ok    CF_ACCESS_AUD_MAP covers exactly the {gated_hosts} gated tunneled host(s)")

# Cross-check against the AUDs the apps carry for their own SSO sign-in. A
# mismatch means one of the two is stale, and the symptom would be "SSO works but
# the page 403s" — a confusing failure worth catching as a config diff instead.
# SERV-139: an OPTIONAL service prefix. Anchored on the literal name this missed
# CHRONICLE_CF_ACCESS_AUD entirely — Chronicle verifies the assertion in-process
# exactly as switchyard and lyceum do, so it is squarely in this check's scope,
# and the agreement below read as satisfied on a value it never read.
# CF_ACCESS_AUD_MAP stays excluded on its own: the trailing "=" in the pattern
# does not match that line's "_MAP=".
service_auds = env_values(r"[A-Z0-9_]*CF_ACCESS_AUD")
mapped_auds = set(aud_map.values())
for aud in service_auds:
    aud = aud.strip()
    if aud and aud not in mapped_auds:
        bad(f"a service carries CF_ACCESS_AUD={aud[:16]}… which is in no CF_ACCESS_AUD_MAP entry")
if service_auds and all(a.strip() in mapped_auds for a in service_auds if a.strip()):
    print(f"  ok    {len(service_auds)} service-side CF_ACCESS_AUD value(s) agree with the map")

# The one Access audience the sweep above structurally CANNOT see (SERV-161).
#
# That pattern matches names ENDING in CF_ACCESS_AUD. `CF_ACCESS_MCP_AUD` does
# not, so it was invisible — and widening the pattern is the wrong fix, because
# `[A-Z0-9_]*CF_ACCESS_AUD[A-Z0-9_]*` also swallows CF_ACCESS_AUD_MAP and would
# compare the guard's whole map string against itself. It is named here instead.
#
# It is also a DIFFERENT question from the sweep. Everything above asks whether
# an audience is registered for a host — a routing fact. This asks whether the
# API server will ACCEPT an assertion minted for the MCP application when
# switchyard-mcp forwards it to POST /v1/auth/sso/cloudflare, which is an
# application-level trust decision one hop past anything the edge inspects.
#
# Why it earns a check of its own rather than a line in a runbook: it is the only
# Access misconfiguration in this estate that fails SILENTLY AND GREEN. Every
# other one is loud — an unmapped host is refused by the guard, a router missing
# cf-access-jwt fails above, an unset MCP_CF_ACCESS_AUD crash-loops the
# container. When this one was wrong (SERV-99, fixed in #184) Access
# authenticated the user, the guard passed the request, switchyard-mcp verified
# the assertion against its own AUD, the container was healthy, this script
# passed both halves and assert-healthy reported 19/0 — and every remote tool
# call failed. The only evidence anywhere was a 401 in switchyard's request log.
#
# Gated on switchyard-mcp being IN the compose file, not on the variable being
# present: deploying that container is what makes the exchange necessary, so
# absence is a failure exactly when the container exists, and this stays quiet
# for anyone who has not deployed it. Config-only — both values are tracked, so
# no live probe can tell you anything this cannot.
MCP_SVC, API_SVC = "switchyard-mcp", "switchyard"
if MCP_SVC in (compose_doc.get("services") or {}):
    mcp_env, api_env = service_env(MCP_SVC), service_env(API_SVC)
    mcp_raw = mcp_env.get("MCP_CF_ACCESS_AUD", _ABSENT)
    api_raw = api_env.get("CF_ACCESS_MCP_AUD", _ABSENT)
    mcp_side = "" if mcp_raw in (_ABSENT, None) else mcp_raw.strip()
    api_side = "" if api_raw in (_ABSENT, None) else api_raw.strip()
    # Declared but sourced from the env file: this script reads RAW compose, so
    # the value genuinely is not here to compare. Say that, rather than failing a
    # legitimate wiring or — worse — printing "carries no CF_ACCESS_MCP_AUD" at
    # someone whose variable is present and correct.
    if mcp_raw is None or api_raw is None:
        print(f"  NOTE  the {MCP_SVC}/{API_SVC} Access audience pair is passed through from")
        print("        the env file, so its value is not in the tracked compose and cannot")
        print("        be cross-checked here. Confirm the two match by hand on a rotation.")
    elif not api_side:
        bad(f"{MCP_SVC} is deployed but {API_SVC} carries no CF_ACCESS_MCP_AUD")
        print(f"        The SSO exchange accepts only CF_ACCESS_AUD without it, and the MCP")
        print(f"        forwards assertions carrying the MCP application's audience — so every")
        print(f"        remote tool call 401s on POST /v1/auth/sso/cloudflare while every other")
        print(f"        check here passes. Set it on {API_SVC} to {MCP_SVC}'s MCP_CF_ACCESS_AUD.")
    elif not mcp_side:
        bad(f"{MCP_SVC} carries no MCP_CF_ACCESS_AUD to check {API_SVC}'s CF_ACCESS_MCP_AUD against")
    elif api_side != mcp_side:
        # Printed IN FULL, both sides. These are 64-hex-character tags, so a
        # prefix would render a tail difference as two identical strings — a
        # self-contradicting FAIL line, on the one check whose entire purpose is
        # to leave evidence where the original bug left none. They are public
        # identifiers tracked in git, so there is nothing to withhold.
        bad(f"{API_SVC} CF_ACCESS_MCP_AUD does not match {MCP_SVC} MCP_CF_ACCESS_AUD")
        print(f"        {API_SVC}: {api_side}")
        print(f"        {MCP_SVC}: {mcp_side}")
        first_diff = next(
            (i for i, (a, b) in enumerate(zip(api_side, mcp_side)) if a != b),
            min(len(api_side), len(mcp_side)),
        )
        print(f"        first differ at offset {first_diff}")
        print("        These name the same Access application and must be byte-identical.")
        print("        A mismatch fails exactly like the missing variable: silently, at the")
        print("        SSO exchange, with nothing else red.")
    else:
        print(f"  ok    {API_SVC} accepts {MCP_SVC}'s Access audience (CF_ACCESS_MCP_AUD)")

# The address Traefik binds `internal` to must be an address Traefik holds.
static = yaml.safe_load(open(static_file)) or {}
addr = ((static.get("entryPoints") or {}).get("internal") or {}).get("address", "")
ip = addr.rsplit(":", 1)[0] if ":" in addr else ""
traefik_service, edge_net = os.environ["TRAEFIK_SERVICE"], os.environ["EDGE_NET"]
traefik_nets = ((compose_doc.get("services") or {}).get(traefik_service) or {}).get("networks") or {}
declared = ""
if isinstance(traefik_nets, dict):
    declared = ((traefik_nets.get(edge_net) or {}) or {}).get("ipv4_address", "")
if not declared:
    bad(f"compose gives {traefik_service} no ipv4_address on {edge_net}")
    print("        The entrypoint binds one fixed address; with no fixed address to bind,")
    print("        Traefik either fails to start or listens somewhere nobody meant it to.")
elif ip and ip != declared:
    bad(f"the static config binds internal to {ip} but compose gives {traefik_service} {declared} on {edge_net}")
    print("        Traefik would bind an address it does not hold and every tunneled app goes dark.")
elif ip:
    print(f"  ok    internal entrypoint {addr} matches {traefik_service}'s address on {edge_net}")

# Emit the probe targets for the live half. Written before the exit below, so a
# failing config check still produces the list the live probes need — a config
# error and a live bypass are separate findings and the run should report both.
with open(os.environ["PROBE_OUT"], "w") as fh:
    fh.write(f"addr {addr}\n")
    if pending:
        fh.write("pending 1\n")
    for h in sorted(set(hosts) - open_hosts):
        fh.write(f"host {h}\n")
    for name in sorted(EXEMPT):
        r = internal.get(name)
        if not r:
            continue
        rule = (r.get("rule") or "").strip()
        eh = re.findall(r"Host\(`([^`]+)`\)", rule)
        ep = re.findall(r"Path\(`([^`]+)`\)", rule)
        if len(eh) == 1 and len(ep) == 1:
            fh.write(f"exempt {eh[0].lower()} {ep[0]}\n")
        elif len(eh) == 1 and not ep and re.fullmatch(r"Host\(`[^`]+`\)", rule):
            # A whole-host exemption: the rule is exactly one bare Host() and
            # nothing else. Probed with the assertion INVERTED — the host must
            # serve a sessionless request, guard uninvolved — because for a
            # public-by-design host (placard, IDEA-22) "refuses without a
            # session" is the broken state, not the safe one.
            fh.write(f"exempt-host {eh[0].lower()}\n")
        else:
            # Anything else — Host + PathPrefix, multiple hosts, an OR — is
            # broader than either exemption shape and cannot be probed, so it
            # would sit here unverified. Refuse it.
            bad(f"{name} is exempt but its rule is neither one Host + one exact Path nor one bare Host; too broad to verify")

sys.exit(1 if fail else 0)
PY

if [ "$CONFIG_ONLY" -eq 1 ]; then
  echo
  echo "  NOTE  --config-only: the live probe did NOT run. A config that reads"
  echo "        correctly while the origin serves 200 is the failure this exists"
  echo "        to catch, so run without the flag on the box before believing it."
  echo
  if [ "$FAIL" -eq 0 ]; then
    if grep -q '^pending 1$' "$PROBES" 2>/dev/null; then
      echo "Config checks passed — but the AUD map is empty, so this edge cannot serve."
      echo "Nothing here is wrong; it is unfinished. See the PEND line above."
    else
      echo "Config checks passed."
    fi
    exit 0
  fi
  echo "Config checks FAILED."; exit 1
fi

# --- Live probes -------------------------------------------------------------
for dep in docker curl; do
  command -v "$dep" >/dev/null 2>&1 || { err "ERROR: required dependency '$dep' not found in PATH"; exit 2; }
done

ADDR="$(awk '$1=="addr"{print $2}' "$PROBES")"
mapfile -t HOSTS < <(awk '$1=="host"{print $2}' "$PROBES")
mapfile -t EXEMPTS < <(awk '$1=="exempt"{print $2, $3}' "$PROBES")
mapfile -t EXEMPT_HOSTS < <(awk '$1=="exempt-host"{print $2}' "$PROBES")
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

# 6b. Whole-host exemptions, asserted INVERTED. These hosts are public by
# design, so "refuses a sessionless request" is the broken state: for placard a
# gate means any sessionless viewer fetching a placard-hosted mark (a launcher
# tile pointed at the mirror, a service badge) gets login HTML where an image
# belongs, and the surface silently falls back to initials (IDEA-22). The
# assertion is therefore that the host SERVES (200) and that the guard never
# touched the request — the spoofed-Host loop above deliberately skips these
# hosts.
for host in "${EXEMPT_HOSTS[@]}"; do
  code="$(probe "$host")"
  verdict="$(guard_verdict "$host" "/")"
  if [ "$verdict" = "none" ] && [ "$code" = "200" ]; then
    echo "  ok    exempt host $host serves openly (200, guard uninvolved)"
  elif [ "$verdict" = "unreachable" ] || [ "$code" = "000" ]; then
    echo "  FAIL  exempt host $host is unreachable — openness cannot be verified"; FAIL=1
  elif [ "$verdict" != "none" ]; then
    echo "  FAIL  exempt host $host was handled by the guard ($verdict) — the whole-host exemption is not in effect"
    echo "        If this is placard, its front page and every placard-hosted mark are"
    echo "        silently serving login HTML right now (IDEA-22)."
    FAIL=1
  else
    echo "  FAIL  exempt host $host answered $code to a sessionless request (expected 200)"
    echo "        The route bypasses the guard but the service behind it is not serving."
    FAIL=1
  fi
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

# 8. The bind is a bind. Every check above aims at the address the entrypoint is
# CONFIGURED to hold, so all of them keep passing if someone reverts the address to
# `:9080` — which listens on every interface the container has, including the app
# network shared with ~30 other containers. That was the SERV-107 finding, and this
# is the only thing here that would notice it coming back.
#
# The port must come from the configured address, not be assumed: an entrypoint moved
# to another port would otherwise be probed on a port nothing listens on, and pass.
#
# "Could not connect" is the PASS here, which everywhere else in this script it is
# not — so the control matters. It is inherent rather than added: the probes a few
# lines above just reached $ADDR with the same curl, in the same run, and got a 403.
# A curl that could not connect to anything would have failed those first.
#
# Reads the container by $TRAEFIK_SERVICE, which is the compose service key used for
# the config checks above. That works because both edges pin `container_name` to the
# same string; if one ever stops doing so, this needs the container name separately.
echo
ADDR_IP="${ADDR%:*}"
ADDR_PORT="${ADDR##*:}"
OTHER_IPS="$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}={{$v.IPAddress}}{{"\n"}}{{end}}' \
  "$TRAEFIK_SERVICE" 2>/dev/null | awk -F= -v skip="$ADDR_IP" '$2 != "" && $2 != skip {print $1"="$2}')"
if [ -z "$OTHER_IPS" ]; then
  # Not a failure: a Traefik on exactly one network has no other address to leak on.
  echo "  ok    $TRAEFIK_SERVICE holds no address other than $ADDR_IP"
else
  while IFS='=' read -r net ip; do
    [ -z "$ip" ] && continue
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 \
      -H "Host: ${HOSTS[0]}" "http://$ip:$ADDR_PORT/" 2>/dev/null || true)"
    if [ "${code:-000}" = "000" ]; then
      echo "  ok    nothing listens on $ip:$ADDR_PORT ($net) — the single-address bind holds"
    else
      echo "  FAIL  $ip:$ADDR_PORT ($net) ANSWERED ($code) — the entrypoint is not bound to one address"
      echo "        Every other probe in this script aims at $ADDR and would still pass."
      echo "        Check the entrypoint address in the static config: ':PORT' means every"
      echo "        interface, which on a shared network means every neighbour (SERV-107)."
      FAIL=1
    fi
  done <<EOF
$OTHER_IPS
EOF
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "The origin authenticates: every tunneled host rejects a request with no valid"
  echo "Cloudflare Access assertion, and the guard is healthy and enforcing."
  exit 0
fi
echo "FAILED — see above. The origin is not (or not fully) authenticating requests."
exit 1
