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
#      names no cycle. A digest (`@sha256:…`) satisfies rule 2 on its own: it is the pin.
#      It does NOT satisfy rule 1. A digest-pinned ref whose tag names no cycle
#      (`alpine@sha256:…`) is UNKNOWN, exit 1: the pin is real but nothing says whether
#      the image behind it still gets security updates, and "could not tell" is a
#      finding here. A digest on a tag that does name a cycle (`alpine:3.23@sha256:…`)
#      is checked like any other ref.
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
#   - a digest-pinned ref whose tag names no cycle (UNKNOWN: pinned, but rule 1 cannot run);
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
#   --json                 print one JSON document (schema 1) to stdout; the human table, the
#                          footer and gh's noise go to stderr
#   --json-out FILE        write the same document to FILE (the human output stays on stdout)
#   --public-only          --estate only: publish only repos the PRIVACY_GH_TOKEN can see as
#                          public (see MACHINE-READABLE OUTPUT)
#
# ENV
#   BASE_IMAGE_WARN_DAYS   warn when EOL is within this many days (default 90)
#   BASE_IMAGE_POLICY_DIR  read <product>.json from here instead of the API
#   BASE_IMAGE_TODAY       YYYY-MM-DD, overrides the clock (self-test)
#   GH_TOKEN / GITHUB_TOKEN  what `gh api` authenticates with in --estate mode
#   PRIVACY_GH_TOKEN       --public-only: the token that decides which repos are public. It must
#                          be one that cannot read private repos (a 404 is the answer for them);
#                          there is no fallback to GH_TOKEN, which can read them
#
# EXIT CODES (the PROCESS exit; --json and --json-out never change it)
#   0  every base image is a pinned, supported cycle
#   1  at least one finding (EOL, floating, or unevaluable)
#   2  usage error, missing dependency, or the policy source was unreachable. No document is
#      printed and any stale --json-out file is removed: an exit-2 run never leaves one behind.
#
# MACHINE-READABLE OUTPUT (SERV-294). The rule stays owned here and in docs/base-images.md;
# a consumer reads the document and does not copy the rule. Shape, null rules, the status
# vocabulary and the stability promise are in docs/base-images.md. In short: one object per
# FROM line in images[], `status` is one of OK SOON EOL FLOATING UNKNOWN UNMAPPED UNRESOLVED,
# an undeterminable field is null (never "" or 0), and in --estate mode repos[] says per repo
# whether it was read, partly read, unreadable, or has no Dockerfile. A repo or file that
# could not be read never becomes a row.
#
# --public-only is the privacy filter, run here so that no file or artifact ever holds private
# data. A repo is published only when `gh api repos/<owner>/<repo> --jq .private` made with
# PRIVACY_GH_TOKEN exits 0 and prints exactly `false`. A 404 or `true` withholds it (counted in
# summary.withheldRepos); any other answer withholds it and is itself a finding
# (summary.visibilityUnreadable), because "could not tell" must be loud. Withheld repos are
# still swept, so they still count toward the PROCESS exit and still appear in the human log
# (SERV-350); the document's summary and exit describe only what it publishes, so `exit: 0`
# means the public view is clean and says nothing about the estate.
#
# DEVIATION (SERV-294). A script with this much control flow wants a real language
# (PRINCIPLES section 1). The JSON mode extends the bash anyway, deliberately; the port is
# SERV-357.
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
# discovered from it: the two the wiki names in EXTRA_REPOS (wiki/generate/sources/
# repos.ts — this repo, and signet, a host binary with no Dockerfile today), plus
# cta-watch, which is first-party but not deployed on this stack. sextant is NOT here:
# its checkout has no remote, so only `--dir ~/projects` can reach it.
EXTRA_REPOS=(construct-server signet cta-watch)

# Images whose ghcr.io name is not the repo that builds them.
declare -A IMAGE_REPO_OVERRIDES=(
  [estate-asr]=chronicle
)

# ── policy ───────────────────────────────────────────────────────────────────────────

# Scratch space for the structured rows and the assembled document. Nothing here is a
# fixed path: a runner shares its $HOME and /tmp with every other job.
WORK="$(mktemp -d)"
POLICY_DIR="${BASE_IMAGE_POLICY_DIR:-}"
if [ -z "$POLICY_DIR" ]; then
  POLICY_DIR="$(mktemp -d)"
  POLICY_FROM_API=1
else
  POLICY_FROM_API=0
fi
cleanup() {
  rm -rf "$WORK"
  if [ "$POLICY_FROM_API" = 1 ]; then rm -rf "$POLICY_DIR"; fi
}
trap cleanup EXIT

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
OKS=0
ROWS=()   # "status<TAB>where<TAB>image<TAB>detail" — the human view, the step summary

# The document view. The structured fields of the FROM line being judged are set where the
# human row is built, from the same variables, so there is one definition of the rule and
# the document cannot drift from the table. Rows are buffered per repo and only a published
# repo's buffer reaches the document; an empty field is JSON null (never "" or 0).
RECORD_SEP=$'\x1f'   # between fields; not IFS whitespace, so empty fields survive `read`
PATH_SEP=$'\x1e'     # between unreadable paths inside one field
ROWS_BUF="$WORK/rows.buf"      # the repo being swept
ROWS_FILE="$WORK/rows"         # every published repo's rows
REPOS_FILE="$WORK/repos"       # every published repo's state
: >"$ROWS_BUF"; : >"$ROWS_FILE"; : >"$REPOS_FILE"
CUR_REPO=""; CUR_PATH=""
R_LINE=""; R_REF=""; R_IMAGE=""; R_TAG=""; R_DIGEST=""; R_PRODUCT=""
R_CYCLE=""; R_EOL=""; R_EST="false"; R_NEWEST=""
WITHHELD=0; VISUNREAD=0

row_reset() { R_LINE="$1"; R_REF=""; R_IMAGE=""; R_TAG=""; R_DIGEST=""; R_PRODUCT=""; R_CYCLE=""; R_EOL=""; R_EST="false"; R_NEWEST=""; }

record_row() {
  local status="$1" detail="$2"
  detail="${detail//[$'\n\r\x1f\x1e']/ }"
  printf '%s\n' "$CUR_REPO$RECORD_SEP$CUR_PATH$RECORD_SEP$R_LINE$RECORD_SEP$R_REF$RECORD_SEP$R_IMAGE$RECORD_SEP$R_TAG$RECORD_SEP$R_DIGEST$RECORD_SEP$R_PRODUCT$RECORD_SEP$R_CYCLE$RECORD_SEP$R_EOL$RECORD_SEP$R_EST$RECORD_SEP$R_NEWEST$RECORD_SEP$status$RECORD_SEP$detail" >>"$ROWS_BUF"
}

# Append the finished repo's buffer to the document's rows only when it is published.
flush_repo() {
  if [ "$1" = 1 ]; then cat "$ROWS_BUF" >>"$ROWS_FILE"; fi
  : >"$ROWS_BUF"
}

# Human row and counters, no document row. A repo or file that could not be read is a
# finding here and in the process exit, but it is not a FROM line: it never becomes an
# images[] row (and never a fake `line 0`); repos[] carries it.
emit() {
  local status="$1" where="$2" image="$3" detail="$4"
  ROWS+=("$status	$where	$image	$detail")
  case "$status" in
    EOL|FLOATING|UNMAPPED|UNKNOWN|UNRESOLVED) ERRORS=$((ERRORS + 1));;
    SOON) WARNINGS=$((WARNINGS + 1));;
    OK) OKS=$((OKS + 1));;
  esac
  if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
    local file="${where%%:*}" line="${where##*:}" level=notice
    case "$status" in SOON) level=warning;; OK) level=;; *) level=error;; esac
    [ -n "$level" ] && printf '::%s file=%s,line=%s::%s %s — %s\n' "$level" "$file" "$line" "$status" "$image" "$detail"
  fi
  printf '%-10s %-50s %-45s %s\n' "$status" "$where" "$image" "$detail"
}

# A judged FROM line: the human row and the document row.
report() {
  emit "$@"
  record_row "$1" "$4"
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
    row_reset "$lineno"

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
        R_REF="$ref"
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
    R_REF="$ref"; R_IMAGE="$repo"; R_TAG="$tag"; R_DIGEST="$digest"
    if [ -z "$product" ]; then
      report UNMAPPED "$where" "$ref" "no endoflife.date product mapped for '$repo' — add it to PRODUCT_MAP"
      continue
    fi

    local cycle pf newest
    pf="$(policy_file "$product")"
    newest="$(jq -r '[.result.releases[] | select(.isEol == false)] | first | .name' "$pf")"
    R_PRODUCT="$product"; R_NEWEST="$newest"
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

    R_CYCLE="$cycle"
    local is_eol eol_from
    is_eol="$(jq -r --arg c "$cycle" '.result.releases[] | select(.name == $c) | .isEol' "$pf")"
    eol_from="$(jq -r --arg c "$cycle" '.result.releases[] | select(.name == $c) | .eolFrom // empty' "$pf")"

    # isEol is endoflife.date's own verdict, but it is computed against ITS clock; the
    # date comparison below is what makes BASE_IMAGE_TODAY meaningful and what catches
    # a cycle whose eolFrom has passed since the JSON was cached.
    # Go and nginx publish no EOL date: a cycle is supported until the second-next one
    # ships, and endoflife.date carries eolFrom: null for every supported cycle of both.
    # A date-only warning would therefore never fire for two of the estate's commonest
    # base products and the guard would go straight from OK to EOL. So with no date, the
    # OLDEST supported cycle gets an ESTIMATED retirement: the newest cycle's release date
    # plus one release cadence, and warns inside the window. The cadence is the gap
    # between the oldest supported cycle and the one it replaced — NOT the gap to the
    # newest, because nginx ships its stable and mainline weeks apart (1.30 in April,
    # 1.31 in May) and that gap would put 1.30's retirement in the past. An estimate,
    # labelled as one; it is what makes "see it coming" true for Go.
    local est_eol=""
    if [ -z "$eol_from" ]; then
      local oldest_supported newest_rel oldest_rel prev_rel
      oldest_supported="$(jq -r '[.result.releases[] | select(.isEol == false)] | last | .name' "$pf")"
      if [ "$cycle" = "$oldest_supported" ] && [ "$cycle" != "$newest" ]; then
        newest_rel="$(jq -r --arg c "$newest" '.result.releases[] | select(.name == $c) | .releaseDate // empty' "$pf")"
        oldest_rel="$(jq -r --arg c "$cycle" '.result.releases[] | select(.name == $c) | .releaseDate // empty' "$pf")"
        prev_rel="$(jq -r --arg c "$cycle" '.result.releases as $r | ($r | map(.name) | index($c)) as $i | if $i != null and ($i + 1) < ($r | length) then ($r[$i + 1].releaseDate // empty) else empty end' "$pf")"
        if [ -n "$newest_rel" ] && [ -n "$oldest_rel" ] && [ -n "$prev_rel" ]; then
          local cadence
          cadence=$(( ( $(date -u -d "$oldest_rel" +%s) - $(date -u -d "$prev_rel" +%s) ) / 86400 ))
          est_eol="$(date -u -d "$newest_rel + $cadence days" +%F)"
        fi
      fi
    fi

    # The document's date is the published one, else the estimate, labelled as one.
    R_EOL="${eol_from:-$est_eol}"
    if [ -z "$eol_from" ] && [ -n "$est_eol" ]; then R_EST=true; fi

    if [ "$is_eol" = "true" ] || { [ -n "$eol_from" ] && [ "$(days_until "$eol_from")" -lt 0 ]; }; then
      report EOL "$where" "$ref" "$product $cycle reached end-of-life ${eol_from:-(unknown date)}; newest supported is $newest"
    elif [ -n "$eol_from" ] && [ "$(days_until "$eol_from")" -le "$WARN_DAYS" ]; then
      report SOON "$where" "$ref" "$product $cycle reaches end-of-life $eol_from ($(days_until "$eol_from") days); newest supported is $newest"
    elif [ -n "$est_eol" ] && [ "$(days_until "$est_eol")" -le "$WARN_DAYS" ]; then
      report SOON "$where" "$ref" "$product $cycle is the oldest supported cycle and publishes no EOL date; the next release retires it, estimated ~$est_eol from the release cadence; newest supported is $newest"
    else
      report OK "$where" "$ref" "$product $cycle supported${eol_from:+ until $eol_from}"
    fi
  done
}

# ── inputs ───────────────────────────────────────────────────────────────────────────

# Every first-party repo: the ghcr.io images in the compose file map onto repos the same
# way verify-tag.sh and the wiki derive them, so a new service needs no edit here.
estate_repos() {
  local compose="$1" derived
  # Case-insensitive and quote-tolerant, because a compose file accepts both and a
  # pattern that silently stopped matching would shrink the sweep to EXTRA_REPOS with
  # nothing going red — the one place this script could narrow to nothing. So the
  # derived list is asserted: matching no image at all is exit 2, not an empty result.
  derived="$(grep -oiE 'image: *["'"'"']?ghcr\.io/einlanzerous/[a-z0-9_-]+' "$compose" \
      | sed -E 's#.*[Ee][Ii][Nn][Ll][Aa][Nn][Zz][Ee][Rr][Oo][Uu][Ss]/##' | tr 'A-Z' 'a-z' || true)"
  [ -n "$derived" ] || die "no ghcr.io/einlanzerous images found in $compose — the repo list would be EXTRA_REPOS alone, refusing"
  {
    while read -r img; do printf '%s\n' "${IMAGE_REPO_OVERRIDES[$img]:-$img}"; done <<<"$derived"
    printf '%s\n' "${EXTRA_REPOS[@]}"
  } | sort -u
}

# Is this repo world-readable? Asked with PRIVACY_GH_TOKEN, a token that cannot read private
# repos: GitHub answers 404 for those, and a 200 `private:false` is itself the proof. The
# sweep token is deliberately not used, since it can read private repos and answers 200 for
# them. Fail closed: only an exit 0 printing exactly `false` is public. Prints one of
# public, private (404 or private:true) or unreadable (anything else: 5xx, rate limit,
# network, odd output).
repo_visibility() {
  local out errf="$WORK/vis.err" rc=0
  out="$(GH_TOKEN="$PRIVACY_GH_TOKEN" gh api "repos/$GITHUB_OWNER/$1" --jq .private 2>"$errf")" || rc=$?
  if [ "$rc" -eq 0 ]; then
    case "$out" in
      false) printf public;;
      true) printf private;;
      *) printf unreadable;;
    esac
  elif grep -q 'HTTP 404' "$errf"; then
    printf private
  else
    printf unreadable
  fi
}

check_estate() {
  local compose="${1:-$REPO_ROOT/docker-compose.yml}"
  [ -f "$compose" ] || die "no compose file at $compose"
  command -v gh >/dev/null 2>&1 || die "required dependency 'gh' not found in PATH (needed for --estate)"
  local repo paths path body n=0 published state failed ok_files unreadable_paths
  while read -r repo; do
    # Withheld repos are still swept below, so they still count toward the process exit
    # and still appear in the human log; only the document omits them.
    published=1
    if [ "$PUBLIC_ONLY" = 1 ]; then
      case "$(repo_visibility "$repo")" in
        public) ;;
        private) published=0; WITHHELD=$((WITHHELD + 1));;
        *) published=0; VISUNREAD=$((VISUNREAD + 1));;
      esac
    fi
    CUR_REPO="$repo"; CUR_PATH=""
    failed=0; ok_files=0; unreadable_paths=""
    # HEAD on the trees API is the default branch. A repo that cannot be read is a
    # finding: a token that silently skips the private repos would report green on an
    # estate it only half examined.
    if ! paths="$(gh api "repos/$GITHUB_OWNER/$repo/git/trees/HEAD?recursive=1" \
        --jq '.tree[] | select(.type=="blob") | .path | select(test("(^|/)(Dockerfile[^/]*|[^/]+\\.Dockerfile|Containerfile[^/]*)$")) | select(test("(^|/)(node_modules|vendor)/") | not)' 2>&1)"; then
      emit UNRESOLVED "$repo:0" "$repo" "could not read the repo tree via gh api (${paths//$'\n'/ }) — does the token have access?"
      state=unreadable
    elif [ -z "$paths" ]; then
      printf '%-10s %-50s %s\n' "-" "$repo" "no Dockerfile"
      state=no_dockerfile
    else
      while read -r path; do
        CUR_PATH="$path"
        if ! body="$(gh api "repos/$GITHUB_OWNER/$repo/contents/$path" -H 'Accept: application/vnd.github.raw+json')"; then
          emit UNRESOLVED "$repo/$path:0" "$path" "could not read the file via gh api"
          failed=$((failed + 1)); unreadable_paths="${unreadable_paths:+$unreadable_paths$PATH_SEP}$path"
          continue
        fi
        n=$((n + 1)); ok_files=$((ok_files + 1))
        check_dockerfile "$repo/$path" <<<"$body"
      done <<<"$paths"
      if [ "$failed" -eq 0 ]; then state=read
      elif [ "$ok_files" -eq 0 ]; then state=unreadable
      else state=partial
      fi
    fi
    if [ "$published" = 1 ]; then
      printf '%s\n' "$repo$RECORD_SEP$state$RECORD_SEP$unreadable_paths" >>"$REPOS_FILE"
    fi
    flush_repo "$published"
  done < <(estate_repos "$compose")
  [ "$n" -gt 0 ] || die "no Dockerfiles found across the estate — that is not a clean result"
  if [ "$PUBLIC_ONLY" = 1 ]; then
    # Counts only, never a name: this reaches the world-readable log.
    err "WITHHELD $WITHHELD repo(s) from the published document (not public)"
    if [ "$VISUNREAD" -gt 0 ]; then
      err "$VISUNREAD repo(s) with unreadable visibility, withheld and counted as findings"
      ERRORS=$((ERRORS + VISUNREAD))
    fi
  fi
}

check_files() {
  local f
  [ $# -gt 0 ] || die "no Dockerfiles given"
  for f in "$@"; do
    [ -f "$f" ] || die "no such file: $f"
    CUR_PATH="$f"
    check_dockerfile "$f" <"$f"
  done
  flush_repo 1
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

# The document and the privacy gate. Every assertion here can fail: a fixture the filter
# must withhold, a control run without the filter that must show it, an injected jq
# failure, an exit code that must not move. Returns non-zero when a case failed.
self_test_json() {
  local t="$1" fails=0 mock="$SCRIPT_DIR/test/mock-bin-base-images" rc
  local header_last='The workflow runs it before the real check.'
  local zeros=0000000000000000000000000000000000000000000000000000000000000000

  ok() { printf '  ok    %s\n' "$1"; }
  bad() { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }
  # assert NAME FILE JQ-FILTER: the filter must be true over the document.
  assert() {
    if jq -e "$3" "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1: jq filter false: $3"; fi
  }
  # child ENV... -- ARGS: a run of this script with the fixture policy and clock.
  child() { env GITHUB_ACTIONS= GITHUB_STEP_SUMMARY= BASE_IMAGE_POLICY_DIR="$t/policy" BASE_IMAGE_TODAY=2026-09-11 "$@"; }

  echo "self-test: the document"

  # One fixture, every status. Stdout is the document alone: it is captured WITHOUT 2>&1.
  cat >"$t/matrix.Dockerfile" <<EOF
FROM alpine:3.23
FROM alpine:3.20
FROM alpine:3
FROM alpine@sha256:$zeros
FROM alpine:3.22
FROM nginx:1.30-alpine
FROM golang:1.26-bookworm
FROM nginx:1.31-alpine
FROM example.com/nobody/mystery:1.0
FROM alpine:9.99
FROM ubuntu:\${NOARG}
EOF
  rc=0; child "$0" --json "$t/matrix.Dockerfile" >"$t/matrix.out.json" 2>"$t/matrix.err" || rc=$?
  if [ "$rc" = 1 ]; then ok "matrix: --json keeps process exit 1"; else bad "matrix: expected exit 1, got $rc"; fi
  assert "matrix: schema 1, files mode, unfiltered" "$t/matrix.out.json" \
    '.schema == 1 and .mode == "files" and .scope == "unfiltered" and .repos == null and .exit == 1'
  assert "matrix: golden top-level keys" "$t/matrix.out.json" \
    '(keys | sort) == ["exit","generatedAt","images","mode","policy","repos","schema","scope","summary","today"]'
  assert "matrix: golden summary keys" "$t/matrix.out.json" \
    '(.summary | keys | sort) == ["findings","ok","unreadableRepos","visibilityUnreadable","warnings","withheldRepos"]'
  assert "matrix: golden image keys on every row" "$t/matrix.out.json" \
    'all(.images[]; (keys | sort) == ["cycle","detail","digest","eolDate","eolDateEstimated","image","line","newestSupported","path","product","ref","repo","status","tag"])'
  # [status, cycle, eolDate, eolDateEstimated, newestSupported, image, tag, digest]
  assert "matrix: status, cycle, dates, newest, image, tag, digest per fixture" "$t/matrix.out.json" \
    '[.images[] | [.status, .cycle, .eolDate, .eolDateEstimated, .newestSupported, .image, .tag, .digest]] == [
      ["OK","3.23","2027-11-01",false,"3.23","alpine","3.23",null],
      ["EOL","3.20","2026-04-01",false,"3.23","alpine","3.20",null],
      ["FLOATING",null,null,false,"3.23","alpine","3",null],
      ["UNKNOWN",null,null,false,"3.23","alpine",null,"sha256:'"$zeros"'"],
      ["SOON","3.22","2026-11-01",false,"3.23","alpine","3.22",null],
      ["SOON","1.30","2026-09-29",true,"1.31","nginx","1.30-alpine",null],
      ["OK","1.26","2027-02-17",true,"1.27","golang","1.26-bookworm",null],
      ["OK","1.31",null,false,"1.31","nginx","1.31-alpine",null],
      ["UNMAPPED",null,null,false,null,"example.com/nobody/mystery","1.0",null],
      ["UNKNOWN",null,null,false,"3.23","alpine","9.99",null],
      ["UNRESOLVED",null,null,false,null,null,null,null]]'
  assert "matrix: nothing is coalesced to an empty string or 0" "$t/matrix.out.json" \
    '[.images[] | .. | strings | select(. == "")] == [] and all(.images[]; .line > 0)'
  local shown
  shown="$(grep -cE '^(OK|SOON|EOL|FLOATING|UNMAPPED|UNKNOWN|UNRESOLVED) ' "$t/matrix.err" || true)"
  if [ "$shown" = 11 ] && jq -e '.images | length == 11' "$t/matrix.out.json" >/dev/null; then
    ok "matrix: one object per FROM line the human output reports (11), on stderr"
  else bad "matrix: human rows on stderr $shown, expected 11 matching images[]"; fi
  assert "digest with no cycle (position 1): UNKNOWN, no cycle, digest kept" "$t/matrix.out.json" \
    '.images[3] | .status == "UNKNOWN" and .cycle == null and (.digest | startswith("sha256:"))'
  assert "summary reconciles with images" "$t/matrix.out.json" \
    '.summary == {findings: 6, warnings: 2, ok: 3, unreadableRepos: 0, withheldRepos: null, visibilityUnreadable: null}'

  # --json-out: the same bytes, human output stays on stdout.
  rc=0; child "$0" --json-out "$t/o.json" "$t/matrix.Dockerfile" >"$t/o.out" 2>/dev/null || rc=$?
  if [ "$rc" = 1 ] && jq -e '.schema == 1' "$t/o.json" >/dev/null 2>&1 && grep -q '^EOL ' "$t/o.out"; then
    ok "--json-out writes the file and leaves the table on stdout"
  else bad "--json-out: exit $rc, file/table not as expected"; fi

  # The digest wording agrees across the three texts (position 1).
  local phrase='digest-pinned ref whose tag names no cycle'
  local help_out
  help_out="$("$0" --help 2>&1 || true)"   # a captured value: grep -q on a pipe would SIGPIPE the writer under pipefail
  if grep -qF "$phrase" <<<"$help_out" && grep -qF "$phrase" "$REPO_ROOT/docs/base-images.md"; then
    ok "digest wording: header and docs/base-images.md say UNKNOWN for a digest with no cycle"
  else bad "digest wording: '$phrase' missing from --help or docs/base-images.md"; fi
  if grep -q 'a digest-pinned ref whose tag names no cycle (UNKNOWN' "$0"; then ok "digest wording: WHAT IT REFUSES lists it"
  else bad "digest wording: WHAT IT REFUSES omits the digest case"; fi

  # --help prints the whole header and keeps exit 2 (the usage exit).
  rc=0; "$0" --help >"$t/help.out" 2>/dev/null || rc=$?
  if [ "$rc" = 2 ] && grep -qF "$header_last" "$t/help.out"; then ok "--help: whole header, exit 2"
  else bad "--help: exit $rc, last header line present: $(grep -cF "$header_last" "$t/help.out")"; fi

  # Exit 2 prints nothing to stdout and leaves no file, even over a stale one.
  echo stale >"$t/stale.json"
  rc=0; env GITHUB_ACTIONS= GITHUB_STEP_SUMMARY= BASE_IMAGE_POLICY_DIR="$t/nowhere" "$0" --json --json-out "$t/stale.json" "$t/clean.Dockerfile" >"$t/x.out" 2>/dev/null || rc=$?
  if [ "$rc" = 2 ] && [ ! -s "$t/x.out" ] && [ ! -e "$t/stale.json" ]; then ok "policy unreachable: exit 2, empty stdout, stale --json-out removed"
  else bad "policy unreachable: exit $rc, stdout bytes $(wc -c <"$t/x.out"), file present: $([ -e "$t/stale.json" ] && echo yes || echo no)"; fi

  # An injected jq failure in the assembly is exit 2, never 1, with no document anywhere.
  rc=0; child env PATH="$mock:$PATH" MOCK_JQ_FAIL_ASSEMBLY=1 "$0" --json --json-out "$t/j.json" "$t/matrix.Dockerfile" >"$t/j.out" 2>/dev/null || rc=$?
  if [ "$rc" = 2 ] && [ ! -s "$t/j.out" ] && [ ! -e "$t/j.json" ]; then ok "jq assembly failure: exit 2, empty stdout, no file"
  else bad "jq assembly failure: exit $rc, stdout bytes $(wc -c <"$t/j.out"), file: $([ -e "$t/j.json" ] && echo yes || echo no)"; fi
  rc=0; child env PATH="$mock:$PATH" "$0" --json --json-out "$t/j2.json" "$t/matrix.Dockerfile" >"$t/j2.out" 2>/dev/null || rc=$?
  if [ "$rc" = 1 ] && [ -s "$t/j2.json" ]; then ok "jq shim is invisible without the variable (control)"
  else bad "jq shim control: exit $rc"; fi

  echo "self-test: estate states (mock gh)"
  local gh="$t/gh" compose
  mkdir -p "$gh"
  mk() { # repo visibility(false|true|404|500|none) [path=Dockerfile-body]... ; tree.fail via MK_TREE_FAIL=1; MK_FAIL_PATHS="a b"
    local repo="$1" vis="$2" pair path; shift 2
    mkdir -p "$gh/$repo/files" "$gh/$repo/fail"; : >"$gh/$repo/tree"
    [ "$vis" = none ] || printf '%s' "$vis" >"$gh/$repo/vis.public-token"
    [ "${MK_TREE_FAIL:-}" != 1 ] || : >"$gh/$repo/tree.fail"
    for pair in "$@"; do
      path="${pair%%=*}"; mkdir -p "$gh/$repo/files/$(dirname "$path")" "$gh/$repo/fail/$(dirname "$path")"
      printf '%s\n' "${pair#*=}" >"$gh/$repo/files/$path"; printf '%s\n' "$path" >>"$gh/$repo/tree"
    done
    for path in ${MK_FAIL_PATHS:-}; do : >"$gh/$repo/fail/$path"; done
  }
  compose_for() { local f="$t/compose-$1.yml"; shift; { echo "services:"; for r in "$@"; do echo "  $r:"; echo "    image: ghcr.io/einlanzerous/$r:1"; done; } >"$f"; printf '%s' "$f"; }
  # The three repos EXTRA_REPOS always adds. construct-server is public with one clean
  # Dockerfile; signet and cta-watch are public with none.
  mk construct-server false 'Dockerfile=FROM alpine:3.23'
  mk signet false
  mk cta-watch false

  mk fx-ok false 'Dockerfile=FROM alpine:3.23'
  mk fx-none false
  MK_TREE_FAIL=1 mk fx-unread false
  MK_FAIL_PATHS='docker/web.Dockerfile' mk fx-mixed false 'Dockerfile=FROM alpine:3.23' 'docker/web.Dockerfile=FROM alpine:3.23'
  MK_FAIL_PATHS='Dockerfile b.Dockerfile' mk fx-allfail false 'Dockerfile=FROM alpine:3.23' 'b.Dockerfile=FROM alpine:3.23'
  compose="$(compose_for states fx-ok fx-none fx-unread fx-mixed fx-allfail)"

  estate() { # out-prefix [flags...] — runs the estate fixture $compose; stdout, stderr, rc in files
    local o="$1"; shift
    rc=0; child env PATH="$mock:$PATH" MOCK_GH_DIR="$gh" GH_TOKEN=sweep-token PRIVACY_GH_TOKEN=public-token \
      "$0" "$@" --estate "$compose" >"$o.out" 2>"$o.err" || rc=$?
  }
  estate "$t/st" --json
  if [ "$rc" = 1 ]; then ok "states: process exit 1"; else bad "states: expected exit 1, got $rc"; fi
  assert "states: read, partial, unreadable, no_dockerfile, in repo order" "$t/st.out" \
    '[.repos[] | {(.repo): .state}] | add == {"construct-server":"read","cta-watch":"no_dockerfile","fx-allfail":"unreadable","fx-mixed":"partial","fx-none":"no_dockerfile","fx-ok":"read","fx-unread":"unreadable","signet":"no_dockerfile"}'
  assert "states: unreadablePaths names the failed paths, null otherwise" "$t/st.out" \
    '([.repos[] | select(.repo == "fx-mixed") | .unreadablePaths] == [["docker/web.Dockerfile"]])
     and ([.repos[] | select(.repo == "fx-allfail") | .unreadablePaths] == [["Dockerfile","b.Dockerfile"]])
     and ([.repos[] | select(.unreadablePaths == null) | .repo] | length == 6)'
  assert "states: an unreadable repo is not in images[]; a partial repo keeps its readable rows; no line 0" "$t/st.out" \
    '([.images[] | select(.repo == "fx-unread" or .repo == "fx-allfail")] | length == 0)
     and ([.images[] | select(.repo == "fx-mixed") | .path] == ["Dockerfile"])
     and all(.images[]; .line > 0)'
  assert "states: summary counts unreadable plus partial; document exit 1; unfiltered nulls" "$t/st.out" \
    '.exit == 1 and .scope == "unfiltered" and .summary == {findings: 3, warnings: 0, ok: 3, unreadableRepos: 3, withheldRepos: null, visibilityUnreadable: null}'
  rc=0; child env PATH="$mock:$PATH" MOCK_GH_DIR="$gh" GH_TOKEN=sweep-token "$0" --estate "$compose" >/dev/null 2>&1 || rc=$?
  if [ "$rc" = 1 ]; then ok "states: the plain run exits 1 too"; else bad "states: plain run exit $rc"; fi

  echo "self-test: privacy gate (mock gh)"
  # One public repo; a private one (404 for the low-privilege token) carrying an EOL image;
  # one reporting private:true; one whose visibility lookup fails with a 500.
  mk fx-pub false 'Dockerfile=FROM alpine:3.23'
  mk fx-priv404 none 'hiddenpath/Dockerfile=FROM alpine:3.20'
  mk fx-privflag true 'flagpath/Dockerfile=FROM alpine:3.23'
  mk fx-vis500 500 'v500path/Dockerfile=FROM nginx:1.31-alpine'
  compose="$(compose_for gate fx-pub fx-priv404 fx-privflag fx-vis500)"
  estate "$t/pg" --json --json-out "$t/pg.json" --public-only
  local pg_rc="$rc"
  if [ "$pg_rc" = 1 ]; then ok "gate: the failed lookup makes the process exit 1"; else bad "gate: expected exit 1, got $pg_rc"; fi
  assert "gate: only public repos appear in repos[] and images[]" "$t/pg.json" \
    '([.repos[].repo] == ["construct-server","cta-watch","fx-pub","signet"]) and ([.images[].repo] | unique == ["construct-server","fx-pub"]) and .scope == "public-only"'
  if ! grep -qE 'fx-priv|fx-vis500|hiddenpath|flagpath|v500path|alpine:3\.20|1\.31-alpine' "$t/pg.json" "$t/pg.out"; then
    ok "gate: withheld names, paths and images appear nowhere in stdout or the file"
  else bad "gate: a withheld repo, path or image leaked into the document"; fi
  if cmp -s "$t/pg.json" "$t/pg.out"; then ok "gate: --json and --json-out carry the same bytes"; else bad "gate: stdout and file differ"; fi
  assert "gate: withheldRepos and visibilityUnreadable match the fixture" "$t/pg.json" \
    '.summary.withheldRepos == 2 and .summary.visibilityUnreadable == 1'
  assert "gate: document exit 1 (an unreadable visibility is a finding), no finding rows" "$t/pg.json" \
    '.exit == 1 and .summary.findings == 0'
  if grep -q 'WITHHELD' "$t/pg.err" && grep -q 'unreadable visibility' "$t/pg.err"; then ok "gate: stderr says WITHHELD and counts the unreadable lookup"
  else bad "gate: stderr lacks the WITHHELD / unreadable visibility lines"; fi
  if ! grep -qE 'fx-priv|fx-vis500' <(grep -E 'WITHHELD|unreadable visibility' "$t/pg.err"); then ok "gate: the loud lines carry counts, not names"
  else bad "gate: a withheld name is in the WITHHELD lines"; fi

  # A private repo's EOL finding changes neither the summary nor the document exit.
  compose="$(compose_for gate2 fx-pub fx-priv404)"
  estate "$t/p2" --json --public-only
  if [ "$rc" = 1 ]; then ok "gate: a private EOL finding still turns the process exit red"; else bad "gate: private finding, process exit $rc (expected 1)"; fi
  assert "gate: ...while the document stays clean: exit 0, findings 0, withheld 1" "$t/p2.out" \
    '.exit == 0 and .summary.findings == 0 and .summary.withheldRepos == 1 and .summary.visibilityUnreadable == 0'
  # Control: the same estate without the filter shows it. Delete the filter and this goes red.
  estate "$t/p3" --json
  assert "gate control: without --public-only every repo is shown and the counts are null" "$t/p3.out" \
    '.scope == "unfiltered" and ([.repos[].repo] | index("fx-priv404") != null) and .summary.withheldRepos == null and .summary.visibilityUnreadable == null and .exit == 1'
  for d in "$t/pg" "$t/p2" "$t/p3"; do
    f="$d.out"; [ "$d" != "$t/pg" ] || f="$t/pg.json"
    assert "invariant ($(basename "$d")): findings = image-finding rows + unreadableRepos" "$f" \
      '.summary.findings == ([.images[] | select(.status | IN("EOL","FLOATING","UNMAPPED","UNKNOWN","UNRESOLVED"))] | length) + .summary.unreadableRepos'
  done
  # Document exit never exceeds the process exit.
  assert "invariant: document exit <= process exit (public-only, private finding)" "$t/p2.out" '.exit <= 1'

  rc=0; child env -u PRIVACY_GH_TOKEN PATH="$mock:$PATH" MOCK_GH_DIR="$gh" GH_TOKEN=sweep-token "$0" --json --public-only --estate "$compose" >"$t/np.out" 2>/dev/null || rc=$?
  if [ "$rc" = 2 ] && [ ! -s "$t/np.out" ]; then ok "--public-only without PRIVACY_GH_TOKEN: exit 2, empty stdout"; else bad "--public-only without a token: exit $rc"; fi
  rc=0; child env PATH="$mock:$PATH" MOCK_GH_DIR="$gh" GH_TOKEN=sweep-token PRIVACY_GH_TOKEN= "$0" --public-only --estate "$compose" >/dev/null 2>&1 || rc=$?
  if [ "$rc" = 2 ]; then ok "--public-only with a blank PRIVACY_GH_TOKEN: exit 2 (blank is not a value)"; else bad "blank token: exit $rc"; fi
  rc=0; child env PRIVACY_GH_TOKEN=public-token "$0" --public-only "$t/clean.Dockerfile" >/dev/null 2>&1 || rc=$?
  if [ "$rc" = 2 ]; then ok "--public-only outside --estate: exit 2"; else bad "--public-only on files: exit $rc"; fi

  return "$fails"
}

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
{"result":{"name":"nginx","releases":[
 {"name":"1.31","codename":null,"isEol":false,"eolFrom":null,"releaseDate":"2026-05-01"},
 {"name":"1.30","codename":null,"isEol":false,"eolFrom":null,"releaseDate":"2026-04-01"},
 {"name":"1.29","codename":null,"isEol":true,"eolFrom":"2026-05-13","releaseDate":"2025-11-01"}]}}
JSON
  cat >"$t/policy/go.json" <<'JSON'
{"result":{"name":"go","releases":[
 {"name":"1.27","codename":null,"isEol":false,"eolFrom":null,"releaseDate":"2026-08-19"},
 {"name":"1.26","codename":null,"isEol":false,"eolFrom":null,"releaseDate":"2026-02-10"},
 {"name":"1.25","codename":null,"isEol":true,"eolFrom":"2026-08-19","releaseDate":"2025-08-12"}]}}
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
    # GITHUB_STEP_SUMMARY is cleared as well as GITHUB_ACTIONS: the children would
    # otherwise append eleven fixture tables above the real sweep's in the run summary.
    out="$(BASE_IMAGE_POLICY_DIR="$t/policy" BASE_IMAGE_TODAY=2026-09-11 GITHUB_ACTIONS= GITHUB_STEP_SUMMARY= "$0" "$file" 2>&1)"; rc=$?
    set -e
    # The same fixture under --json: same process exit, and stdout alone is the document.
    local jrc=0
    BASE_IMAGE_POLICY_DIR="$t/policy" BASE_IMAGE_TODAY=2026-09-11 GITHUB_ACTIONS= GITHUB_STEP_SUMMARY= "$0" --json "$file" >"$t/$name.json" 2>/dev/null || jrc=$?
    if [ "$jrc" != "$rc" ]; then
      printf '  FAIL  %-28s --json exit %s differs from plain exit %s\n' "$name" "$jrc" "$rc"; fails=$((fails + 1))
    elif ! jq -e '.schema == 1 and (.images | type == "array")' "$t/$name.json" >/dev/null 2>&1; then
      printf '  FAIL  %-28s --json stdout is not one schema-1 document\n' "$name"; fails=$((fails + 1))
    elif [ "$rc" = "$expect" ] && { [ -z "$expect_status" ] || grep -q "^$expect_status " <<<"$out"; }; then
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
  # Ruling position 1: a digest pins the image (rule 2) but cannot say whether its cycle is
  # supported (rule 1), so a digest on a tag that names no cycle stays UNKNOWN, exit 1.
  run_case digest-no-cycle 1 UNKNOWN <<'EOF'
FROM alpine@sha256:0000000000000000000000000000000000000000000000000000000000000000
EOF
  run_case eol-soon-warns-only 0 SOON <<'EOF'
FROM alpine:3.22
EOF
  run_case codename-pinned 0 OK <<'EOF'
FROM debian:trixie-slim
EOF
  # No EOL date published (go, nginx): the oldest supported cycle warns once its
  # estimated retirement (newest release + the cadence between the oldest supported
  # cycle and its predecessor) is inside the window — nginx 1.30 here lands
  # ~2026-09-29, 18 days out; go 1.26 lands ~2027-02-17, so it stays OK.
  run_case no-date-oldest-in-window-warns 0 SOON <<'EOF'
FROM nginx:1.30-alpine
EOF
  run_case no-date-oldest-far-ok 0 OK <<'EOF'
FROM golang:1.26-bookworm
EOF
  run_case no-date-newest-ok 0 OK <<'EOF'
FROM nginx:1.31-alpine
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
  BASE_IMAGE_POLICY_DIR="$t/nowhere" GITHUB_ACTIONS= GITHUB_STEP_SUMMARY= "$0" "$t/clean.Dockerfile" >/dev/null 2>&1; rc=$?
  set -e
  if [ "$rc" = 2 ]; then printf '  ok    %-28s exit 2\n' "policy-unavailable"; else printf '  FAIL  policy-unavailable expected exit 2, got %s\n' "$rc"; fails=$((fails + 1)); fi

  self_test_json "$t" || fails=$((fails + 1))

  rm -rf "$t"
  if [ "$fails" -gt 0 ]; then err "self-test: $fails case(s) failed"; exit 1; fi
  echo "self-test: passed"
}

# ── document ─────────────────────────────────────────────────────────────────────────

# Assemble the schema-1 document from the published rows, once, at the end. summary and
# exit are computed here from those rows and nowhere else, so they describe exactly what
# is published: a private repo's finding moves neither. Any failure here is exit 2, never
# 1, so a broken assembly cannot read as "findings".
write_document() {
  local scope=unfiltered withheld=null visunread=null policy_src doc="$WORK/document.json"
  if [ "$PUBLIC_ONLY" = 1 ]; then scope=public-only; withheld="$WITHHELD"; visunread="$VISUNREAD"; fi
  if [ "$POLICY_FROM_API" = 1 ]; then policy_src="$API"; else policy_src="$POLICY_DIR"; fi
  jq -n \
    --arg generatedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg today "$TODAY" --arg source "$policy_src" --arg mode "$MODE" --arg scope "$scope" \
    --argjson warnDays "$WARN_DAYS" --argjson withheld "$withheld" --argjson visunread "$visunread" \
    --rawfile rows "$ROWS_FILE" --rawfile repos "$REPOS_FILE" '
    def nn: if . == "" then null else . end;
    def finding: IN("EOL", "FLOATING", "UNMAPPED", "UNKNOWN", "UNRESOLVED");
    def table($s): $s | split("\n") | map(select(length > 0) | split("\u001f"));
    (table($rows) | map({
        repo: (.[0] | nn), path: .[1], line: (.[2] | tonumber), ref: .[3], image: (.[4] | nn),
        tag: (.[5] | nn), digest: (.[6] | nn), product: (.[7] | nn), cycle: (.[8] | nn),
        eolDate: (.[9] | nn), eolDateEstimated: (.[10] == "true"), newestSupported: (.[11] | nn),
        status: .[12], detail: .[13] })) as $images
    | (table($repos) | map({
        repo: .[0], state: .[1],
        unreadablePaths: (.[2] | if . == "" then null else split("\u001e") end) })) as $repolist
    | ($repolist | map(select(.state == "unreadable" or .state == "partial")) | length) as $unreadable
    | (($images | map(select(.status | finding)) | length) + $unreadable) as $findings
    | { schema: 1, scope: $scope, generatedAt: $generatedAt, today: $today,
        policy: { source: $source, warnDays: $warnDays }, mode: $mode,
        exit: (if $findings > 0 or ($visunread // 0) > 0 then 1 else 0 end),
        summary: { findings: $findings,
                   warnings: ($images | map(select(.status == "SOON")) | length),
                   ok: ($images | map(select(.status == "OK")) | length),
                   unreadableRepos: $unreadable, withheldRepos: $withheld,
                   visibilityUnreadable: $visunread },
        repos: (if $mode == "estate" then $repolist else null end),
        images: $images }' >"$doc" || die "could not assemble the JSON document"
  if [ -n "$JSON_OUT" ]; then
    cp -- "$doc" "$JSON_OUT.tmp.$$" && mv -- "$JSON_OUT.tmp.$$" "$JSON_OUT" \
      || { rm -f -- "$JSON_OUT.tmp.$$" "$JSON_OUT"; die "could not write $JSON_OUT"; }
  fi
  if [ "$JSON" = 1 ]; then cat -- "$doc" >&3; fi
}

# ── main ─────────────────────────────────────────────────────────────────────────────

JSON=0; JSON_OUT=""; PUBLIC_ONLY=0; MODE=files
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON=1;;
    --json-out)
      [ $# -ge 2 ] && [ -n "$2" ] || die "--json-out needs a file"
      JSON_OUT="$2"; shift;;
    --public-only) PUBLIC_ONLY=1;;
    *) ARGS+=("$1");;
  esac
  shift
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

# Under --json stdout carries the document and nothing else, so the human table, the
# footer and anything a child prints move to stderr; the document goes to fd 3.
if [ "$JSON" = 1 ]; then exec 3>&1 1>&2; fi
# A stale document must never survive a run that does not produce one.
if [ -n "$JSON_OUT" ]; then
  rm -f -- "$JSON_OUT"
  [ -d "$(dirname -- "$JSON_OUT")" ] || die "no such directory for --json-out: $(dirname -- "$JSON_OUT")"
fi
if [ "$PUBLIC_ONLY" = 1 ]; then
  [ "${1:-}" = "--estate" ] || die "--public-only applies to --estate only"
  [ -n "${PRIVACY_GH_TOKEN:-}" ] || die "--public-only needs PRIVACY_GH_TOKEN (a token that cannot read private repos); there is no fallback to GH_TOKEN"
fi

case "${1:-}" in
  --self-test) self_test; exit 0;;
  --estate)    MODE=estate; shift; check_estate "${1:-}";;
  --dir)       MODE=dir; shift; [ -n "${1:-}" ] || die "--dir needs a path"; check_dir "$1";;
  -h|--help|"") awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; exit 2;;
  *)           check_files "$@";;
esac

if [ -n "$JSON_OUT" ] || [ "$JSON" = 1 ]; then write_document; fi

echo
if [ "$POLICY_FROM_API" = 1 ]; then policy_src="$API"; else policy_src="$POLICY_DIR"; fi
echo "base images: $ERRORS finding(s), $WARNINGS warning(s), $OKS ok (policy: $policy_src, today: $TODAY)"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "## Base images"
    echo
    if [ "$PUBLIC_ONLY" = 1 ]; then
      echo "Withheld from the published file: $WITHHELD repo(s) not public, $VISUNREAD repo(s) with unreadable visibility."
      echo
    fi
    echo "| status | where | image | detail |"
    echo "|---|---|---|---|"
    for r in "${ROWS[@]}"; do
      IFS=$'\t' read -r s w i d <<<"$r"
      printf '| %s | `%s` | `%s` | %s |\n' "$s" "$w" "$i" "$d"
    done
  } >>"$GITHUB_STEP_SUMMARY"
fi

[ "$ERRORS" -eq 0 ]
