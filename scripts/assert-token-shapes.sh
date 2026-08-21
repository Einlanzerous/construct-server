#!/usr/bin/env bash
# assert-token-shapes.sh — does the RENDERED environment hold values the services
# will actually accept?
#
# SERV-118: switchyard-dev crash-looped 166 times over two days because
# SWITCHYARD_BOOTSTRAP_TOKEN in DEV_ENV_FILE was 48 characters of hex — the shape of
# `openssl rand -hex 24`, not of a switchyard API token. SWY-295 had just turned that
# from a silently-dead credential into a loud boot failure, so dev, which tracks
# `latest`, was the first tier to run the build that refused it. The value had been
# wrong long before anything said so.
#
# The deploy that rendered that environment went green, and the tier stayed dark for
# two days. A deploy that renders an environment the application will REFUSE should
# fail at render. That is all this script is.
#
# ── WHY COMPOSE, AND NOT A GREP OF .env ──────────────────────────────────────────
# Compose strips quotes and takes the last of duplicate keys, so a grep of the file
# and the value the container receives can disagree — a disagreement of exactly that
# kind has already shipped a bug in this repo (SERV-88, and see the "Show what dev
# will pull" step in deploy-dev.yml). This asks compose, so the check cannot disagree
# with what the service is actually handed.
#
# ── WHAT IT WILL NOT PRINT ───────────────────────────────────────────────────────
# The resolved config holds every credential in the stack. Nothing here echoes a
# value. A failure reports the variable, its LENGTH, and whether it carries the `sw_`
# prefix — which is what makes the failure diagnosable ("48 chars, no prefix" is
# instantly recognisable as a hex string) without putting the credential in a CI log
# that outlives it.
#
# ── THE SHAPE, AND THE FACT THAT IT IS RESTATED ──────────────────────────────────
# `sw_` followed by 32 characters of ABCDEFGHIJKLMNOPQRSTUVWXYZ234567 — 35 total.
# Switchyard builds this from constants and exports it as `API_TOKEN_RE_SOURCE`
# (server/src/lib/id.ts), precisely so it has one definition. This is a second copy in
# another language in another repo, and there is no way around that from here: the
# stack cannot import a TypeScript regex. It is a copy, so it can drift — if
# switchyard ever widens the alphabet or the length, this file is one of the places
# that has to follow, and until it does this check FAILS CLOSED on a token switchyard
# would have accepted. That is the safe direction, but it is not a free check.
#
# ── BLANK IS UNSET, DELIBERATELY ─────────────────────────────────────────────────
# Switchyard wraps the variable in `blankAsUnset`, so an empty BOOTSTRAP_TOKEN is a
# legal state: with no token set and no api_tokens rows, it generates one and surfaces
# it. Failing on blank here would reject a configuration the service accepts. So blank
# is SKIPPED — and skipped LOUDLY, named in the output, because "no bootstrap token"
# is worth seeing rather than worth hiding (the same reasoning as db/init-db.sh).
#
# Usage:
#   ./scripts/assert-token-shapes.sh
#     DEPLOY_ROOT / COMPOSE_FILE / COMPOSE_PROJECT select the project, the same way
#     assert-healthy.sh and report-versions.sh do. `make assert-tokens` and
#     `make dev-assert-tokens` set them for you.
#
# Exit codes:
#   0  every switchyard-token variable is well shaped (or legally blank)
#   1  at least one carries a value the service will refuse
#   2  usage / missing dependency / no deploy root

set -euo pipefail

DEPLOY_ROOT="${DEPLOY_ROOT:-/opt/construct-server}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
COMPOSE_PROJECT="${COMPOSE_PROJECT:-}"

err() { printf '%s\n' "$*" >&2; }

for dep in docker jq; do
  command -v "$dep" >/dev/null 2>&1 || { err "ERROR: required dependency '$dep' not found in PATH"; exit 2; }
done

if [ ! -f "$DEPLOY_ROOT/$COMPOSE_FILE" ]; then
  err "ERROR: no $COMPOSE_FILE at DEPLOY_ROOT=$DEPLOY_ROOT"
  exit 2
fi

cd "$DEPLOY_ROOT"

# Which variables must carry a switchyard API token, by the name the CONTAINER sees.
# Matching on the container-side name rather than the .env key is what makes this
# cover both tiers: dev feeds BOTH of its consumers from SWITCHYARD_BOOTSTRAP_TOKEN,
# while prod feeds purser from its own minted PURSER_SWITCHYARD_TOKEN (SERV-113), and
# the container-side names are identical either way.
#
# AUTHENTIK_BOOTSTRAP_TOKEN is a different product's credential with a different shape
# and must not be dragged in — hence an exact match on BOOTSTRAP_TOKEN rather than a
# suffix match, which would catch it.
is_switchyard_token_var() {
  case "$1" in
    BOOTSTRAP_TOKEN) return 0 ;;
    *SWITCHYARD_TOKEN) return 0 ;;
    *) return 1 ;;
  esac
}

# `sw_` + 32 of the base32 alphabet. See the note above about this being a copy.
TOKEN_RE='^sw_[A-Z2-7]{32}$'

config_json="$(docker compose -f "$COMPOSE_FILE" ${COMPOSE_PROJECT:+-p "$COMPOSE_PROJECT"} config --format json 2>/dev/null)" || {
  err "ERROR: 'docker compose config' failed in $DEPLOY_ROOT — cannot resolve the environment"
  err "A config that will not resolve is its own problem; fix that before reading this check."
  exit 2
}

# service<TAB>varname<TAB>value. Tab because a token cannot contain one, and because
# `read -r` splitting on it leaves the value untouched.
rows="$(printf '%s' "$config_json" | jq -r '
  .services // {} | to_entries[] as $svc
  | ($svc.value.environment // {}) | to_entries[]
  | [$svc.key, .key, (.value // "")] | @tsv
')"

checked=0
skipped=0
failed=0

while IFS=$'\t' read -r svc var value; do
  [ -n "${var:-}" ] || continue
  is_switchyard_token_var "$var" || continue

  if [ -z "${value:-}" ]; then
    printf 'skip  %-22s %-24s blank — switchyard treats blank as unset, so this is legal\n' "$svc" "$var"
    skipped=$((skipped + 1))
    continue
  fi

  if printf '%s' "$value" | grep -qE "$TOKEN_RE"; then
    printf 'ok    %-22s %-24s well shaped\n' "$svc" "$var"
    checked=$((checked + 1))
  else
    # Length and prefix only. Never the value.
    case "$value" in
      sw_*) prefix="carries the sw_ prefix" ;;
      *)    prefix="does NOT start with sw_" ;;
    esac
    printf 'FAIL  %-22s %-24s %s, %s chars (want sw_ + 32 of A-Z2-7, 35 total)\n' \
      "$svc" "$var" "$prefix" "${#value}"
    failed=$((failed + 1))
  fi
done <<< "$rows"

echo
if [ "$failed" -gt 0 ]; then
  err "ERROR: $failed switchyard token variable(s) hold a value the service will refuse."
  err ""
  err "This is not a warning. Switchyard's auth check requires the shape BEFORE it looks"
  err "anything up, so such a value cannot authenticate — and \`ensureBootstrapToken\` is"
  err "additive, so correcting it later adds a second row rather than repairing the first."
  err "Fix the value at its source (the environment secret, or Signet) and re-render;"
  err "do not edit the deployed .env, which the next deploy regenerates."
  exit 1
fi

echo "$checked switchyard token variable(s) well shaped, $skipped legally blank."
