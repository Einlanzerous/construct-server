#!/usr/bin/env bash
# check-compose-drift.sh — Detect containers running a stale spec vs docker-compose.yml
#
# Guardrail for the SERV-8 /media-ssd drift incident (2026-06-29): a `docker restart`
# (instead of `docker compose up -d <svc>`) silently keeps a container's OLD config, so
# mounts/env/image edits in docker-compose.yml never take effect. This script compares
# each running service's LIVE mounts (docker inspect) against the mounts DECLARED in the
# resolved compose file (docker compose config) and flags any drift.
#
# A missing or changed mount means the container needs to be RECREATED:
#     docker compose up -d <service>     # never `docker restart <service>`
#
# Usage:
#   ./scripts/check-compose-drift.sh [service ...]
#     no args  — check every service defined in the compose file
#     service  — check only the named service(s)
#
# Exit codes:
#   0  no drift (extra anonymous image volumes are reported as warnings only)
#   1  drift detected (a declared mount is missing/changed, or a stale bind lingers)
#   2  usage / missing dependency error

set -euo pipefail

# Resolve repo root from this script's location so compose finds docker-compose.yml
# regardless of the caller's working directory.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd)"

err() { printf '%s\n' "$*" >&2; }

# Strip a single trailing slash (so "/proc/" and "/proc" compare equal), but keep "/".
norm_path() { local p="$1"; [ "$p" != "/" ] && p="${p%/}"; printf '%s' "$p"; }

for dep in docker jq; do
  command -v "$dep" >/dev/null 2>&1 || { err "ERROR: required dependency '$dep' not found in PATH"; exit 2; }
done

cd "$REPO_ROOT"

# Resolved compose config (env-substituted, short syntax normalized to long form).
COMPOSE_JSON="$(docker compose config --format json 2>/dev/null)" || {
  err "ERROR: 'docker compose config' failed — is docker-compose.yml valid and is the daemon up?"
  exit 2
}

# Which services to check.
if [ "$#" -gt 0 ]; then
  SERVICES=("$@")
else
  mapfile -t SERVICES < <(printf '%s' "$COMPOSE_JSON" | jq -r '.services | keys[]')
fi

# Normalize a service's DECLARED mounts from the compose config into
# `target<TAB>type<TAB>source<TAB>ro|rw` lines. Volume sources are dropped from the
# key because docker prefixes named volumes with the project name at runtime.
declared_mounts() {
  local svc="$1"
  printf '%s' "$COMPOSE_JSON" | jq -r --arg svc "$svc" '
    .services[$svc].volumes // [] | .[] |
    select(.target != null) |
    if .type == "bind" then
      [.target, "bind", (.source // ""), (if .read_only then "ro" else "rw" end)]
    elif .type == "volume" then
      [.target, "volume", "", (if .read_only then "ro" else "rw" end)]
    else
      [.target, .type, (.source // ""), "rw"]
    end | @tsv'
}

# Normalize a container's LIVE mounts from docker inspect into the same shape.
live_mounts() {
  local cid="$1"
  docker inspect "$cid" 2>/dev/null | jq -r '
    .[0].Mounts // [] | .[] |
    if .Type == "bind" then
      [.Destination, "bind", .Source, (if .RW then "rw" else "ro" end)]
    elif .Type == "volume" then
      [.Destination, "volume", "", (if .RW then "rw" else "ro" end)]
    else
      [.Destination, .Type, (.Source // ""), (if .RW then "rw" else "ro" end)]
    end | @tsv'
}

DRIFT=0          # set to 1 if any hard drift is found (controls exit code)
CHECKED=0

for svc in "${SERVICES[@]}"; do
  # Confirm the service exists in the compose file.
  if ! printf '%s' "$COMPOSE_JSON" | jq -e --arg svc "$svc" '.services | has($svc)' >/dev/null; then
    err "WARN: '$svc' is not defined in docker-compose.yml — skipping"
    continue
  fi

  cid="$(docker compose ps -q "$svc" 2>/dev/null || true)"
  if [ -z "$cid" ]; then
    printf '• %-16s SKIP — not running\n' "$svc"
    continue
  fi

  CHECKED=$((CHECKED + 1))

  # Build target-keyed maps for declared and live mounts. Value = "type|source|ro".
  declare -A DECL=() LIVE=()
  while IFS=$'\t' read -r target type source ro; do
    [ -n "$target" ] && DECL["$(norm_path "$target")"]="$type|$(norm_path "$source")|$ro"
  done < <(declared_mounts "$svc")
  while IFS=$'\t' read -r target type source ro; do
    [ -n "$target" ] && LIVE["$(norm_path "$target")"]="$type|$(norm_path "$source")|$ro"
  done < <(live_mounts "$cid")

  svc_findings=()

  # Declared mounts vs the live container, keyed by target (the container path).
  for target in "${!DECL[@]}"; do
    if [ -z "${LIVE[$target]+x}" ]; then
      # Missing target — the SERV-8 incident signature (e.g. /media-ssd absent).
      svc_findings+=("DRIFT  missing mount: $target (declared: ${DECL[$target]})")
      DRIFT=1
      continue
    fi
    IFS='|' read -r d_type d_source d_ro <<<"${DECL[$target]}"
    IFS='|' read -r l_type l_source l_ro <<<"${LIVE[$target]}"
    # type (bind vs volume) and read-only flag are environment-independent — hard drift.
    if [ "$d_type" != "$l_type" ]; then
      svc_findings+=("DRIFT  type mismatch: $target (declared: $d_type | live: $l_type)")
      DRIFT=1
    fi
    if [ "$d_ro" != "$l_ro" ]; then
      svc_findings+=("DRIFT  read-only flag mismatch: $target (declared: $d_ro | live: $l_ro)")
      DRIFT=1
    fi
    # bind source differences are often just deploy-directory / path-normalization
    # quirks (e.g. CI-runner checkout vs local clone), so surface them as warnings.
    if [ "$d_type" = "bind" ] && [ "$l_type" = "bind" ] && [ "$d_source" != "$l_source" ]; then
      svc_findings+=("warn   bind source differs: $target (declared: $d_source | live: $l_source)")
    fi
  done

  # Live mounts not in the compose file. A lingering BIND is real drift (compose
  # removed it but the container kept it); an extra named/anonymous VOLUME is almost
  # always an image-declared anonymous volume, so treat it as a warning only.
  for target in "${!LIVE[@]}"; do
    if [ -z "${DECL[$target]+x}" ]; then
      live_type="${LIVE[$target]%%|*}"
      if [ "$live_type" = "bind" ]; then
        svc_findings+=("DRIFT  stale bind not in compose: $target (live: ${LIVE[$target]})")
        DRIFT=1
      else
        svc_findings+=("warn   extra volume not in compose: $target (live: ${LIVE[$target]})")
      fi
    fi
  done

  if [ "${#svc_findings[@]}" -eq 0 ]; then
    printf '• %-16s OK\n' "$svc"
  else
    printf '• %-16s %d finding(s)\n' "$svc" "${#svc_findings[@]}"
    for f in "${svc_findings[@]}"; do
      printf '    %s\n' "$f"
    done
  fi

  unset DECL LIVE
done

echo
if [ "$DRIFT" -eq 1 ]; then
  err "DRIFT DETECTED — recreate the affected service(s): docker compose up -d <service>"
  err "(never 'docker restart <service>' after a compose edit — it keeps the old spec)"
  exit 1
fi

printf 'No drift across %d running service(s).\n' "$CHECKED"
exit 0
