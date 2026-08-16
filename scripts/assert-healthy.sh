#!/usr/bin/env bash
# assert-healthy.sh — Fail if any container in the stack is unhealthy
#
# Docker computes health and then does nothing with it. `restart: unless-stopped`
# restarts EXITED containers, not unhealthy ones, so a container can sit failing its
# healthcheck forever with no consequence. That is not hypothetical: on 2026-08-15
# switchyard was unhealthy at a failing streak of 12 — the signal existed, was correct,
# and reached nothing (SERV-102). This script is what it reaches.
#
# Deliberately DETECTION, not recovery. It runs after `up -d`, so by the time it fails
# the deploy has already happened and nothing here rolls anything back; what it buys is
# that the deploy goes red and says which service, instead of going green over a broken
# stack. Automatic recovery is the post-deploy smoke + auto-rollback in
# docs/delivery-pipeline.md (SERV-79); this is the check that step will call.
#
# Containers with no healthcheck are reported but never fail the run — the stack has
# plenty (postgres among them) and their absence is a separate gap, not a deploy error.
# The listing is there because a service silently having no healthcheck is exactly how
# interlock-worker stayed invisibly dead for an hour.
#
# Usage:
#   ./scripts/assert-healthy.sh [--timeout SECONDS] [--warn-only] [service ...]
#     no services  — check every running container in the project
#     --timeout    — how long to wait for `starting` containers to settle (default 300)
#     --warn-only  — report exactly as normal but always exit 0
#
# Exit codes:
#   0  nothing unhealthy (or --warn-only)
#   1  at least one container is unhealthy
#   2  usage / missing dependency / no deploy root

set -euo pipefail

# Same fixed path as the rest of the tooling (SERV-76): the answer must not depend on
# which checkout invoked this. See check-compose-drift.sh for the full reasoning.
DEPLOY_ROOT="${DEPLOY_ROOT:-/opt/construct-server}"

TIMEOUT=300
WARN_ONLY=0
services=()

err() { printf '%s\n' "$*" >&2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --timeout)
      [ $# -ge 2 ] || { err "ERROR: --timeout needs a value"; exit 2; }
      TIMEOUT="$2"
      case "$TIMEOUT" in (*[!0-9]*|'') err "ERROR: --timeout must be a whole number of seconds, got '$TIMEOUT'"; exit 2 ;; esac
      shift 2
      ;;
    --warn-only) WARN_ONLY=1; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    -*) err "ERROR: unknown option '$1'"; exit 2 ;;
    *) services+=("$1"); shift ;;
  esac
done

command -v docker >/dev/null 2>&1 || { err "ERROR: required dependency 'docker' not found in PATH"; exit 2; }

if [ ! -f "$DEPLOY_ROOT/docker-compose.yml" ]; then
  err "ERROR: no docker-compose.yml at DEPLOY_ROOT=$DEPLOY_ROOT"
  err "The stack deploys from a fixed path (SERV-76). Point this elsewhere with"
  err "  DEPLOY_ROOT=/path/to/root $0"
  exit 2
fi

cd "$DEPLOY_ROOT"

ids() {
  if [ ${#services[@]} -gt 0 ]; then
    docker compose ps -q "${services[@]}"
  else
    docker compose ps -q
  fi
}

# `{{if .State.Health}}` distinguishes "no healthcheck declared" from a health status —
# without it every container without one reads as an empty string alongside real results.
#
# Do NOT add `{{.Id}}` here to carry the id along. `Id` is not a field on the struct
# docker renders (it is `ID`), and referencing it silently drops the whole template into
# raw-map mode, where `.State.Health` on a container that has no healthcheck stops
# meaning "absent" and starts being a hard error. The visible effect is subtle and bad:
# every container without a healthcheck fails to render, so they vanish from the tally
# instead of being listed, and the script reports "no healthcheck: 0" over a stack with
# eighteen of them. The id is already in hand from the loop below — pair it there.
inspect_fmt='{{.Name}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}'

# Emit "<id> <name> <status>" per container, taking the id from the loop rather than the
# template for the reason above.
statuses() {
  local cid
  for cid in $container_ids; do
    printf '%s %s\n' "$cid" "$(docker inspect -f "$inspect_fmt" "$cid")"
  done
}

container_ids="$(ids)" || { err "ERROR: 'docker compose ps' failed — is the daemon up and the project deployed?"; exit 2; }
if [ -z "$container_ids" ]; then
  err "ERROR: no running containers found in $DEPLOY_ROOT"
  err "Nothing to assert on. If this ran straight after 'up -d', the stack failed to start."
  exit 2
fi

# Wait out `starting`. A container inside its start_period is not yet a verdict, and
# failing on one would just be a race against whichever healthcheck has the longest
# grace. Docker flips `starting` to `unhealthy` on its own once start_period elapses,
# so this only ever waits for an answer — it cannot mask one.
deadline=$(( $(date +%s) + TIMEOUT ))
while :; do
  starting=""
  while read -r _id name status; do
    [ "$status" = "starting" ] && starting="$starting ${name#/}"
  done <<< "$(statuses)"

  [ -z "$starting" ] && break
  if [ "$(date +%s)" -ge "$deadline" ]; then
    printf 'Still starting after %ss, reporting on current state:%s\n\n' "$TIMEOUT" "$starting"
    break
  fi
  sleep 10
done

healthy=""; unhealthy=""; nocheck=""; starting=""
declare -A unhealthy_id=()
while read -r id name status; do
  name="${name#/}"
  case "$status" in
    healthy)   healthy="$healthy $name" ;;
    unhealthy) unhealthy="$unhealthy $name"; unhealthy_id["$name"]="$id" ;;
    starting)  starting="$starting $name" ;;
    none)      nocheck="$nocheck $name" ;;
  esac
done <<< "$(statuses)"

count() { printf '%s' "$1" | wc -w | tr -d ' '; }

printf 'healthy: %s   unhealthy: %s   starting: %s   no healthcheck: %s\n' \
  "$(count "$healthy")" "$(count "$unhealthy")" "$(count "$starting")" "$(count "$nocheck")"

if [ -n "$nocheck" ]; then
  printf '\nNo healthcheck declared (not an error, but these cannot be seen to fail):\n'
  for n in $nocheck; do printf '  - %s\n' "$n"; done
fi

if [ -n "$unhealthy" ]; then
  printf '\nUNHEALTHY:\n'
  for n in $unhealthy; do
    printf '  - %s\n' "$n"
    # The probe's own output is almost always the whole diagnosis, and it is otherwise
    # buried in `docker inspect` on a box nobody is logged into at the time. Docker keeps
    # the last five entries, so ranging the whole log and tailing it lands on the most
    # recent failures. Indexing the last entry directly would be tidier but needs a `sub`
    # function that docker's template engine does not define.
    docker inspect -f '{{range .State.Health.Log}}{{.Output}}{{end}}' \
      "${unhealthy_id[$n]}" 2>/dev/null | tail -5 | sed 's/^/      /' || true
  done
  printf '\nA healthy stack is the deploy'"'"'s postcondition, so this is a failed deploy even\n'
  printf 'though `up -d` succeeded. Investigate with:\n'
  printf '  docker logs <name> --tail 50\n'
  printf '  make force-recreate svc=<name>   # --no-deps is baked in (SERV-63)\n'
  [ "$WARN_ONLY" -eq 1 ] && { printf '\n(--warn-only: not failing)\n'; exit 0; }
  exit 1
fi

printf '\nNothing unhealthy.\n'
exit 0
