#!/usr/bin/env bash
# delivery-reportable.sh — which containers may honestly be REPORTED to the
# Switchyard ledger, and at what version (SERV-117).
#
# Wraps delivery-facts.sh with the two filters that keep the push producer from
# manufacturing false alarms. Emits `name=version` lines, which is exactly the
# `services:` input the report-deploy composite action takes.
#
# ── Filter 1: the ledger must already know the service ────────────────────
#
# The matrix flags a report with no corroborating observation as "claimed, not
# confirmed", and buckets that row as `attention` — red, with a banner. For a
# service that has NEVER been observed the flag is unconditional: there is no
# observation to compare against, so the row is red the moment it is reported
# and stays red for ever.
#
# Several first-party containers are in exactly that position. `switchyard-frontend`
# publishes no /healthz the reconciler can address, so nothing will ever confirm
# a claim about it. Reporting it would buy a run link and pay for it with a
# permanent red row on the one page whose entire job is to be believed.
#
# So this asks Switchyard which services it actually tracks (`GET /v1/services`,
# auth-only, no extra scope) and reports only those. It is the same rule the
# host-side prober applies with `resolveExistingTargets`: a producer must not be
# able to wedge a phantom row into the inventory by naming something wrong.
#
# It also means the list widens ON ITS OWN. As SWY-192's /healthz contract
# reaches another service and the reconciler starts observing it, that service
# becomes reportable with no edit here.
#
# ── Filter 2: `latest` is not a version ───────────────────────────────────
#
# argosy's publish workflow stamps `org.opencontainers.image.version=latest`
# because it cuts no semver. `latest` names a moving target, not a build; the
# ledger would store it as an identity, compare it against whatever /healthz
# says, and disagree for ever. Dropped to empty, which the ledger records as
# version-unknown — true, and not red.
#
# ── The name the LEDGER uses is not always the container's ────────────────
#
# Switchyard holds one `services` row per service and uses the environment as the
# other axis, so prod's `switchyard` and dev's `switchyard-dev` are the same
# service seen twice — the `-dev` suffix is a compose-project artefact, not part
# of the identity. `LEDGER_NAME_STRIP_SUFFIX=-dev` maps them back.
#
# Filter 1 is the backstop if that mapping is ever wrong: an unmapped name is
# simply skipped, so the worst case is a missing row rather than a phantom
# `switchyard-dev` service wedged into the inventory beside the real one.
#
# Usage:
#   SWITCHYARD_URL=http://localhost:4002 SWITCHYARD_TOKEN=sw_... \
#     ./scripts/delivery-reportable.sh [compose service ...]
#     ./scripts/delivery-reportable.sh --stdin < facts.tsv
#
#   --stdin  read delivery-facts.sh output instead of invoking it, for a caller
#            that has already narrowed the set (deploy-dev.yml reports only the
#            containers whose image actually moved).
#
# Exit codes:
#   0  emitted zero or more `name=version` lines
#   2  usage / missing dependency / could not reach Switchyard
#
# Reaching Switchyard is a HARD failure here and a soft one in the caller: this
# script cannot tell "the ledger tracks nothing" from "the ledger is down", and
# answering the second with an empty list would silently report nothing at all.
# The workflow step that calls it is the layer that decides a ledger outage must
# not fail a deploy.

set -euo pipefail

err() { printf '%s\n' "$*" >&2; }

FROM_STDIN=0
case "${1:-}" in
  --stdin) FROM_STDIN=1; shift ;;
  -h|--help) sed -n '2,57p' "$0"; exit 0 ;;
  -*) err "ERROR: unknown option '$1'"; exit 2 ;;
esac

# Empty by default: prod's container names already ARE the ledger's names.
STRIP="${LEDGER_NAME_STRIP_SUFFIX:-}"

: "${SWITCHYARD_URL:?SWITCHYARD_URL is required}"
: "${SWITCHYARD_TOKEN:?SWITCHYARD_TOKEN is required}"

command -v jq >/dev/null 2>&1 || { err "ERROR: required dependency 'jq' not found in PATH"; exit 2; }

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

url="${SWITCHYARD_URL%/}"
known="$(mktemp)"
trap 'rm -f "$known"' EXIT

# `limit=200` is the API's ceiling. The estate has ~27 services at the outside,
# so a second page would mean something has gone very wrong; paginating for it
# would be dead code that never runs and is never exercised.
code="$(curl -sS -o "$known" -w '%{http_code}' --max-time 15 \
  -H "Authorization: Bearer ${SWITCHYARD_TOKEN}" \
  "${url}/v1/services?limit=200" 2>/dev/null)" || code="000"

if [ "$code" != "200" ]; then
  err "ERROR: GET /v1/services returned ${code}"
  exit 2
fi

# Archived services are excluded deliberately: archiving one is how an operator
# says "stop showing me this", and a reporter that kept writing rows for it would
# override that decision from a workflow.
mapfile -t known_names < <(jq -r '.items[] | select(.archived_at == null) | .name' < "$known")

if [ "${#known_names[@]}" -eq 0 ]; then
  err "NOTE: Switchyard tracks no services yet — nothing is reportable."
  exit 0
fi

is_known() {
  local candidate="$1" n
  for n in "${known_names[@]}"; do
    [ "$n" = "$candidate" ] && return 0
  done
  return 1
}

filter() {
  local name version
  while IFS=$'\t' read -r name version _ _; do
    [ -n "$name" ] || continue
    if [ -n "$STRIP" ]; then
      name="${name%"$STRIP"}"
    fi
    is_known "$name" || { err "skip: ${name} is not a service the ledger tracks"; continue; }
    [ "$version" = "latest" ] && version=""
    printf '%s=%s\n' "$name" "$version"
  done
}

if [ "$FROM_STDIN" -eq 1 ]; then
  filter
else
  filter < <("$here/delivery-facts.sh" "$@")
fi
