#!/usr/bin/env bash
#
# report-deploy — POST one `reported` deployment row per target (SWY-191/SERV-119).
#
# ── Why this is a vendored copy and not a `uses:` ──────────────────────────
#
# It began as a composite action in switchyard, on the argument that a client of
# that API contract should version with it. That does not work here: switchyard
# is PRIVATE and this repo is PUBLIC, and GitHub will not resolve an action from
# a private repo into a public repo's workflow — `actions/permissions/access` is
# set to `user` and it still fails. Worse, resolution happens at *Set up job*,
# before any `if:` is evaluated, so an unresolvable `uses:` fails the whole job
# even when every step referencing it would have been skipped. That took prod's
# deploy AND rollback path down, because deploy.yml triggers on versions.env.
#
# The alternative was a sparse checkout of switchyard using a GitHub App token,
# which means putting a credential dependency in front of the emergency lever.
# A vendored script has no such dependency and cannot fail to resolve.
#
# KEEP IN SYNC with switchyard's `.github/actions/report-deploy/`. The payload
# filter beside this file is a byte copy of that action's `payload.jq`, and
# switchyard's `server/test/lib/report-deploy-payload.test.ts` runs THAT copy
# against the shared `CreateDeployment` schema. If the contract changes, both
# move — see docs in switchyard's `docs/delivery.md`.
#
# The push half of the delivery ledger. Everything it sends is a CLAIM about a
# deploy that this workflow performed; the reconciler's observations are what
# corroborate it. See docs/delivery.md for the contract and .../payload.jq for
# the body.
#
# Inputs arrive as RD_* environment variables rather than `${{ inputs.* }}`
# interpolated into the run block. That is not style: a `note` or `source_ref`
# carrying a backtick or `$(…)` would otherwise be substituted into the script
# body by the expression engine before bash ever sees it, and these values come
# from branch names, commit messages and workflow_dispatch fields.
set -euo pipefail

# The filter lives beside this script, not at a caller-supplied path: this is a
# plain script in this repo now, not a composite action being handed its own
# location by the runner.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RD_ACTION_PATH="${RD_ACTION_PATH:-$here}"

fail() { echo "::error::report-deploy: $*" >&2; exit 1; }
warn() { echo "::warning::report-deploy: $*" >&2; }

[ -n "${RD_TOKEN:-}" ] || fail "token is required"
[ -n "${RD_ENVIRONMENT:-}" ] || fail "environment is required"

# Keep the token out of the log even if a later command echoes its environment.
echo "::add-mask::${RD_TOKEN}"

url="${RD_URL:-http://localhost:4002}"
url="${url%/}"
status="${RD_STATUS:-succeeded}"
retries="${RD_RETRIES:-5}"

# ── targets ────────────────────────────────────────────────────────────────
#
# Either one `service` + `version`, or a multi-line `services` block of
# `name=version` lines. The list form exists because a composite action cannot
# fan out into a job matrix, and construct-server's deploy.yml recreates
# several first-party services in a single run — one step has to be able to
# write several rows.
#
# A blank version is legitimate and is NOT an error: a `:latest` container
# yields a digest and no version, and the ledger records that as version-unknown
# rather than inventing one.
targets=()
if [ -n "${RD_SERVICES:-}" ]; then
  [ -z "${RD_SERVICE:-}" ] || fail "pass either 'service' or 'services', not both"
  # Rejected rather than ignored. The list form carries a version per line, so a
  # top-level `version` alongside it is a caller who believes it applies to all
  # of them — and silently dropping it would report every service at whatever
  # its line said while the author thinks they pinned the lot.
  [ -z "${RD_VERSION:-}" ] || fail "'version' does not apply to 'services' — put it on each line"
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"   # ltrim
    line="${line%"${line##*[![:space:]]}"}"   # rtrim
    [ -n "$line" ] || continue
    case "$line" in
      *=*) : ;;
      # Rejected rather than defaulted: `switchyard` with no `=` most likely
      # means the caller's shell dropped the version, and a row silently
      # recorded as version-unknown would look like a deliberate `:latest`.
      *) fail "'services' lines must be name=version, got: $line" ;;
    esac
    targets+=("$line")
  done <<< "${RD_SERVICES}"
  [ "${#targets[@]}" -gt 0 ] || fail "'services' was set but contained no entries"
else
  [ -n "${RD_SERVICE:-}" ] || fail "one of 'service' or 'services' is required"
  targets+=("${RD_SERVICE}=${RD_VERSION:-}")
fi

# ── idempotency key ────────────────────────────────────────────────────────
#
# Scoped to (run, service, environment, STATUS) — deliberately NOT the attempt.
#
# Re-running a workflow must not append a second identical row (SWY-191's
# acceptance criterion), and `run_attempt` is exactly what changes on a re-run,
# so including it would guarantee the duplicate it is supposed to prevent.
# `status` is in the key instead, which gets the useful half of the same idea:
# the `running` row and the `succeeded` row that closes it are two distinct
# writes, and a re-run that failed and then succeeded still records the
# succeeded row — while a re-run that lands the same status replays.
idem_key() {
  local service="$1" raw
  if [ -n "${RD_IDEMPOTENCY_KEY:-}" ]; then
    # Still per-service. A caller-supplied key reused verbatim across a
    # multi-service run would make services 2..N replay service 1's response
    # and write nothing at all, silently.
    raw="${RD_IDEMPOTENCY_KEY}-${service}"
  elif [ -n "${GITHUB_RUN_ID:-}" ]; then
    raw="${GITHUB_RUN_ID}-${service}-${RD_ENVIRONMENT}-${status}"
  else
    # Off a runner (a local dry run). There is no stable identity to key on, so
    # key on this invocation: it still guards the retry loop below, which is the
    # window that matters, without colliding with the next dry run and replaying
    # a 24h-old response at someone who is trying to test a change.
    raw="local-${invocation_id}-${service}-${RD_ENVIRONMENT}-${status}"
  fi
  raw="$(printf '%s' "$raw" | tr -c 'A-Za-z0-9._-' '-')"
  # `idempotency_keys.key` is varchar(128) and the header schema caps at 128.
  # Service names go to 80 chars, so the composed key can overflow — hash rather
  # than truncate, because two truncated keys that collide would make one deploy
  # replay another's response.
  if [ "${#raw}" -gt 128 ]; then
    raw="$(printf '%s' "$raw" | sha256sum | cut -d' ' -f1)"
  fi
  printf '%s' "$raw"
}
invocation_id="$$-${SECONDS}-${RANDOM}"

# ── post ───────────────────────────────────────────────────────────────────

body_file="$(mktemp)"
resp_file="$(mktemp)"
trap 'rm -f "$body_file" "$resp_file"' EXIT

reported=0
skipped=0
deployment_id=""
http_status=""

for target in "${targets[@]}"; do
  service="${target%%=*}"
  version="${target#*=}"
  [ -n "$service" ] || fail "empty service name in target: $target"

  jq -n \
    --arg service      "$service" \
    --arg environment  "${RD_ENVIRONMENT}" \
    --arg status       "$status" \
    --arg version      "$version" \
    --arg digest       "${RD_DIGEST:-}" \
    --arg sha          "${RD_SHA:-}" \
    --arg deployed_at  "${RD_DEPLOYED_AT:-}" \
    --arg deployed_by  "${RD_DEPLOYED_BY:-}" \
    --arg source_ref   "${RD_SOURCE_REF:-}" \
    --arg run_url      "${RD_RUN_URL:-}" \
    --arg gate_run_url "${RD_GATE_RUN_URL:-}" \
    --arg gate_passed  "${RD_GATE_PASSED:-}" \
    --arg gate_total   "${RD_GATE_TOTAL:-}" \
    --arg commit_count "${RD_COMMIT_COUNT:-}" \
    --arg ticket_keys  "${RD_TICKET_KEYS:-}" \
    --arg note         "${RD_NOTE:-}" \
    -f "${RD_ACTION_PATH}/report-deploy.jq" > "$body_file" \
    || fail "could not build the request body for '$service' — check the numeric inputs"

  key="$(idem_key "$service")"
  attempt=1
  code=""
  while : ; do
    code="$(curl -sS -o "$resp_file" -w '%{http_code}' \
      --max-time 20 \
      -X POST "${url}/v1/deployments" \
      -H "Authorization: Bearer ${RD_TOKEN}" \
      -H "Content-Type: application/json" \
      -H "Idempotency-Key: ${key}" \
      --data-binary @"$body_file" 2>/dev/null)" || code="000"

    # 000 is our marker for "curl itself failed" — connection refused, DNS,
    # timeout. That is the expected state for a good part of a deploy: the
    # container restarts to run its migrations while this step is posting, so a
    # first attempt failing is normal operation and not a fault worth logging.
    if [ "$code" = "000" ] || [ "$code" -ge 500 ] 2>/dev/null; then
      if [ "$attempt" -ge "$retries" ]; then
        break
      fi
      sleep "$(( 2 ** attempt ))"
      attempt=$(( attempt + 1 ))
      continue
    fi
    break
  done

  http_status="$code"
  if [ "$code" = "201" ] || [ "$code" = "200" ]; then
    # `|| true`, and it is not decoration. Under `set -e` an unguarded jq exits
    # the whole script on any 2xx whose body is not JSON — taking the caller's
    # deploy job with it, skipping the $GITHUB_OUTPUT block below so `reported`
    # and `skipped` are unset too, and doing all of that regardless of
    # `fail-on-error: false`. The ledger must never be able to fail a deploy.
    deployment_id="$(jq -r '.id // empty' < "$resp_file" 2>/dev/null || true)"
    reported=$(( reported + 1 ))
    echo "report-deploy: ${service} @ ${RD_ENVIRONMENT} ${version:-(version unknown)} → ${status} (HTTP ${code})"
  else
    skipped=$(( skipped + 1 ))
    # The ledger is an observer of the deploy, never a gate on it. A deploy that
    # worked must not be reported as failed because the thing recording it was
    # unreachable — that would put a red row on the page for the one service
    # that is fine, which is the exact false-alarm this epic exists to avoid.
    detail="$(jq -r '.error.message // .message // empty' < "$resp_file" 2>/dev/null || true)"
    warn "could not record ${service} @ ${RD_ENVIRONMENT}: HTTP ${code}${detail:+ — ${detail}}"
  fi
done

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "reported=${reported}"
    echo "skipped=${skipped}"
    echo "deployment-id=${deployment_id}"
    echo "http-status=${http_status}"
  } >> "$GITHUB_OUTPUT"
fi

if [ "$skipped" -gt 0 ] && [ "${RD_FAIL_ON_ERROR:-false}" = "true" ]; then
  fail "${skipped} of ${#targets[@]} report(s) failed and fail-on-error is set"
fi
exit 0
