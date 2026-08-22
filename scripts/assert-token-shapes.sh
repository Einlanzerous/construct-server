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
# It gated dev from the start and prod from SERV-124, which also recorded why the
# asymmetry was wrong: prod carries more of these variables and the worse blast radius,
# and "prod is safer because it is Signet-managed" turned out to be false — `signet
# render --check` compares key SETS, not values, so a vault seeded from a stale file
# renders the stale value and reports success. That is how the dev value above got in.
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
# Three forms, because the estate uses three and a suffix match alone misses one:
#
#   BOOTSTRAP_TOKEN                   switchyard's own boot credential
#   *SWITCHYARD_TOKEN                 SWITCHYARD_TOKEN, PURSER_SWITCHYARD_TOKEN
#   *SWITCHYARD_TOKEN_*               SWITCHYARD_TOKEN_N8N_VOX_DICTATE — one per
#                                     consumer, minted separately (.env.example:84)
#
# That third line is a review catch, not foresight: the trailing `_N8N_VOX_DICTATE`
# defeats a suffix match, so n8n's per-workflow token went unchecked while the summary
# line reported full coverage. Anything of that form is a switchyard API token by
# construction, so match the infix rather than enumerating consumers.
#
# What must NOT be dragged in, and why the matching is this fussy rather than a grep for
# SWITCHYARD: AUTHENTIK_BOOTSTRAP_TOKEN is a different product's credential with a
# different shape (hence an EXACT match on BOOTSTRAP_TOKEN, not a suffix one), and
# SWITCHYARD_DB_PASSWORD and SWITCHYARD_WEBHOOK_SECRET are a password and an HMAC secret
# — switchyard's, but not API tokens, and neither is shaped like one.
is_switchyard_token_var() {
  case "$1" in
    BOOTSTRAP_TOKEN) return 0 ;;
    *SWITCHYARD_TOKEN) return 0 ;;
    *SWITCHYARD_TOKEN_*) return 0 ;;
    *) return 1 ;;
  esac
}

# `sw_` + 32 of the base32 alphabet. See the note above about this being a copy.
TOKEN_RE='^sw_[A-Z2-7]{32}$'

# stderr is captured rather than discarded. Silencing it is right on the success path,
# where compose is merely chatty about unset variables — but on the FAILURE path it left
# exit 2 saying only "cannot resolve", on a runner where reproducing means shelling into
# the box. Compose names the offending variable or interpolation template there, never a
# value, so there is no credential argument for hiding it. (Discarding an error you then
# report on is also the exact shape of the bug in SERV-123, one directory over.)
compose_err="$(mktemp)"
trap 'rm -f "$compose_err"' EXIT
if ! config_json="$(docker compose -f "$COMPOSE_FILE" ${COMPOSE_PROJECT:+-p "$COMPOSE_PROJECT"} config --format json 2>"$compose_err")"; then
  err "ERROR: 'docker compose config' failed in $DEPLOY_ROOT — cannot resolve the environment"
  err "A config that will not resolve is its own problem; fix that before reading this check."
  err ""
  err "compose said:"
  sed 's/^/  /' "$compose_err" >&2
  exit 2
fi

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
    # Two different situations, and the same sentence is wrong for one of them.
    #
    # BOOTSTRAP_TOKEN is switchyard's own boot credential, wrapped in `blankAsUnset`:
    # blank is a state it self-heals from, generating a token and surfacing it. Legal,
    # and saying so is accurate.
    #
    # Every other match is a CLIENT credential held by a consumer — n8n, purser,
    # autosavant-bot. Blank there means that consumer has no switchyard credential, which
    # is not switchyard self-healing and is not obviously fine. It is still not a SHAPE
    # failure, which is all this script judges, so it is skipped rather than failed — but
    # it is reported as what it is rather than waved through with a fact about a
    # different service. Whether a blank consumer token should fail is a real question
    # for whoever owns that consumer; it is deliberately not answered here.
    case "$var" in
      BOOTSTRAP_TOKEN)
        printf 'skip  %-22s %-32s blank — switchyard treats blank as unset and generates one\n' "$svc" "$var" ;;
      *)
        printf 'skip  %-22s %-32s blank — no shape to check; this consumer has no switchyard credential\n' "$svc" "$var" ;;
    esac
    skipped=$((skipped + 1))
    continue
  fi

  if printf '%s' "$value" | grep -qE "$TOKEN_RE"; then
    printf 'ok    %-22s %-32s well shaped\n' "$svc" "$var"
    checked=$((checked + 1))
  else
    # Length and prefix only. Never the value.
    case "$value" in
      sw_*) prefix="carries the sw_ prefix" ;;
      *)    prefix="does NOT start with sw_" ;;
    esac
    printf 'FAIL  %-22s %-32s %s, %s chars (want sw_ + 32 of A-Z2-7, 35 total)\n' \
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

# Matching NOTHING is a failure, not a pass. This is a gate in deploy-dev.yml AND, since
# SERV-124, in deploy.yml — so on both tiers what decides whether it inspects anything is
# a container-side variable name in a compose file, not a place anyone editing that file
# would think to look. If a name moves, every check here silently covers zero variables
# while still printing a line that reads green. That is the failure this repo keeps naming: the step directly below
# this one in deploy-dev.yml asserts its own coverage in both directions for the same
# reason ("a pin nothing reads looks like a control and is not one"), and
# mint-prober-token.sh asserts its granted scopes rather than trusting the request.
if [ "$((checked + skipped))" -eq 0 ]; then
  err "ERROR: no switchyard token variables matched — this check inspected nothing."
  err ""
  err "That is a failure rather than a pass. Either the container-side variable names in"
  err "$COMPOSE_FILE have changed and is_switchyard_token_var() has not followed, or this"
  err "is being run against a project that holds no switchyard consumer. Both need a human;"
  err "neither should go green."
  exit 1
fi

echo "$checked switchyard token variable(s) well shaped, $skipped blank."
