#!/usr/bin/env bash
# register-delivery-service.sh — put a first-party service into Switchyard's
# delivery inventory, but only once it can actually be observed (SERV-128).
#
# ── Why this needs a guard at all ─────────────────────────────────────────
#
# Registering is a one-line POST, and doing it at the wrong moment creates a
# permanent red row on the one page whose entire job is to be believed.
#
# The delivery matrix pairs a REPORT (what a deploy claims it shipped, taken
# from the image's org.opencontainers.image.version label) with an OBSERVATION
# (what the running process answered). A report with no observation to pair
# with is `claimed_not_confirmed` — red, with a banner.
#
# The trap is that `no_version` does NOT produce an observation.
# `markProbeNoVersion` in switchyard only updates the pair's probe STATE; it
# never inserts a `deployments` row. So a service that answers /healthz politely
# without a version looks fine on the matrix — and the moment a deploy recreates
# it, `delivery-reportable.sh` reports it (its only filter is "is this service in
# the inventory"), the report finds nothing to corroborate it, and the row goes
# red and stays red.
#
# So the rule is: REGISTER A SERVICE ONLY AFTER IT REPORTS A VERSION. Not after
# its PR merges — after the release is built, deployed, and answering. This
# script enforces exactly that and refuses otherwise.
#
# ── Why it probes from inside the switchyard container ────────────────────
#
# Because that is the reconciler's vantage point, and it is the only one that
# matters. A probe from the host proves nothing: the host can reach published
# ports and 127.0.0.1 that construct_net cannot, and the reconciler resolves
# `http://{service}:{port}` against docker's DNS. Checking from anywhere else
# would bless an address that is about to resolve to nothing.
#
# Usage:
#   ./scripts/register-delivery-service.sh <name> <port> [health_path]
#
#   name         MUST match the container name on construct_net — the
#                reconciler substitutes it into prod's `http://{service}:{port}`.
#   port         the port the service listens on INSIDE the network, not a
#                published host port.
#   health_path  defaults to /healthz. Set it when the contract lives elsewhere
#                (interlock-web and cook_book both answer at /api/health;
#                interlock's /healthz is a page route that 302s to /login).
#
# Options:
#   --allow-no-version   register despite the service reporting no version.
#                        Loud, and almost always wrong — read the note above
#                        before reaching for it.
#   --dry-run            probe and report the verdict, change nothing.
#
# Environment:
#   SWITCHYARD_URL    default http://localhost:4002
#   SWITCHYARD_TOKEN  REQUIRED, and needs write scope. The delivery prober's
#                     token is `deployments:observe` only and cannot create a
#                     service — deliberately, since a producer that could
#                     register would be able to wedge a phantom row into the
#                     inventory by naming something wrong.
#
# Exit codes:
#   0  registered, or already present (idempotent)
#   1  the service is not ready to be registered — the reason is printed
#   2  usage / missing dependency / could not reach Switchyard

set -euo pipefail

err() { printf '%s\n' "$*" >&2; }

SWITCHYARD_CONTAINER="${SWITCHYARD_CONTAINER:-switchyard}"
SWITCHYARD_URL="${SWITCHYARD_URL:-http://localhost:4002}"
ALLOW_NO_VERSION=0
DRY_RUN=0

args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --allow-no-version) ALLOW_NO_VERSION=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) awk 'NR==1{next} /^set -euo pipefail$/{exit} {print}' "$0"; exit 0 ;;
    -*) err "ERROR: unknown option '$1'"; exit 2 ;;
    *) args+=("$1"); shift ;;
  esac
done

if [ "${#args[@]}" -lt 2 ] || [ "${#args[@]}" -gt 3 ]; then
  err "usage: $0 <name> <port> [health_path] [--allow-no-version] [--dry-run]"
  exit 2
fi

NAME="${args[0]}"
PORT="${args[1]}"
HEALTH_PATH="${args[2]:-/healthz}"

command -v jq >/dev/null 2>&1 || { err "ERROR: required dependency 'jq' not found in PATH"; exit 2; }
command -v docker >/dev/null 2>&1 || { err "ERROR: required dependency 'docker' not found in PATH"; exit 2; }
: "${SWITCHYARD_TOKEN:?SWITCHYARD_TOKEN is required, and needs write scope (the prober token will not do)}"

url="${SWITCHYARD_URL%/}"

# ── is it already there? ────────────────────────────────────────────────────
# Checked first so a re-run is a no-op rather than a 409, which makes this safe
# to put in a runbook someone follows twice.
existing="$(curl -sS --max-time 15 -H "Authorization: Bearer ${SWITCHYARD_TOKEN}" \
  "${url}/v1/services?limit=200" 2>/dev/null)" || {
    err "ERROR: could not reach Switchyard at ${url}"
    exit 2
  }

if ! printf '%s' "$existing" | jq -e '.items' >/dev/null 2>&1; then
  err "ERROR: unexpected response from GET /v1/services — is SWITCHYARD_TOKEN valid?"
  exit 2
fi

if printf '%s' "$existing" | jq -e --arg n "$NAME" '.items[] | select(.name == $n)' >/dev/null 2>&1; then
  echo "[register] ${NAME} is already in the inventory — nothing to do"
  exit 0
fi

# ── probe from the reconciler's vantage point ───────────────────────────────
probe_url="http://${NAME}:${PORT}${HEALTH_PATH}"
echo "[register] probing ${probe_url} from inside the ${SWITCHYARD_CONTAINER} container"

# `-O -` keeps the body; wget exits non-zero on a 503, which is a CONTRACT
# status here — a degraded service still reports its version, and that is the
# case most worth registering. So the exit code is ignored and the body is
# judged instead.
body="$(docker exec "$SWITCHYARD_CONTAINER" sh -c \
  "wget -q -O - --timeout=5 '${probe_url}' 2>/dev/null || true" 2>/dev/null || true)"

if [ -z "$body" ]; then
  err "REFUSING: ${probe_url} returned nothing."
  err "  Either the service is not on construct_net under that exact name, the port"
  err "  is wrong, or the path is. The reconciler would record 'unreachable' — a red"
  err "  row for a service that may be running perfectly well."
  exit 1
fi

version="$(printf '%s' "$body" | jq -r '.version // empty' 2>/dev/null || true)"

if [ -z "$version" ]; then
  err "REFUSING: ${NAME} answered, but reports no version."
  err "  body: $(printf '%s' "$body" | head -c 200)"
  err ""
  err "  This is the state that looks harmless and is not. A no_version probe"
  err "  updates the pair's probe state but writes NO observation row, so the next"
  err "  deploy that recreates ${NAME} will report it with nothing to corroborate"
  err "  the claim — 'claimed_not_confirmed', permanently."
  err ""
  err "  Ship the SWY-192 contract in ${NAME}'s repo first, release it, deploy it,"
  err "  then run this again. See PRINCIPLES.md section 4."
  [ "$ALLOW_NO_VERSION" -eq 1 ] || exit 1
  err "  --allow-no-version given; continuing anyway."
fi

# A "v" prefix can never match the image label, which metadata-action stamps
# bare. Caught here as well as in each repo because this is the last gate before
# the row exists, and the failure it prevents is silent and permanent.
case "$version" in
  v[0-9]*)
    err "REFUSING: ${NAME} reports '${version}' — a 'v'-prefixed version."
    err "  The deploy reporter reads org.opencontainers.image.version, which is"
    err "  stamped BARE, and the matrix compares the two with strict equality. This"
    err "  service would be 'claimed_not_confirmed' on every deploy, for ever."
    err "  Fix the build to stamp bare semver before registering."
    exit 1
    ;;
  latest)
    err "REFUSING: ${NAME} reports 'latest', which names a moving target rather"
    err "  than a build. Stored as an identity it can never agree with anything."
    exit 1
    ;;
esac

echo "[register] ${NAME} reports version=${version:-<none>} sha=$(printf '%s' "$body" | jq -r '.sha // "null"')"

if [ "$DRY_RUN" -eq 1 ]; then
  echo "[register] --dry-run: would POST /v1/services name=${NAME} port=${PORT} health_path=${HEALTH_PATH}"
  exit 0
fi

# ── register ────────────────────────────────────────────────────────────────
# `health_path` is sent only when it differs from the default, so the common
# case stores NULL and inherits whatever the reconciler's default becomes.
payload="$(jq -nc --arg name "$NAME" --argjson port "$PORT" --arg hp "$HEALTH_PATH" '
  { name: $name, port: $port, source: "first_party", kind: "application" }
  + (if $hp == "/healthz" then {} else { health_path: $hp } end)
')"

code="$(curl -sS -o /tmp/register-out.$$ -w '%{http_code}' --max-time 15 \
  -X POST -H "Authorization: Bearer ${SWITCHYARD_TOKEN}" \
  -H 'Content-Type: application/json' \
  -d "$payload" "${url}/v1/services" 2>/dev/null)" || code="000"

if [ "$code" != "201" ] && [ "$code" != "200" ]; then
  err "ERROR: POST /v1/services returned ${code}"
  err "  $(head -c 300 /tmp/register-out.$$ 2>/dev/null)"
  rm -f "/tmp/register-out.$$"
  exit 2
fi

echo "[register] registered ${NAME} (port ${PORT}, health_path ${HEALTH_PATH})"
echo "[register] the reconciler picks it up within a tick — never-probed pairs sort first."
rm -f "/tmp/register-out.$$"
