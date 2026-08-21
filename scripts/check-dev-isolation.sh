#!/usr/bin/env bash
# check-dev-isolation.sh — Assert the dev environment cannot reach prod, and the
# WAN cannot reach dev (SERV-77, SERV-93).
#
# SERV-77's stated validation is that for dev, "the check is that the public path
# FAILS". That is a claim about several separate things, and each is checked here
# rather than assumed:
#
#   1. No dev hostname is routed on the PROD edge, and no dev router sits on a
#      public entrypoint.
#   2. No dev container is attached to a PROD network — construct_net or
#      construct_edge_net.
#   3. Every published dev port is bound to loopback, never 0.0.0.0.
#   4. Nothing from outside the dev project is attached to either DEV network.
#   5. REACHABILITY: from the dev network, prod's edge cannot actually be reached.
#
# WHY 5 EXISTS, GIVEN 2 AND 4 (SERV-93)
# Checks 2 and 4 assert ATTACHMENT: who is on which network. That is not the same
# claim as "dev cannot reach prod", and SERV-93's acceptance says so explicitly —
# attachment is a proxy for reachability, and proxies are what let SERV-25's
# deferral stay invisible for six weeks. Check 5 runs the exploit itself from a
# throwaway container on construct_dev_net and asserts prod's edge does not answer.
#
# It carries a POSITIVE CONTROL for the same reason. A probe that cannot connect to
# anything — no wget in the image, wrong network name, a typo in the URL — reports
# "unreachable" for every target and looks exactly like perfect isolation. So the
# same tool, from the same container, must first reach a DEV backend. If the control
# does not answer, the negative results prove nothing and are reported as untested
# rather than as a pass.
#
# WHY THE DEV EDGE DOES NOT WEAKEN ANY OF THIS
# SERV-93 gives dev its own Traefik, its own guard and its own tunnel, all inside the
# dev compose project. Nothing is attached to both a dev and a prod network, so check
# 4 needed no carve-out — which is precisely why that design was chosen over putting
# a leg of the prod Traefik on construct_dev_net. If a future change adds an
# exception here, that is the rejected design arriving by the back door.
#
# Checks 1 and 4 need only the network and the config, so they run whether or not
# the dev project is up. Checks 2, 3 and 5 need running dev containers and are
# skipped (not failed) when there are none.
#
# Usage:
#   ./scripts/check-dev-isolation.sh
#
# Exit codes:
#   0  isolation holds
#   1  an isolation property is violated
#   2  usage / missing dependency error

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd)"
DEV_PROJECT="${DEV_PROJECT:-construct-server-dev}"
PROD_ROUTERS="$REPO_ROOT/config/traefik/dynamic/routers.yml"
DEV_ROUTERS="$REPO_ROOT/config/traefik-dev/dynamic/routers.yml"
PROD_STATIC="$REPO_ROOT/config/traefik/traefik.yml"
DEV_NET="${DEV_NET:-construct_dev_net}"
DEV_EDGE_NET="${DEV_EDGE_NET:-construct_dev_edge_net}"
# The prod networks nothing in dev may touch. construct_edge_net is here as well as
# construct_net because dev now HAS an edge: the plausible mistake is no longer only
# "a dev service joined the prod app network", it is "cloudflared-dev was pointed at
# the prod edge network", which construct_net alone would not see.
PROD_NETS=(construct_net construct_edge_net)

err() { printf '%s\n' "$*" >&2; }
for dep in docker python3; do
  command -v "$dep" >/dev/null 2>&1 || { err "ERROR: required dependency '$dep' not found in PATH"; exit 2; }
done

FAIL=0
SKIPPED=0

# --- 1. Routing: dev is absent from the prod edge, and has no public path --------
# Parsed structurally rather than grepped: a grep for "public" near "dev" would both
# miss a reordering and fire on a comment.
if [ -f "$PROD_ROUTERS" ] && [ -f "$DEV_ROUTERS" ]; then
  PROD_ROUTERS="$PROD_ROUTERS" DEV_ROUTERS="$DEV_ROUTERS" python3 <<'PY' || FAIL=1
import os, re, sys, yaml

def routers(path):
    return (yaml.safe_load(open(path)) or {}).get("http", {}).get("routers", {}) or {}

fail = False

# 1a. The PROD edge must not route dev. This is the option-A regression stated as a
# check: giving dev a hostname on prod's Traefik means prod's Traefik needs a path to
# the dev backends, and the only way it gets one is by joining construct_dev_net.
# Catching it here — in the routing config, at review time — is cheaper than catching
# it in check 4 after it is deployed.
prod = routers(os.environ["PROD_ROUTERS"])
leaked = sorted(
    n for n, r in prod.items()
    if "-dev" in n or re.search(r"Host\(`[^`]*-dev\.", r.get("rule", ""))
)
if leaked:
    print(f"  FAIL  the PROD router config routes dev hostname(s): {', '.join(leaked)}")
    print("        Dev has its own edge (SERV-93). A dev router on prod's Traefik needs")
    print("        prod's Traefik on construct_dev_net, which check 4 forbids.")
    fail = True
else:
    print(f"  ok    none of the {len(prod)} prod routers route a dev hostname")

# 1b. No dev router on a public entrypoint. The dev project has no `public`
# entrypoint at all (config/traefik-dev/traefik.yml), so such a router would serve
# nothing — but it would also be the first half of someone building dev a WAN path,
# and dev exists to run untested code.
dev = routers(os.environ["DEV_ROUTERS"])
public = sorted(n for n, r in dev.items() if "public" in (r.get("entryPoints") or []))
if public:
    print(f"  FAIL  dev routers on a PUBLIC entrypoint: {', '.join(public)}")
    print("        Dev is reached through its tunnel or on loopback, never from the WAN.")
    fail = True
elif not dev:
    print("  ok    no dev routers defined")
else:
    print(f"  ok    {len(dev)} dev router(s), all internal-only")

sys.exit(1 if fail else 0)
PY
else
  echo "  SKIP  router config not found ($PROD_ROUTERS / $DEV_ROUTERS)"; SKIPPED=$((SKIPPED + 1))
fi

# --- 2 & 3 & 5 need the dev project running ----------------------------------
mapfile -t DEV_CONTAINERS < <(docker ps -a --filter "label=com.docker.compose.project=$DEV_PROJECT" --format '{{.Names}}' 2>/dev/null || true)
if [ "${#DEV_CONTAINERS[@]}" -eq 0 ]; then
  echo "  SKIP  dev project '$DEV_PROJECT' is not running — attachment, port and reachability checks need it up"
  SKIPPED=$((SKIPPED + 3))
else
  # --- 2. No dev container is on a prod network ------------------------------
  leaked=()
  for c in "${DEV_CONTAINERS[@]}"; do
    nets="$(docker inspect "$c" --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' 2>/dev/null || true)"
    for pn in "${PROD_NETS[@]}"; do
      case " $nets " in
        *" $pn "*) leaked+=("$c->$pn") ;;
      esac
    done
  done
  if [ "${#leaked[@]}" -gt 0 ]; then
    echo "  FAIL  dev containers attached to a prod network: ${leaked[*]}"
    echo "        Dev must have no route to prod. Nothing belongs on both sides."
    FAIL=1
  else
    echo "  ok    ${#DEV_CONTAINERS[@]} dev container(s), none on ${PROD_NETS[*]}"
  fi

  # --- 3. Published dev ports are loopback-only ------------------------------
  exposed=()
  for c in "${DEV_CONTAINERS[@]}"; do
    while read -r hostip; do
      [ -z "$hostip" ] && continue
      case "$hostip" in
        127.0.0.1|::1) ;;
        *) exposed+=("$c:$hostip") ;;
      esac
    done < <(docker inspect "$c" --format '{{range $p,$b := .NetworkSettings.Ports}}{{range $b}}{{.HostIp}}{{"\n"}}{{end}}{{end}}' 2>/dev/null || true)
  done
  if [ "${#exposed[@]}" -gt 0 ]; then
    echo "  FAIL  dev ports bound beyond loopback: ${exposed[*]}"
    echo "        Bind dev ports to 127.0.0.1 — dev is reached via its tunnel or loopback, not the LAN."
    FAIL=1
  else
    echo "  ok    all published dev ports are loopback-bound"
  fi
fi

# --- 4. Nothing foreign is attached to either dev network ---------------------
# Deliberately asks the NETWORK who is on it, rather than asking the dev project
# what it is attached to. Those are different questions, and only this one sees a
# prod container reaching into dev — the regression this repo has already made once,
# and the reason SERV-93 built dev a second edge instead of sharing prod's.
for net in "$DEV_NET" "$DEV_EDGE_NET"; do
  if ! docker network inspect "$net" >/dev/null 2>&1; then
    if [ "$net" = "$DEV_EDGE_NET" ]; then
      # Compose-managed and only created when the `edge` profile is on, so its
      # absence is the ordinary state of a dev root with no tunnel token.
      echo "  ok    network '$net' does not exist — the dev edge is not deployed"
    else
      echo "  SKIP  network '$net' does not exist — run: make dev-network"
      SKIPPED=$((SKIPPED + 1))
    fi
    continue
  fi
  foreign=()
  while read -r cname; do
    [ -z "$cname" ] && continue
    proj="$(docker inspect "$cname" --format '{{index .Config.Labels "com.docker.compose.project"}}' 2>/dev/null || true)"
    [ "$proj" = "$DEV_PROJECT" ] || foreign+=("$cname(project=${proj:-none})")
  done < <(docker network inspect "$net" --format '{{range .Containers}}{{.Name}}{{"\n"}}{{end}}' 2>/dev/null || true)
  if [ "${#foreign[@]}" -gt 0 ]; then
    echo "  FAIL  non-dev containers attached to $net: ${foreign[*]}"
    echo "        Anything on both sides is the design SERV-93 rejected: it trades a"
    echo "        property that holds structurally for one that holds only while a"
    echo "        middleware is correctly attached everywhere. Give dev its own, or"
    echo "        route it through traefik-dev."
    FAIL=1
  else
    echo "  ok    nothing outside '$DEV_PROJECT' is attached to $net"
  fi
done

# --- 5. REACHABILITY: prod's edge does not answer from the dev network --------
# The one check that asks rather than infers. Everything above is about topology;
# this runs the original SERV-77 exploit — a spoofed Host at the prod internal
# entrypoint — from where a dev container stands, and asserts nothing answers.
if [ "${#DEV_CONTAINERS[@]}" -gt 0 ] && docker network inspect "$DEV_NET" >/dev/null 2>&1; then
  # The probe image is whatever postgres-dev is already running: it is guaranteed to
  # be present (no pull, no registry credential, works offline), it is Alpine, and
  # busybox wget is all this needs. Deriving it beats hard-coding a digest that would
  # silently rot out of step with the compose file.
  PROBE_IMAGE="$(docker inspect -f '{{.Config.Image}}' postgres-dev 2>/dev/null || true)"
  # The prod entrypoint's real bind address, read from the prod static config rather
  # than restated here — restating it is how a probe ends up aimed at an address
  # nothing has listened on for months, passing forever.
  PROD_EDGE_ADDR="$(PROD_STATIC="$PROD_STATIC" python3 -c '
import os, yaml
s = yaml.safe_load(open(os.environ["PROD_STATIC"])) or {}
print(((s.get("entryPoints") or {}).get("internal") or {}).get("address", ""))
' 2>/dev/null || true)"

  if [ -z "$PROBE_IMAGE" ] || [ -z "$PROD_EDGE_ADDR" ]; then
    echo "  SKIP  cannot run the reachability probe (image='${PROBE_IMAGE:-?}' prod-edge='${PROD_EDGE_ADDR:-?}')"
    SKIPPED=$((SKIPPED + 1))
  else
    # Classifies one attempt into exactly one of: an HTTP response (with its code),
    # a name that did not resolve, or no route at all. `bad address` and a timeout
    # are both passes HERE — the property is that dev cannot reach prod — which is
    # the opposite of check-edge-auth.sh, where a failure to connect must never read
    # as a pass. Different question, opposite polarity, stated so nobody copies one
    # into the other.
    probe() {  # probe <url> [host-header]
      local url="$1" host="${2:-}" out
      out="$(docker run --rm --network "$DEV_NET" --entrypoint sh "$PROBE_IMAGE" -c \
        "wget -q -S -O /dev/null --timeout=4 ${host:+--header 'Host: $host'} '$url' 2>&1" 2>&1 || true)"
      if printf '%s' "$out" | grep -qi 'HTTP/'; then
        printf 'http %s\n' "$(printf '%s' "$out" | grep -oiE 'HTTP/[0-9.]+ [0-9]{3}' | head -1 | awk '{print $2}')"
      elif printf '%s' "$out" | grep -qi 'bad address'; then
        printf 'nxdomain\n'
      else
        printf 'noroute\n'
      fi
    }

    # Positive control first. Without it, every negative below is unfalsifiable.
    # Several candidates because any one of them may legitimately be down; the
    # control only has to prove the PROBE works, not that dev is healthy — which is
    # make dev-health-check's job, not this script's.
    #
    # It sends the SAME spoofed Host header the negative probes send, against a dev
    # backend that does not vhost and will serve it regardless. That is deliberate:
    # the control has to exercise every part of the probe the negatives rely on,
    # header quoting included. A control that skipped the header would keep passing
    # while a broken --header made every negative report "no route", which is the
    # precise shape of a check that silently stops checking.
    control=""
    for candidate in "switchyard-frontend-dev:4002" "argosy-dev:8096" "lyceum-dev:4005"; do
      case "$(probe "http://$candidate/" "switchyard.zerogravity.industries")" in
        http*) control="$candidate"; break ;;
      esac
    done
    if [ -z "$control" ]; then
      echo "  SKIP  the probe reached no dev backend, so it cannot prove prod is unreachable"
      echo "        (that is a broken probe or a down dev tier, not evidence of isolation)"
      SKIPPED=$((SKIPPED + 1))
    else
      echo "  ok    probe control: reached $control from $DEV_NET, so the probe works"
      # Two angles, because they fail differently: by ADDRESS (is there a route to
      # the prod edge network?) and by NAME (can dev even resolve a prod service?).
      for target in \
        "$PROD_EDGE_ADDR|switchyard.zerogravity.industries|prod switchyard via the prod edge address" \
        "$PROD_EDGE_ADDR|lyceum.zerogravity.industries|prod lyceum via the prod edge address" \
        "traefik:9080||the prod Traefik by name" \
        "postgres:5432||the prod Postgres by name"
      do
        IFS='|' read -r hostport hdr label <<< "$target"
        verdict="$(probe "http://$hostport/" "$hdr")"
        case "$verdict" in
          nxdomain) echo "  ok    $label — name does not resolve from $DEV_NET" ;;
          noroute)  echo "  ok    $label — no route from $DEV_NET" ;;
          http*)
            echo "  FAIL  $label — ANSWERED from $DEV_NET (${verdict#http })"
            echo "        A container on the dev network reached prod's HTTP tier. That is the"
            echo "        exact finding SERV-93 exists to keep closed; check what is attached to"
            echo "        both networks (check 4 above) before anything else."
            FAIL=1 ;;
        esac
      done
    fi
  fi
fi

echo
if [ "$FAIL" -eq 1 ]; then
  err "DEV ISOLATION VIOLATED — see the failures above."
  exit 1
fi
if [ "$SKIPPED" -gt 0 ]; then
  # Never print the unqualified success line when a property went untested. This
  # script is cited as the thing that asserts isolation, so a green line standing
  # for "parsed a YAML file and skipped the rest" is worse than no line at all.
  echo "PARTIAL — $SKIPPED isolation propert(y/ies) NOT checked; bring dev up and re-run."
  exit 0
fi
echo "Dev isolation holds (all properties checked)."
exit 0
