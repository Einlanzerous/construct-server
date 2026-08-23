#!/usr/bin/env bash
# delivery-reportable.sh — which containers may honestly be REPORTED to the
# Switchyard ledger, and at what version (SERV-117).
#
# Wraps delivery-facts.sh with the two filters that keep the push producer from
# manufacturing false alarms. Emits `name=version` lines, which is exactly the
# `services:` input the report-deploy composite action takes.
#
# ── Filter 1: only what this deploy actually MOVED ────────────────────────
#
# `--since <baseline>` diffs the current facts against a snapshot taken before
# the pull and keeps only the containers that this run actually RECREATED —
# a change in either the image digest or the container id.
#
# Digest alone is not enough, and the gap is the common case rather than a corner:
# compose recreates a container whenever its config hash moves (env, mounts,
# healthcheck, ports, labels) with a byte-identical image. A push that re-renders
# `.env` does that to every service that reads a changed value. The container id
# changes on every recreate and never on a restart, so it is the signal that
# matches what "deployed" means here.
#
# Without it every run reports every service. That is wrong on both deploy paths
# for the same reason: prod's FULL path runs on a push to `config/**` or
# `scripts/**` and recreates nothing, and dev's workflow runs hourly. Reports are
# deliberately NOT deduplicated the way observations are — a deploy that really
# happened twice is two events — so a reporter that fired on every run would
# append a row per no-op and bury the handful that are real.
#
# Digest, not tag: dev floats on `latest`, so the tag is the same string on both
# sides of a pull that moved the whole tier.
#
# A MISSING baseline reports nothing, deliberately. The file is named for the run
# and written by a step early in the job, so its absence means that step never
# executed — the deploy failed before it started, and "everything is new" would
# be exactly the wrong reading. An EMPTY baseline is different and does mean
# everything is new: that is a cold root with no containers yet.
#
# ── Filter 2: the ledger must already know the service ────────────────────
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
# ── Filter 3: `latest` is not a version ───────────────────────────────────
#
# argosy's publish workflow stamps `org.opencontainers.image.version=latest` on
# a build from `main`, because the version label is derived from the image's own
# tags and a main build is tagged `latest`. `latest` names a moving target, not a
# build; the ledger would store it as an identity, compare it against whatever
# /healthz says, and disagree for ever. Dropped to empty, which the ledger records
# as version-unknown — true, and not red.
#
# This filter is NOT redundant now that SERV-125 makes releases publish real
# semver images, and do not delete it on that basis: prod tracks a major.minor
# pin, but a `main` build still stamps `latest` and is still what a floating or
# hand-pulled container can be running. The filter narrows rather than widens —
# a real version passes straight through it.
#
# ── The name the LEDGER uses is not always the container's ────────────────
#
# Switchyard holds one `services` row per service and uses the environment as the
# other axis, so prod's `switchyard` and dev's `switchyard-dev` are the same
# service seen twice — the `-dev` suffix is a compose-project artefact, not part
# of the identity. `LEDGER_NAME_STRIP_SUFFIX=-dev` maps them back.
#
# Filter 2 is the backstop if that mapping is ever wrong: an unmapped name is
# simply skipped, so the worst case is a missing row rather than a phantom
# `switchyard-dev` service wedged into the inventory beside the real one.
#
# Usage:
#   SWITCHYARD_URL=http://localhost:4002 SWITCHYARD_TOKEN=sw_... \
#     ./scripts/delivery-reportable.sh --since /tmp/before.txt [compose service ...]
#
#   --since FILE  report only containers whose digest differs from FILE.
#                 Omit to report everything tracked, which almost no caller wants.
#
#   DEPLOY_ROOT / COMPOSE_FILE / COMPOSE_PROJECT select the project and are
#   passed through to delivery-facts.sh.
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

SINCE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --since) SINCE="${2:-}"; [ -n "$SINCE" ] || { err "ERROR: --since needs a path"; exit 2; }; shift 2 ;;
    # Anchored on `set -euo pipefail` rather than a line number, because a line
    # number silently truncates. This was `2,95p` while the header ran to 104, so
    # `--help` printed none of the exit codes — including the one explaining that
    # an unreachable Switchyard is a hard failure here and a soft one in the
    # caller, which is the least guessable thing on the page. It clipped quietly:
    # help output that stops early looks exactly like help output that ended.
    -h|--help) awk 'NR==1{next} /^set -euo pipefail$/{exit} {print}' "$0"; exit 0 ;;
    -*) err "ERROR: unknown option '$1'"; exit 2 ;;
    *) break ;;
  esac
done

# Empty by default: prod's container names already ARE the ledger's names.
STRIP="${LEDGER_NAME_STRIP_SUFFIX:-}"

: "${SWITCHYARD_URL:?SWITCHYARD_URL is required}"
: "${SWITCHYARD_TOKEN:?SWITCHYARD_TOKEN is required}"

command -v jq >/dev/null 2>&1 || { err "ERROR: required dependency 'jq' not found in PATH"; exit 2; }

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -n "$SINCE" ] && [ ! -f "$SINCE" ]; then
  err "NOTE: no baseline at ${SINCE} — the snapshot step never ran, so what moved is unknowable. Reporting nothing."
  exit 0
fi

url="${SWITCHYARD_URL%/}"
known="$(mktemp)"

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

now="$(mktemp)"
trap 'rm -f "$known" "$now"' EXIT

"$here/delivery-facts.sh" "$@" > "$now"

if [ -n "$SINCE" ]; then
  # Keyed on FILENAME, not the usual `NR == FNR`. With an EMPTY baseline that
  # idiom silently inverts: FNR resets per file, so with no records from the
  # first, `NR == FNR` stays true for every line of the second and the whole
  # current list is absorbed as "before" — reporting nothing on exactly the cold
  # start where everything is new.
  moved="$(awk -F'|' -v BEFORE="$SINCE" '
    FILENAME == BEFORE { d[$1] = $3; id[$1] = $5; next }
    { if (!($1 in d) || d[$1] != $3 || id[$1] != $5) print }
  ' "$SINCE" "$now")"
else
  moved="$(cat "$now")"
fi

[ -n "$moved" ] || exit 0

# `|` and not a tab. Tab is IFS whitespace, so `IFS=$'\t' read` collapses runs of
# it and a row with no version shifts every later field one place left — storing
# the DIGEST as the version, for exactly the images that have no version to
# report. See delivery-facts.sh.
printf '%s\n' "$moved" | while IFS='|' read -r name version _digest _revision _cid; do
  [ -n "$name" ] || continue
  if [ -n "$STRIP" ]; then
    name="${name%"$STRIP"}"
  fi
  is_known "$name" || { err "skip: ${name} is not a service the ledger tracks"; continue; }
  [ "$version" = "latest" ] && version=""
  printf '%s=%s\n' "$name" "$version"
done
