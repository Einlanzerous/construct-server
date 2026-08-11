#!/usr/bin/env bash
# check-dev-isolation.sh — Assert the dev environment cannot reach prod, and the
# WAN cannot reach dev (SERV-77).
#
# SERV-77's stated validation is that for dev, "the check is that the public path
# FAILS". That is a claim about four separate things, and each is checked here
# rather than assumed:
#
#   1. No dev host is routed on Traefik's `public` entrypoint.
#   2. Dev containers are not attached to construct_net, so they have no route to
#      any prod service — including the prod Postgres.
#   3. Every published dev port is bound to loopback, never 0.0.0.0.
#   4. NOTHING from outside the dev project is attached to construct_dev_net.
#
# Check 4 is the one that matters most and was missing until review caught it.
# Checks 2 and 3 are dev-side: they enumerate containers labelled with the dev
# project and ask what networks they are on. The regression this repo has already
# made once is the mirror image — a PROD container (Traefik) joining the DEV
# network — and that container is outside the dev-project filter, so every
# dev-side check passes while an unauthenticated route into prod's HTTP tier is
# live. Check 4 looks at the network's membership instead of the project's, which
# is the only angle that sees it.
#
# Checks 1 and 4 need only the network and the config, so they run whether or not
# the dev project is up. Checks 2 and 3 need running dev containers and are
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
ROUTERS="$REPO_ROOT/config/traefik/dynamic/routers.yml"

err() { printf '%s\n' "$*" >&2; }
for dep in docker python3; do
  command -v "$dep" >/dev/null 2>&1 || { err "ERROR: required dependency '$dep' not found in PATH"; exit 2; }
done

FAIL=0
SKIPPED=0

# --- 1. No dev router on the public entrypoint -------------------------------
# Parsed structurally rather than grepped: a grep for "public" near "dev" would
# both miss a reordering and fire on a comment.
if [ -f "$ROUTERS" ]; then
  ROUTERS="$ROUTERS" python3 <<'PY' || FAIL=1
import os, sys, yaml
routers = (yaml.safe_load(open(os.environ["ROUTERS"])) or {}).get("http", {}).get("routers", {}) or {}
bad = [
    name for name, r in routers.items()
    if "dev" in name and "public" in (r.get("entryPoints") or [])
]
if bad:
    print(f"  FAIL  dev routers on the PUBLIC entrypoint: {', '.join(bad)}")
    sys.exit(1)
n = sum(1 for name in routers if "dev" in name)
if n == 0:
    # Vacuously true today: SERV-77 shipped no dev routers, because the network
    # path they needed was the one that had to be removed. SERV-93 adds them back.
    print("  ok    no dev routers defined yet (vacuous until SERV-93)")
else:
    print(f"  ok    {n} dev router(s), none on the public entrypoint")
PY
else
  echo "  SKIP  $ROUTERS not found"; SKIPPED=$((SKIPPED + 1))
fi

# --- 2 & 4. Dev containers are not on construct_net --------------------------
mapfile -t DEV_CONTAINERS < <(docker ps -a --filter "label=com.docker.compose.project=$DEV_PROJECT" --format '{{.Names}}' 2>/dev/null || true)
if [ "${#DEV_CONTAINERS[@]}" -eq 0 ]; then
  echo "  SKIP  dev project '$DEV_PROJECT' is not running — network checks need it up"
  SKIPPED=$((SKIPPED + 2))  # the attachment check and the port check
else
  leaked=()
  for c in "${DEV_CONTAINERS[@]}"; do
    nets="$(docker inspect "$c" --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' 2>/dev/null || true)"
    case " $nets " in
      *" construct_net "*) leaked+=("$c") ;;
    esac
  done
  if [ "${#leaked[@]}" -gt 0 ]; then
    echo "  FAIL  dev containers attached to construct_net: ${leaked[*]}"
    echo "        Dev must have no route to prod. Nothing belongs on both networks."
    FAIL=1
  else
    echo "  ok    ${#DEV_CONTAINERS[@]} dev container(s), none on construct_net"
  fi
fi

# --- 3. Published dev ports are loopback-only --------------------------------
if [ "${#DEV_CONTAINERS[@]}" -gt 0 ]; then
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
    echo "        Bind dev ports to 127.0.0.1 — dev is reached via the tunnel or loopback, not the LAN."
    FAIL=1
  else
    echo "  ok    all published dev ports are loopback-bound"
  fi
fi

# --- 4. Nothing foreign is attached to the dev network ----------------------
# Deliberately asks the NETWORK who is on it, rather than asking the dev project
# what it is attached to. Those are different questions, and only this one sees a
# prod container reaching into dev.
DEV_NET="${DEV_NET:-construct_dev_net}"
if ! docker network inspect "$DEV_NET" >/dev/null 2>&1; then
  echo "  SKIP  network '$DEV_NET' does not exist — run: make dev-network"
  SKIPPED=$((SKIPPED + 1))
else
  foreign=()
  while read -r cname; do
    [ -z "$cname" ] && continue
    proj="$(docker inspect "$cname" --format '{{index .Config.Labels "com.docker.compose.project"}}' 2>/dev/null || true)"
    [ "$proj" = "$DEV_PROJECT" ] || foreign+=("$cname(project=${proj:-none})")
  done < <(docker network inspect "$DEV_NET" --format '{{range .Containers}}{{.Name}}{{"\n"}}{{end}}' 2>/dev/null || true)
  if [ "${#foreign[@]}" -gt 0 ]; then
    echo "  FAIL  non-dev containers attached to $DEV_NET: ${foreign[*]}"
    echo "        Anything on both networks reopens the route dev must not have:"
    echo "        Traefik's internal entrypoint has no source restriction and the"
    echo "        prod routers on it have no auth middleware (SERV-25). See SERV-93."
    FAIL=1
  else
    echo "  ok    nothing outside '$DEV_PROJECT' is attached to $DEV_NET"
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
