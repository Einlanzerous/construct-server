#!/usr/bin/env bash
# delivery-facts.sh — what the first-party containers are ACTUALLY running,
# in a shape a machine can read (SERV-117).
#
# The sibling of report-versions.sh, and deliberately not a flag on it.
# report-versions.sh is a report for a human: it truncates the digest to 19
# characters and the revision to 12 so the columns line up. Those are exactly
# the two fields the delivery ledger stores whole, so a `--json` mode there
# would have had to either stop truncating (breaking the table it exists to
# print) or emit values that look like identifiers and are not.
#
# ── Why the LABEL and not the pin ─────────────────────────────────────────
#
# `versions.env` pins major.minor — `SWITCHYARD_TAG=4.13`. The container behind
# that pin is running 4.13.1. Reporting the pin would put `4.13` in the ledger
# while the reconciler's probe of /healthz observes `4.13.1`, and the matrix
# compares those two as identities: a permanent "claimed, not confirmed" on a
# service that is running exactly what it should be. The false-alarm failure the
# whole two-producer split exists to avoid, manufactured by the producer.
#
# `org.opencontainers.image.version` is set by docker/metadata-action from the
# release tag and agrees with /healthz character for character — verified on
# prod switchyard: label 4.13.1, /healthz 4.13.1, and the revision label equals
# the sha /healthz reports. So a report built from the label and an observation
# built from the endpoint produce the same identity, which is the property that
# keeps the two producers agreeing when they should.
#
# An image with no version label (a `build:` service, or a third-party image)
# yields an EMPTY version, not a guess. That is a legitimate row: the ledger
# records the digest and shows the version as unknown. Third-party images are
# tier B's business (SERV-115) and are filtered out here.
#
# Usage:
#   ./scripts/delivery-facts.sh [service ...]     # compose service names
#
# Emits one TAB-separated line per first-party container:
#   <container_name>\t<version>\t<digest>\t<revision>
#
# Exit codes:
#   0  reported (possibly zero lines — no first-party container in scope)
#   2  usage / missing dependency / no deploy root

set -euo pipefail

DEPLOY_ROOT="${DEPLOY_ROOT:-/opt/construct-server}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
COMPOSE_PROJECT="${COMPOSE_PROJECT:-}"

# What counts as ours. Kept as a prefix rather than a service list so a new
# first-party service is included the day it is added to the compose file.
FIRST_PARTY_PREFIX="${FIRST_PARTY_PREFIX:-ghcr.io/einlanzerous/}"

err() { printf '%s\n' "$*" >&2; }

case "${1:-}" in
  -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
  -*) err "ERROR: unknown option '$1'"; exit 2 ;;
esac

command -v docker >/dev/null 2>&1 || { err "ERROR: required dependency 'docker' not found in PATH"; exit 2; }

if [ ! -f "$DEPLOY_ROOT/$COMPOSE_FILE" ]; then
  err "ERROR: no $COMPOSE_FILE at DEPLOY_ROOT=$DEPLOY_ROOT"
  exit 2
fi

cd "$DEPLOY_ROOT"

compose() { docker compose -f "$COMPOSE_FILE" ${COMPOSE_PROJECT:+-p "$COMPOSE_PROJECT"} "$@"; }

# `-a` for the same reason report-versions.sh uses it: a service that crashed on
# boot is the one most worth naming, and `ps -q` omits it entirely.
if [ $# -gt 0 ]; then
  container_ids="$(compose ps -aq "$@" 2>/dev/null || true)"
else
  container_ids="$(compose ps -aq 2>/dev/null || true)"
fi

[ -n "$container_ids" ] || exit 0

for cid in $container_ids; do
  ref="$(docker inspect -f '{{.Config.Image}}' "$cid" 2>/dev/null || true)"
  case "$ref" in
    "${FIRST_PARTY_PREFIX}"*) : ;;
    *) continue ;;
  esac

  name="$(docker inspect -f '{{.Name}}' "$cid")"; name="${name#/}"
  imgid="$(docker inspect -f '{{.Image}}' "$cid")"

  label() {
    local v
    v="$(docker image inspect "$imgid" --format "{{index .Config.Labels \"$1\"}}" 2>/dev/null || true)"
    # `<no value>` is what Go's template prints for a missing key. Passing that
    # string through as a version would put the literal text "<no value>" on the
    # matrix where a version belongs.
    [ "$v" = "<no value>" ] && v=""
    printf '%s' "$v"
  }

  version="$(label org.opencontainers.image.version)"
  revision="$(label org.opencontainers.image.revision)"

  # Same RepoDigests care as report-versions.sh: one image id can be tagged from
  # several repositories, so match this container's repo rather than taking the
  # first, or a service gets reported under an unrelated repo's digest.
  repo="${ref%%@*}"; repo="${repo%:*}"
  digest="$(docker image inspect "$imgid" \
    --format '{{range .RepoDigests}}{{println .}}{{end}}' 2>/dev/null \
    | awk -F@ -v r="$repo" '$1 == r { print $2; exit }')"

  printf '%s\t%s\t%s\t%s\n' "$name" "$version" "$digest" "$revision"
done
