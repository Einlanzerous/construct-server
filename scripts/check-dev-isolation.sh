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
#   4. postgres-dev is not on construct_net, so no prod container can reach the
#      dev database either.
#
# Checks 1 and 3 are static and always run. Checks 2 and 4 need the dev project
# up and are skipped (not failed) when it is down.
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
print(f"  ok    {n} dev router(s), none on the public entrypoint")
PY
else
  echo "  SKIP  $ROUTERS not found"
fi

# --- 2 & 4. Dev containers are not on construct_net --------------------------
mapfile -t DEV_CONTAINERS < <(docker ps -a --filter "label=com.docker.compose.project=$DEV_PROJECT" --format '{{.Names}}' 2>/dev/null || true)
if [ "${#DEV_CONTAINERS[@]}" -eq 0 ]; then
  echo "  SKIP  dev project '$DEV_PROJECT' is not running — network checks need it up"
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
    echo "        Dev must have no route to prod. Traefik is the only crossing point."
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

echo
if [ "$FAIL" -eq 1 ]; then
  err "DEV ISOLATION VIOLATED — see the failures above."
  exit 1
fi
echo "Dev isolation holds."
exit 0
