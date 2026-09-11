#!/usr/bin/env bash
# check-base-images.sh — Fail on a base image that is past end-of-life or floating (SERV-170).
#
# Every first-party service builds FROM a public base image, and nothing used to ask
# whether that image was still receiving security updates. A survey on 2026-09-05 found
# four repos on alpine:3.20 (EOL 2026-04-01), two on node:20 (EOL 2026-04-30), one Go
# builder on 1.24 and another on 1.25 (both out of Go's two-release window), three nginx
# runtimes on 1.27 (EOL 2025-06-24), and two tags that named no version at all. None of
# it was visible from anywhere: an EOL base image builds, passes CI, deploys and reports
# healthy — the only difference is that `apk add` and `apt-get install` resolve against a
# branch nobody patches any more. This script is what makes that state loud.
#
# TWO RULES, checked against endoflife.date rather than a table kept here:
#
#   1. NOT PAST END-OF-LIFE. The tag's version is mapped onto a release cycle of the
#      product behind the image (alpine 3.23, nodejs 24, go 1.26, ...) and that cycle's
#      `isEol` must be false. A cycle whose EOL is inside the warning window is reported
#      but does not fail — the point is to see it coming.
#
#   2. NOT FLOATING. The tag must name the version to at least the product's cycle
#      precision: `alpine:3.23` and `node:24-alpine` are pinned, `alpine:3`, `nginx:alpine`
#      and `node:latest` are not. A floating tag is an image that changes underneath a
#      rebuild with nothing in the diff to show it — the opposite of what versions.env
#      exists to give this estate — and it cannot be evaluated by rule 1 either, since it
#      names no cycle. A digest (`@sha256:…`) satisfies this rule on its own.
#
# The policy data is endoflife.date's v1 API and NOT a table in this file. A table is
# exactly the thing that goes stale — that is what happened to the Dockerfiles. The cost
# is a network dependency: when the API cannot be reached the script exits 2, never 0,
# because "could not check" must not read as "checked and fine". BASE_IMAGE_POLICY_DIR
# points at cached product JSON for offline runs and the self-test.
#
# WHAT IT REFUSES RATHER THAN GUESSES (exit 1, same as a finding):
#   - an image repo with no entry in PRODUCT_MAP below — add the mapping, do not skip it;
#   - a tag whose version is not a cycle endoflife.date knows;
#   - a `FROM ${VAR}` whose ARG default is not declared earlier in the same file;
#   - in --estate mode, a repo whose tree could not be read (token lacks access).
#
# USAGE
#   check-base-images.sh <Dockerfile>...           check the named files
#   check-base-images.sh --dir <path>              every Dockerfile under a tree (~/projects)
#   check-base-images.sh --estate [compose.yml]    every Dockerfile on the default branch of
#                                                  every first-party repo, read via `gh api`.
#                                                  Repos are derived from the compose file's
#                                                  ghcr.io images plus EXTRA_REPOS.
#   check-base-images.sh --self-test               prove the script can FAIL (see below)
#
# ENV
#   BASE_IMAGE_WARN_DAYS   warn when EOL is within this many days (default 90)
#   BASE_IMAGE_POLICY_DIR  read <product>.json from here instead of the API
#   BASE_IMAGE_TODAY       YYYY-MM-DD, overrides the clock (self-test)
#   GH_TOKEN / GITHUB_TOKEN  what `gh api` authenticates with in --estate mode
#
# EXIT CODES
#   0  every base image is a pinned, supported cycle
#   1  at least one finding (EOL, floating, or unevaluable)
#   2  usage error, missing dependency, or the policy source was unreachable
#
# A guard that fails closed is only worth having if it is known to fail at all, so
# `--self-test` builds a fixture policy and a fixture Dockerfile and asserts that an EOL
# tag, a floating tag and an unmapped image each produce exit 1 while a clean file
# produces exit 0. The workflow runs it before the real check.

set -euo pipefail

err() { printf '%s\n' "$*" >&2; }
die() { err "ERROR: $*"; exit 2; }

for dep in jq curl; do
  command -v "$dep" >/dev/null 2>&1 || die "required dependency '$dep' not found in PATH"
done

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd)"

WARN_DAYS="${BASE_IMAGE_WARN_DAYS:-90}"
TODAY="${BASE_IMAGE_TODAY:-$(date -u +%F)}"
API="${BASE_IMAGE_API:-https://endoflife.date/api/v1/products}"
GITHUB_OWNER="Einlanzerous"

# Image repository -> endoflife.date product. Keyed on the repo as written in FROM with
# the docker.io/library/ prefix normalised away. A repo missing here is a FINDING, not a
# skip: the whole point is that nothing in a Dockerfile goes unexamined.
#
# `gcr.io/distroless/*` is handled in product_for(): its images carry the Debian release
# in the name (`static-debian12`) and follow that cycle.
declare -A PRODUCT_MAP=(
  [alpine]=alpine-linux
  [node]=nodejs
  [golang]=go
  [nginx]=nginx
  [debian]=debian
  [ubuntu]=ubuntu
  [oven/bun]=bun
  [postgres]=postgresql
  [redis]=redis
  [python]=python
)

# Repos with no first-party image in the compose file, which therefore cannot be
# discovered from it. Mirrors EXTRA_REPOS in wiki/generate/sources/repos.ts, plus
# cta-watch, which is first-party but not deployed on this stack.
EXTRA_REPOS=(construct-server cta-watch)

# Images whose ghcr.io name is not the repo that builds them.
declare -A IMAGE_REPO_OVERRIDES=(
  [estate-asr]=chronicle
)

# ── policy ───────────────────────────────────────────────────────────────────────────

POLICY_DIR="${BASE_IMAGE_POLICY_DIR:-}"
if [ -z "$POLICY_DIR" ]; then
  POLICY_DIR="$(mktemp -d)"
  trap 'rm -rf "$POLICY_DIR"' EXIT
  POLICY_FROM_API=1
else
  POLICY_FROM_API=0
fi

# Fetch (or read) one product's release list. Cached per run so one product is asked
# for once however many images use it. Unreachable API is exit 2 — see the header.
policy_file() {
  local product="$1" f="$POLICY_DIR/$product.json"
  if [ ! -s "$f" ]; then
    [ "$POLICY_FROM_API" = 1 ] || die "no policy for '$product' in $POLICY_DIR"
    local code
    code="$(curl -sS --retry 2 --max-time 20 -o "$f" -w '%{http_code}' "$API/$product" || true)"
    if [ "$code" != "200" ] || ! jq -e '.result.releases | length > 0' "$f" >/dev/null 2>&1; then
      rm -f "$f"
      die "could not fetch policy for '$product' from $API/$product (HTTP ${code:-none}) — refusing to report green"
    fi
  fi
  printf '%s' "$f"
}

# How many dotted components a cycle name carries for this product (alpine "3.23" -> 2,
# nodejs "24" -> 1). Read from the data, not assumed.
cycle_precision() {
  jq -r '.result.releases[0].name | split(".") | length' "$(policy_file "$1")"
}

# ── image parsing ────────────────────────────────────────────────────────────────────

# Normalise a FROM reference into "repo|tag|digest".
split_ref() {
  local ref="$1" digest="" tag="" repo
  case "$ref" in *@sha256:*) digest="${ref##*@}"; ref="${ref%%@*}";; esac
  # A ':' after the last '/' is the tag; one before it is a registry port.
  local last="${ref##*/}"
  if [[ "$last" == *:* ]]; then
    tag="${last##*:}"; repo="${ref%:*}"
  else
    repo="$ref"
  fi
  repo="${repo#docker.io/}"; repo="${repo#library/}"
  printf '%s|%s|%s' "$repo" "$tag" "$digest"
}

# endoflife.date product for a repo, and — for distroless — the cycle implied by the
# name. Prints "product|forced_cycle"; empty product means unmapped.
product_for() {
  local repo="$1"
  if [[ "$repo" =~ ^gcr\.io/distroless/.*-debian([0-9]+)$ ]]; then
    printf 'debian|%s' "${BASH_REMATCH[1]}"; return
  fi
  printf '%s|' "${PRODUCT_MAP[$repo]:-}"
}

# Resolve a tag to a cycle name for the product. Prints the cycle, or one of:
#   FLOATING   the tag names fewer version components than the product's cycles
#   UNKNOWN    the version is not a cycle endoflife.date lists
tag_cycle() {
  local product="$1" tag="$2" pf prec
  pf="$(policy_file "$product")"
  prec="$(cycle_precision "$product")"
  [ -n "$tag" ] || { printf 'FLOATING'; return; }

  local ver=""
  if [[ "$tag" =~ ^v?([0-9]+(\.[0-9]+)*) ]]; then
    ver="${BASH_REMATCH[1]}"
  else
    # A codename (`trixie`, `noble`, `bookworm-slim`): first word, matched
    # case-insensitively against the release's codename.
    local word="${tag%%-*}"
    local cyc
    cyc="$(jq -r --arg w "$word" '.result.releases[] | select((.codename // "") | ascii_downcase | split(" ")[0] == ($w | ascii_downcase)) | .name' "$pf" | head -1)"
    if [ -n "$cyc" ]; then printf '%s' "$cyc"; else printf 'FLOATING'; fi
    return
  fi

  local n
  n="$(awk -F. '{print NF}' <<<"$ver")"
  if [ "$n" -lt "$prec" ]; then printf 'FLOATING'; return; fi
  local cycle
  cycle="$(cut -d. -f1-"$prec" <<<"$ver")"
  if jq -e --arg c "$cycle" '.result.releases[] | select(.name == $c)' "$pf" >/dev/null; then
    printf '%s' "$cycle"
  else
    printf 'UNKNOWN'
  fi
}

days_until() {
  local d="$1"
  echo $(( ( $(date -u -d "$d" +%s) - $(date -u -d "$TODAY" +%s) ) / 86400 ))
}

# ── findings ─────────────────────────────────────────────────────────────────────────

ERRORS=0
WARNINGS=0
ROWS=()   # "status<TAB>where<TAB>image<TAB>detail"

report() {
  local status="$1" where="$2" image="$3" detail="$4"
  ROWS+=("$status	$where	$image	$detail")
  case "$status" in
    EOL|FLOATING|UNMAPPED|UNKNOWN|UNRESOLVED) ERRORS=$((ERRORS + 1));;
    SOON) WARNINGS=$((WARNINGS + 1));;
  esac
  if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
    local file="${where%%:*}" line="${where##*:}" level=notice
    case "$status" in SOON) level=warning;; OK) level=;; *) level=error;; esac
    [ -n "$level" ] && printf '::%s file=%s,line=%s::%s %s — %s\n' "$level" "$file" "$line" "$status" "$image" "$detail"
  fi
  printf '%-10s %-50s %-45s %s\n' "$status" "$where" "$image" "$detail"
}

# "Dockerfile" throughout means any of `Dockerfile*`, `*.Dockerfile` or `Containerfile*`
# — interlock builds from docker/web.Dockerfile, which a bare `Dockerfile*` glob misses,
# and the 2026-09-05 survey missed it for exactly that reason.
#
# Check one Dockerfile's contents (on stdin) under a display name.
check_dockerfile() {
  local where_prefix="$1"
  declare -A args=()
  declare -A stages=()
  local lineno=0 line
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    # `ARG NAME=value` at any point before the FROM that uses it. Only the default is
    # knowable statically, which is also the value a bare `docker build` uses.
    if [[ "$line" =~ ^[[:space:]]*ARG[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      local v="${BASH_REMATCH[2]}"; v="${v%%[[:space:]]#*}"; v="${v//\"/}"; v="${v//\'/}"
      args["${BASH_REMATCH[1]}"]="$v"
      continue
    fi
    [[ "$line" =~ ^[[:space:]]*[Ff][Rr][Oo][Mm][[:space:]]+(.*)$ ]] || continue
    local rest="${BASH_REMATCH[1]}" tok ref="" alias=""
    local prev=""
    for tok in $rest; do
      if [ "$prev" = "AS" ] || [ "$prev" = "as" ]; then alias="$tok"; fi
      if [[ "$tok" != --* ]] && [ -z "$ref" ]; then ref="$tok"; fi
      prev="$tok"
    done
    [ -n "$alias" ] && stages["$alias"]=1
    local where="$where_prefix:$lineno"

    # Substitute ${VAR} / $VAR from declared ARG defaults.
    if [[ "$ref" == *'$'* ]]; then
      local unresolved=""
      while [[ "$ref" =~ \$\{?([A-Za-z_][A-Za-z0-9_]*)\}? ]]; do
        local name="${BASH_REMATCH[1]}"
        if [ -n "${args[$name]+x}" ]; then
          ref="${ref//\$\{$name\}/${args[$name]}}"; ref="${ref//\$$name/${args[$name]}}"
        else
          unresolved="$name"; break
        fi
      done
      if [ -n "$unresolved" ]; then
        report UNRESOLVED "$where" "$ref" "\$$unresolved has no ARG default earlier in the file"
        continue
      fi
    fi

    [ "$ref" = "scratch" ] && continue
    [ -n "${stages[$ref]+x}" ] && continue   # FROM <earlier stage>

    local repo tag digest
    IFS='|' read -r repo tag digest <<<"$(split_ref "$ref")"
    local product forced
    IFS='|' read -r product forced <<<"$(product_for "$repo")"
    if [ -z "$product" ]; then
      report UNMAPPED "$where" "$ref" "no endoflife.date product mapped for '$repo' — add it to PRODUCT_MAP"
      continue
    fi

    local cycle
    if [ -n "$forced" ]; then cycle="$forced"; else cycle="$(tag_cycle "$product" "$tag")"; fi
    case "$cycle" in
      FLOATING)
        if [ -n "$digest" ]; then
          report UNKNOWN "$where" "$ref" "digest-pinned, but the tag names no $product cycle so its support status cannot be checked"
        else
          report FLOATING "$where" "$ref" "tag names no $product cycle (needs $(cycle_precision "$product")-component version, e.g. $(jq -r '[.result.releases[] | select(.isEol == false)] | first | .name' "$(policy_file "$product")"))"
        fi
        continue;;
      UNKNOWN)
        report UNKNOWN "$where" "$ref" "'$tag' is not a $product cycle endoflife.date lists"
        continue;;
    esac

    local pf is_eol eol_from
    pf="$(policy_file "$product")"
    is_eol="$(jq -r --arg c "$cycle" '.result.releases[] | select(.name == $c) | .isEol' "$pf")"
    eol_from="$(jq -r --arg c "$cycle" '.result.releases[] | select(.name == $c) | .eolFrom // empty' "$pf")"
    local newest
    newest="$(jq -r '[.result.releases[] | select(.isEol == false)] | first | .name' "$pf")"

    # isEol is endoflife.date's own verdict, but it is computed against ITS clock; the
    # date comparison below is what makes BASE_IMAGE_TODAY meaningful and what catches
    # a cycle whose eolFrom has passed since the JSON was cached.
    if [ "$is_eol" = "true" ] || { [ -n "$eol_from" ] && [ "$(days_until "$eol_from")" -lt 0 ]; }; then
      report EOL "$where" "$ref" "$product $cycle reached end-of-life ${eol_from:-(unknown date)}; newest supported is $newest"
    elif [ -n "$eol_from" ] && [ "$(days_until "$eol_from")" -le "$WARN_DAYS" ]; then
      report SOON "$where" "$ref" "$product $cycle reaches end-of-life $eol_from ($(days_until "$eol_from") days); newest supported is $newest"
    else
      report OK "$where" "$ref" "$product $cycle supported${eol_from:+ until $eol_from}"
    fi
  done
}

# ── inputs ───────────────────────────────────────────────────────────────────────────

# Every first-party repo: the ghcr.io images in the compose file map onto repos the same
# way verify-tag.sh and the wiki derive them, so a new service needs no edit here.
estate_repos() {
  local compose="$1"
  {
    grep -oE 'image: *ghcr\.io/einlanzerous/[a-z0-9_-]+' "$compose" \
      | sed -E 's#.*ghcr\.io/einlanzerous/##' \
      | while read -r img; do printf '%s\n' "${IMAGE_REPO_OVERRIDES[$img]:-$img}"; done
    printf '%s\n' "${EXTRA_REPOS[@]}"
  } | sort -u
}

check_estate() {
  local compose="${1:-$REPO_ROOT/docker-compose.yml}"
  [ -f "$compose" ] || die "no compose file at $compose"
  command -v gh >/dev/null 2>&1 || die "required dependency 'gh' not found in PATH (needed for --estate)"
  local repo paths path body n=0
  while read -r repo; do
    # HEAD on the trees API is the default branch. A repo that cannot be read is a
    # finding: a token that silently skips the private repos would report green on an
    # estate it only half examined.
    if ! paths="$(gh api "repos/$GITHUB_OWNER/$repo/git/trees/HEAD?recursive=1" \
        --jq '.tree[] | select(.type=="blob") | .path | select(test("(^|/)(Dockerfile[^/]*|[^/]+\\.Dockerfile|Containerfile[^/]*)$")) | select(test("(^|/)(node_modules|vendor)/") | not)' 2>&1)"; then
      report UNRESOLVED "$repo:0" "$repo" "could not read the repo tree via gh api (${paths//$'\n'/ }) — does the token have access?"
      continue
    fi
    [ -n "$paths" ] || { printf '%-10s %-50s %s\n' "-" "$repo" "no Dockerfile"; continue; }
    while read -r path; do
      body="$(gh api "repos/$GITHUB_OWNER/$repo/contents/$path" -H 'Accept: application/vnd.github.raw+json')" \
        || { report UNRESOLVED "$repo/$path:0" "$path" "could not read the file via gh api"; continue; }
      n=$((n + 1))
      check_dockerfile "$repo/$path" <<<"$body"
    done <<<"$paths"
  done < <(estate_repos "$compose")
  [ "$n" -gt 0 ] || die "no Dockerfiles found across the estate — that is not a clean result"
}

check_files() {
  local f
  [ $# -gt 0 ] || die "no Dockerfiles given"
  for f in "$@"; do
    [ -f "$f" ] || die "no such file: $f"
    check_dockerfile "$f" <"$f"
  done
}

check_dir() {
  local root="$1"
  [ -d "$root" ] || die "no such directory: $root"
  local files
  mapfile -t files < <(find "$root" -type d \( -name node_modules -o -name vendor -o -name .git \) -prune -o \
    -type f \( -name 'Dockerfile*' -o -name '*.Dockerfile' -o -name 'Containerfile*' \) -print | sort)
  [ "${#files[@]}" -gt 0 ] || die "no Dockerfile* under $root — that is not a clean result"
  check_files "${files[@]}"
}

# ── self-test ────────────────────────────────────────────────────────────────────────

self_test() {
  local t rc fails=0
  t="$(mktemp -d)"
  mkdir -p "$t/policy"
  cat >"$t/policy/alpine-linux.json" <<'JSON'
{"result":{"name":"alpine-linux","releases":[
 {"name":"3.23","codename":null,"isEol":false,"eolFrom":"2027-11-01"},
 {"name":"3.22","codename":null,"isEol":false,"eolFrom":"2026-11-01"},
 {"name":"3.20","codename":null,"isEol":true,"eolFrom":"2026-04-01"}]}}
JSON
  cat >"$t/policy/nginx.json" <<'JSON'
{"result":{"name":"nginx","releases":[{"name":"1.30","codename":null,"isEol":false,"eolFrom":null}]}}
JSON
  cat >"$t/policy/debian.json" <<'JSON'
{"result":{"name":"debian","releases":[{"name":"13","codename":"Trixie","isEol":false,"eolFrom":"2030-06-30"},{"name":"12","codename":"Bookworm","isEol":false,"eolFrom":"2028-06-30"}]}}
JSON
  cat >"$t/policy/ubuntu.json" <<'JSON'
{"result":{"name":"ubuntu","releases":[{"name":"24.04","codename":"Noble Numbat","isEol":false,"eolFrom":"2029-05-31"}]}}
JSON

  run_case() {
    local name="$1" expect="$2" expect_status="$3" out
    local file="$t/$name.Dockerfile"
    cat >"$file"
    set +e
    out="$(BASE_IMAGE_POLICY_DIR="$t/policy" BASE_IMAGE_TODAY=2026-09-11 GITHUB_ACTIONS= "$0" "$file" 2>&1)"; rc=$?
    set -e
    if [ "$rc" = "$expect" ] && { [ -z "$expect_status" ] || grep -q "^$expect_status " <<<"$out"; }; then
      printf '  ok    %-28s exit %s%s\n' "$name" "$rc" "${expect_status:+ ($expect_status)}"
    else
      printf '  FAIL  %-28s expected exit %s%s, got %s:\n%s\n' "$name" "$expect" "${expect_status:+ with $expect_status}" "$rc" "$out"
      fails=$((fails + 1))
    fi
  }

  echo "self-test: the guard must be able to fail"
  run_case clean 0 OK <<'EOF'
FROM alpine:3.23 AS build
FROM build AS test
FROM gcr.io/distroless/static-debian12:nonroot
FROM scratch
EOF
  run_case eol 1 EOL <<'EOF'
FROM alpine:3.20
EOF
  run_case floating-major-only 1 FLOATING <<'EOF'
FROM alpine:3
EOF
  run_case floating-no-version 1 FLOATING <<'EOF'
FROM nginx:alpine
EOF
  run_case unmapped 1 UNMAPPED <<'EOF'
FROM example.com/nobody/mystery:1.0
EOF
  run_case unknown-cycle 1 UNKNOWN <<'EOF'
FROM alpine:9.99
EOF
  run_case eol-soon-warns-only 0 SOON <<'EOF'
FROM alpine:3.22
EOF
  run_case codename-pinned 0 OK <<'EOF'
FROM debian:trixie-slim
EOF
  run_case arg-resolved 0 OK <<'EOF'
ARG UBUNTU=24.04
FROM ubuntu:${UBUNTU} AS sdk
EOF
  run_case arg-unresolved 1 UNRESOLVED <<'EOF'
FROM ubuntu:${UBUNTU}
EOF
  run_case platform-flag-and-digest 0 OK <<'EOF'
FROM --platform=linux/amd64 alpine:3.23@sha256:0000000000000000000000000000000000000000000000000000000000000000 AS x
EOF
  # Missing policy must be exit 2, never 0.
  set +e
  BASE_IMAGE_POLICY_DIR="$t/nowhere" "$0" "$t/clean.Dockerfile" >/dev/null 2>&1; rc=$?
  set -e
  if [ "$rc" = 2 ]; then printf '  ok    %-28s exit 2\n' "policy-unavailable"; else printf '  FAIL  policy-unavailable expected exit 2, got %s\n' "$rc"; fails=$((fails + 1)); fi

  rm -rf "$t"
  if [ "$fails" -gt 0 ]; then err "self-test: $fails case(s) failed"; exit 1; fi
  echo "self-test: passed"
}

# ── main ─────────────────────────────────────────────────────────────────────────────

case "${1:-}" in
  --self-test) self_test; exit 0;;
  --estate)    shift; check_estate "${1:-}";;
  --dir)       shift; [ -n "${1:-}" ] || die "--dir needs a path"; check_dir "$1";;
  -h|--help|"") sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'; exit 2;;
  *)           check_files "$@";;
esac

echo
if [ "$POLICY_FROM_API" = 1 ]; then policy_src="$API"; else policy_src="$POLICY_DIR"; fi
echo "base images: $ERRORS finding(s), $WARNINGS warning(s), $(( ${#ROWS[@]} - ERRORS - WARNINGS )) ok (policy: $policy_src, today: $TODAY)"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "## Base images"
    echo
    echo "| status | where | image | detail |"
    echo "|---|---|---|---|"
    for r in "${ROWS[@]}"; do
      IFS=$'\t' read -r s w i d <<<"$r"
      printf '| %s | `%s` | `%s` | %s |\n' "$s" "$w" "$i" "$d"
    done
  } >>"$GITHUB_STEP_SUMMARY"
fi

[ "$ERRORS" -eq 0 ]
