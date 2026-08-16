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

# --all, NOT the default. `docker compose ps -q` lists only RUNNING containers, so a
# container that crashed and exited is simply absent from it — and absent reads as fine.
# Verified: with a service dead in `exited`, the running-only form reported "nothing
# unhealthy" and exited 0. A service that fails to start at all is the most basic deploy
# failure there is, and it was the one case this could not see.
ids() {
  if [ ${#services[@]} -gt 0 ]; then
    docker compose ps -aq "${services[@]}"
  else
    docker compose ps -aq
  fi
}

# Two different questions, and both have to be asked: `.State.Status` is whether the
# container is running at all, `.State.Health` is whether the process inside it works. A
# check that asks only the second misses a crash; one that asks only the first misses the
# SERV-102 case, where every container was up and two of them were dead.
#
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
#
# FailingStreak and the probe timestamps are carried because a health STATUS on its own
# is a stale answer — see the wait loop for what that costs.
inspect_fmt='{{.Name}} {{.State.Status}} {{if .State.Health}}{{.State.Health.Status}} {{.State.Health.FailingStreak}}{{range .State.Health.Log}} {{.End.Unix}}{{end}}{{else}}none 0 0{{end}}'

# Emit "<id> <name> <state> <health> <streak> <probe-epochs…>" per container, taking the
# id from the loop rather than the template for the reason above.
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

# Wait for a verdict that is actually about the deploy that just happened.
#
# The obvious version of this — read every container's health status once and pass if
# none says `unhealthy` — is wrong in the exact way SERV-102 was missed. A status is
# only as fresh as the last probe, and probes run on their own interval (30-60s here).
# Immediately after `up -d` recreates postgres, switchyard still reports `healthy` from a
# probe that ran before postgres moved. The gate would go green, and switchyard would
# flip to unhealthy a minute later with the deploy already reported successful. That is
# the ticket's own "the signal existed and reached nothing", reproduced inside the thing
# built to fix it.
#
# So three separate conditions mean "no verdict yet", and all three are waited out:
#
#   starting / restarting   inside start_period, or coming up after its database. Normal
#                           for a few seconds on a cold deploy.
#   stale                   the last probe finished BEFORE this script started, so its
#                           verdict predates the deploy and says nothing about it.
#   healthy + streak > 0    currently failing but has not yet hit `retries`. Docker will
#                           resolve this either way shortly; passing now would be calling
#                           it early, in the direction of a false green.
#
# Docker moves every one of these to a settled state on its own, so this only ever waits
# for an answer — with one honest exception: amber declares `start_period: 15m`, which is
# longer than the default timeout, so a cold amber can still be `starting` at the
# deadline. That is reported rather than failed, and is why the loop reports what it was
# still waiting on instead of claiming everything settled.
script_start="$(date +%s)"
deadline=$(( script_start + TIMEOUT ))
while :; do
  waiting=""
  while read -r _id name state health streak probes; do
    name="${name#/}"
    last_probe="${probes##* }"
    case "${last_probe}" in (*[!0-9]*|'') last_probe=0 ;; esac
    if [ "$state" = "restarting" ] || [ "$health" = "starting" ]; then
      waiting="$waiting $name"
    elif [ "$health" != "none" ] && [ "$state" = "running" ]; then
      if [ "$last_probe" -lt "$script_start" ]; then
        waiting="$waiting $name(stale)"
      elif [ "$health" = "healthy" ] && [ "${streak:-0}" -gt 0 ]; then
        waiting="$waiting $name(failing)"
      fi
    fi
  done <<< "$(statuses)"

  [ -z "$waiting" ] && break
  if [ "$(date +%s)" -ge "$deadline" ]; then
    printf 'Gave up waiting after %ss on:%s\n' "$TIMEOUT" "$waiting"
    printf 'Reporting on current state — a `(stale)` entry means its healthcheck had not\n'
    printf 're-run yet, so its verdict may still change after this.\n\n'
    break
  fi
  sleep 10
done

healthy=""; unhealthy=""; nocheck=""; starting=""; down=""
declare -A unhealthy_id=()
declare -A down_state=()
while read -r id name state health streak probes; do
  name="${name#/}"
  # Not running beats any health verdict: an exited container has a stale health status
  # from before it died, and reporting that would be worse than saying nothing.
  if [ "$state" != "running" ]; then
    down="$down $name"; down_state["$name"]="$state"; unhealthy_id["$name"]="$id"
    continue
  fi
  case "$health" in
    healthy)   healthy="$healthy $name" ;;
    unhealthy) unhealthy="$unhealthy $name"; unhealthy_id["$name"]="$id" ;;
    starting)  starting="$starting $name" ;;
    none)      nocheck="$nocheck $name" ;;
  esac
done <<< "$(statuses)"

count() { printf '%s' "$1" | wc -w | tr -d ' '; }

printf 'healthy: %s   unhealthy: %s   not running: %s   starting: %s   no healthcheck: %s\n' \
  "$(count "$healthy")" "$(count "$unhealthy")" "$(count "$down")" \
  "$(count "$starting")" "$(count "$nocheck")"

if [ -n "$nocheck" ]; then
  printf '\nNo healthcheck declared (not an error, but these cannot be seen to fail):\n'
  for n in $nocheck; do printf '  - %s\n' "$n"; done
fi

if [ -n "$down" ]; then
  printf '\nNOT RUNNING:\n'
  for n in $down; do
    printf '  - %s (%s)\n' "$n" "${down_state[$n]}"
    docker logs "${unhealthy_id[$n]}" --tail 5 2>&1 | sed 's/^/      /' || true
  done
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
fi

if [ -n "$unhealthy" ] || [ -n "$down" ]; then
  printf '\nA working stack is the deploy'"'"'s postcondition, so this is a failed deploy even\n'
  printf 'though `up -d` succeeded. Investigate with:\n'
  printf '  docker logs <name> --tail 50\n'
  printf '  make force-recreate svc=<name>   # --no-deps is baked in (SERV-63)\n'
  [ "$WARN_ONLY" -eq 1 ] && { printf '\n(--warn-only: not failing)\n'; exit 0; }
  exit 1
fi

printf '\nEverything is running, and nothing is unhealthy.\n'
exit 0
