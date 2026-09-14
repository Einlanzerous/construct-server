#!/usr/bin/env bash
# assert-env-keys.sh — does the RENDERED environment still hold every key the stack needs?
#
# SERV-173: LYCEUM_BINDERY_API_KEY was empty in the prod lyceum container for the FOURTH
# time on 2026-09-14. Compose reads it as `${LYCEUM_BINDERY_API_KEY:-}`, so its absence
# is not an error: lyceum boots, reports healthy, and quietly runs the no-op acquirer —
# every ingest confirm since then marked rows `wanted` and nothing picked them up. Each
# occurrence was a rewrite of the environment secret from a copy that predated the key:
# absent at first enable (2026-07-20), dropped 2026-08-25, dropped again before the
# 2026-08-29 deploy, and the 2026-09-06 restore was itself reverted, because it went in
# with `gh secret set` and PROD_ENV_FILE is rendered by Signet from the vault — the vault
# never held the key, so the next `signet sync` rebuilt the secret without it.
#
# Nothing on the deploy path could see any of that. `assert-token-shapes.sh` judges the
# VALUES of five variables; the SERV-88 step asserts image tags; `check-compose-drift.sh`
# compares mounts. A key that is simply not there fails none of them, and compose's
# `:-` defaults exist precisely so that its absence is not an error either. So this is the
# check that asks the one question none of them ask: is every key the stack needs PRESENT,
# with a value, in the file compose is about to read?
#
# ── THE MANIFEST ─────────────────────────────────────────────────────────────────
# `required-env-keys.txt` (prod) and `dev-required-env-keys.txt` (dev), tracked in git:
# one key NAME per line, `#` comments, nothing else. Every listed key must be present in
# the rendered .env with a non-empty value. It is names only, so it can be reviewed and
# diffed like any other file here and holds nothing worth protecting.
#
# Names, not a pattern, and hand-maintained rather than derived from docker-compose.yml —
# because the keys that matter most are exactly the ones compose cannot tell you about.
# A `${KEY}` reference with no default is at least visible: compose warns that it is
# unset. A `${KEY:-}` reference is silent by design, and a key something OTHER than
# compose reads — GITHUB_PAT for the registry login in deploy.yml — never appears in
# any compose output at all. The manifest is the list of keys whose loss is silent, which
# is a judgement, and judgements go in a reviewed file.
#
# Two consequences to keep straight. A key the vault delivers that is NOT in the manifest
# is unprotected, and this script says so as a warning (not a failure — see ORDERING).
# And a key that may legitimately be blank does not belong in the manifest at all: an
# empty value is not a value (CLAUDE.md), and the `:-` defaults in compose treat it as
# unset, so "present but empty" is the same failure as "missing" and is reported as such.
#
# ── ORDERING: VAULT FIRST, THEN THE MANIFEST ─────────────────────────────────────
# Adding a key is `signet set` + `signet target add-key` + `signet sync`, THEN a line in
# the manifest. In that order the interval between the two is a warning on each deploy
# ("delivered, unlisted"). In the other order it is a red prod deploy until the vault
# catches up, and every unrelated deploy — a rollback included — is blocked with it. The
# same asymmetry decides what is fatal here: missing is a failure, unlisted is a warning.
#
# ── WHY THE FILE, AND NOT `docker compose config` ────────────────────────────────
# assert-token-shapes.sh asks compose rather than grepping .env, and its header explains
# why: for VALUES, compose's quote-stripping and last-duplicate-wins are the truth. That
# argument does not carry here. The question is presence, and the resolved config cannot
# answer it — a `${KEY:-default}` resolves to its default whether the key is absent,
# empty, or set to the same string, which is the exact ambiguity this check exists to
# remove; and a key nothing in compose reads is not in the resolved config at all. So this
# reads the file compose will read, applying compose's own rules where they bear on the
# answer: the LAST definition of a duplicate key wins, and a value that is only a pair of
# matching quotes is empty.
#
# ── WHAT IT WILL NOT PRINT ───────────────────────────────────────────────────────
# The file holds every credential in the stack. Nothing here echoes a value or a value's
# length: the parse keeps a key name and one of two states, `set` or `empty`, and the
# value is discarded inside awk before anything is printed.
#
# ── --vault: ASK THE VAULT INSTEAD OF THE FILE ───────────────────────────────────
# `signet sync` writes the environment secret, and only a DEPLOY renders that into the
# .env on the box. So straight after adding a key the deployed file legitimately does not
# have it, and the honest question is "will the next deploy have it?" — which the vault
# answers. `--vault` reads `signet status` and takes every key delivered through the
# tier's render target (`gh-render:…→PROD_ENV_FILE`), names only. It sees presence and
# not emptiness, since it never reads a value; it exists so a vault edit can be checked
# before it ships, and the default form is what the deploy runs afterwards. Same two
# moments, same reasoning, as `make promote-dispatch-check vault=1`.
#
# Usage:
#   ./scripts/assert-env-keys.sh                # prod: required-env-keys.txt vs $DEPLOY_ROOT/.env
#   ./scripts/assert-env-keys.sh --dev          # dev:  dev-required-env-keys.txt vs $DEV_ROOT/.env
#   ./scripts/assert-env-keys.sh --vault        # what the vault will deliver, instead of the file
#   ./scripts/assert-env-keys.sh --env FILE     # a candidate file — before it becomes the secret
#   ./scripts/assert-env-keys.sh --manifest FILE
#     DEPLOY_ROOT / DEV_ROOT override the roots, the same way the Makefile does.
#
# Exit codes:
#   0  every required key is present with a value (warnings may still have printed)
#   1  at least one required key is missing or empty
#   2  usage error, no environment to read, a malformed or empty manifest, or signet unavailable

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd)"

err() { printf '%s\n' "$*" >&2; }

usage() {
  err "usage: assert-env-keys.sh [--dev] [--vault | --env FILE] [--manifest FILE]"
}

DEPLOY_ROOT="${DEPLOY_ROOT:-/opt/construct-server}"
DEV_ROOT="${DEV_ROOT:-/opt/construct-server-dev}"

DEV=0
VAULT=0
ENV_FILE=""
MANIFEST=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dev) DEV=1 ;;
    --vault) VAULT=1 ;;
    --env) shift; ENV_FILE="${1:-}"; [ -n "$ENV_FILE" ] || { usage; exit 2; } ;;
    --manifest) shift; MANIFEST="${1:-}"; [ -n "$MANIFEST" ] || { usage; exit 2; } ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
  shift
done

if [ "$VAULT" -eq 1 ] && [ -n "$ENV_FILE" ]; then
  err "ERROR: --vault and --env are two different sources; pick one."
  exit 2
fi

if [ "$DEV" -eq 1 ]; then
  TIER="dev"
  PROJECT="construct-server-dev"
  RENDER_SECRET="DEV_ENV_FILE"
  VERSIONS="$REPO_ROOT/dev-versions.env"
  : "${MANIFEST:=$REPO_ROOT/dev-required-env-keys.txt}"
  : "${ENV_FILE:=$DEV_ROOT/.env}"
else
  TIER="prod"
  PROJECT="construct-server"
  RENDER_SECRET="PROD_ENV_FILE"
  VERSIONS="$REPO_ROOT/versions.env"
  : "${MANIFEST:=$REPO_ROOT/required-env-keys.txt}"
  : "${ENV_FILE:=$DEPLOY_ROOT/.env}"
fi

# ── the manifest ─────────────────────────────────────────────────────────────────
[ -f "$MANIFEST" ] || { err "ERROR: no manifest at $MANIFEST"; exit 2; }

# Anything that is neither a comment nor a bare key is a typo, and a typo here is a key
# that is silently not required. Fail closed on it — the same rule render-env.sh applies
# to the versions file, for the same reason.
manifest_lines="$(tr -d '\r' < "$MANIFEST" | sed 's/[[:space:]]*$//')"
malformed="$(printf '%s\n' "$manifest_lines" | grep -vE '^[[:space:]]*(#|$)' | grep -vE '^[A-Za-z_][A-Za-z0-9_]*$' || true)"
if [ -n "$malformed" ]; then
  err "ERROR: $MANIFEST has lines that are neither a comment nor a key name:"
  printf '%s\n' "$malformed" | sed 's/^/  /' >&2
  exit 2
fi
required="$(printf '%s\n' "$manifest_lines" | grep -E '^[A-Za-z_][A-Za-z0-9_]*$' | awk '!seen[$0]++' || true)"
if [ -z "$required" ]; then
  err "ERROR: $MANIFEST names no keys — refusing to report an all-clear over an empty list."
  exit 2
fi

# Keys the versions file owns are never the vault's to deliver (SERV-94/96) and never
# belong in the manifest: render-env.sh appends them from git on every render, so
# requiring one here would gate a deploy on a file that cannot fail to have it. Read
# so they can be excluded from the "unlisted" report, and refused in the manifest.
versioned="$( [ -f "$VERSIONS" ] && grep -oE '^[A-Za-z_][A-Za-z0-9_]*' "$VERSIONS" | sort -u || true)"
if [ -n "$versioned" ]; then
  owned="$(comm -12 <(printf '%s\n' "$required" | sort -u) <(printf '%s\n' "$versioned"))"
  if [ -n "$owned" ]; then
    err "ERROR: $MANIFEST lists key(s) that $(basename "$VERSIONS") owns:"
    printf '%s\n' "$owned" | sed 's/^/  /' >&2
    err "Those are image pins, tracked in git and rendered by render-env.sh on every deploy."
    err "They are not delivered by the vault and cannot go missing the way a credential can."
    exit 2
  fi
fi

# ── the environment: key<TAB>state, never a value ────────────────────────────────
if [ "$VAULT" -eq 1 ]; then
  command -v signet >/dev/null 2>&1 || {
    err "ERROR: signet is not on PATH — --vault asks the host vault and cannot answer without it."
    exit 2
  }
  if ! status="$(signet status --project "$PROJECT" 2>&1)"; then
    err "ERROR: signet status failed for project $PROJECT:"
    printf '%s\n' "$status" | sed 's/^/  /' >&2
    exit 2
  fi
  # A row is `PROJECT SECRET VHASH STATUS EXPIRES TARGETS…`; a secret delivered to
  # several places lists them comma-separated, so match the render target as one token
  # — `gh-render:` through to `→SECRET` with no space or comma between — rather than
  # two separate substrings that a different pair of targets could also satisfy.
  states="$(awk -v p="$PROJECT" -v dest="$RENDER_SECRET" '
    $1 == p && $0 ~ ("gh-render:[^ ,]*" dest) { print $2 "\tset" }
  ' <<< "$status")"
  SOURCE="the $PROJECT vault's render of $RENDER_SECRET"
  if [ -z "$states" ]; then
    err "ERROR: the vault delivers no keys through $RENDER_SECRET for project $PROJECT."
    err "Either the render target is gone or signet's output changed shape; neither is an all-clear."
    exit 2
  fi
else
  [ -f "$ENV_FILE" ] || { err "ERROR: no environment file at $ENV_FILE"; exit 2; }
  # Compose's rules where they change the answer: the last of duplicate keys wins, and
  # a value that is only a pair of matching quotes is empty. The value never leaves awk.
  states="$(awk '
    /^[A-Za-z_][A-Za-z0-9_]*=/ {
      eq = index($0, "=")
      key = substr($0, 1, eq - 1)
      val = substr($0, eq + 1)
      sub(/\r$/, "", val)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
      n = length(val)
      if (n >= 2) {
        first = substr(val, 1, 1); last = substr(val, n, 1)
        if ((first == "\"" || first == "\047") && first == last) val = substr(val, 2, n - 2)
      }
      state[key] = (val == "" ? "empty" : "set")
    }
    END { for (k in state) print k "\t" state[k] }
  ' "$ENV_FILE")"
  SOURCE="$ENV_FILE"
fi

# ── required vs present ──────────────────────────────────────────────────────────
missing=""
empty=""
present=0
while IFS= read -r key; do
  [ -n "$key" ] || continue
  state="$(awk -F'\t' -v k="$key" '$1 == k { print $2; exit }' <<< "$states")"
  case "$state" in
    set) present=$((present + 1)) ;;
    empty) empty="$empty$key"$'\n' ;;
    *) missing="$missing$key"$'\n' ;;
  esac
done <<< "$required"

# ── delivered but unlisted: a warning, by the ORDERING argument above ────────────
# Excludes the pins, which git delivers, and which no manifest should have to name.
unlisted="$(comm -23 <(cut -f1 <<< "$states" | sort -u) \
                    <(printf '%s\n%s\n' "$required" "$versioned" | grep . | sort -u))"
# One line, however many there are: this prints on every deploy until the vault is
# tidied, and a block of thirty names on each run is what teaches people to skip the
# step. The names are still all there.
if [ -n "$unlisted" ]; then
  echo "note: $SOURCE carries $(printf '%s\n' "$unlisted" | grep -c .) key(s) that $(basename "$MANIFEST") does not list —"
  echo "      delivered but unprotected (a rewrite that drops one passes this check). List the ones"
  echo "      the stack reads; retire the rest: $(printf '%s\n' "$unlisted" | paste -sd, - | sed 's/,/, /g')"
fi

# ── compose references with no default that the environment does not set ────────
# The complement of the manifest's blind spot. A `${KEY}` with no default interpolates
# to blank when unset — compose warns and continues, which is the empty-env invariant
# arriving through a different door. Anything so referenced that is neither set nor
# listed is named here, as a warning: a profile-gated service that is deliberately not
# deployed (authentik, `identity`) references two of these on every deploy, and the raw
# file cannot tell that service from a live one. Comments are stripped first — the
# file's comments quote interpolation syntax to explain it.
if [ "$VAULT" -eq 0 ]; then
  compose="$REPO_ROOT/$([ "$DEV" -eq 1 ] && echo docker-compose.dev.yml || echo docker-compose.yml)"
  if [ -f "$compose" ]; then
    nodefault="$(grep -vE '^[[:space:]]*#' "$compose" | grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' | tr -d '${}' | sort -u)"
    unset_refs="$(comm -23 <(printf '%s\n' "$nodefault") \
                          <(printf '%s\n%s\n%s\n' "$(cut -f1 <<< "$states")" "$required" "$versioned" | grep . | sort -u))"
    if [ -n "$unset_refs" ]; then
      echo "note: $(basename "$compose") reads $(printf '%s\n' "$unset_refs" | grep -c .) key(s) with no default that $SOURCE does not set —"
      echo "      each interpolates to blank. If the service reading it is deployed, that is a missing"
      echo "      credential (vault, then $(basename "$MANIFEST")): $(printf '%s\n' "$unset_refs" | paste -sd, - | sed 's/,/, /g')"
    fi
  fi
fi

echo
if [ -n "$missing$empty" ]; then
  err "ERROR: $SOURCE is missing required key(s) for the $TIER stack:"
  [ -z "$missing" ] || printf '%s' "$missing" | sed 's/^/  - /; s/$/  (absent)/' >&2
  [ -z "$empty" ]   || printf '%s' "$empty"   | sed 's/^/  - /; s/$/  (present, empty)/' >&2
  err ""
  err "Every key in $(basename "$MANIFEST") must reach the deployed .env with a value. The"
  err "services that read these boot without them — with the feature off, or with a blank"
  err "credential — which is why this fails the deploy before anything is pulled or recreated."
  err ""
  err "$RENDER_SECRET is rendered by Signet from the $PROJECT vault. Fix it there, never with"
  err "\`gh secret set\`, which the next \`signet sync\` reverts (that is how the 2026-09-06"
  err "restore of LYCEUM_BINDERY_API_KEY was lost):"
  err "  signet set --project $PROJECT --name KEY"
  err "  signet target add-key --project $PROJECT --gh-secret $RENDER_SECRET --name KEY"
  err "  signet sync"
  err "  ./scripts/assert-env-keys.sh$([ "$DEV" -eq 1 ] && echo " --dev") --vault    # before the deploy that renders it"
  exit 1
fi

echo "All $present required $TIER key(s) in $(basename "$MANIFEST") are present with a value in $SOURCE."
