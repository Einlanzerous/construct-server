#!/usr/bin/env bash
# report-versions.sh — What is this compose project ACTUALLY running?
#
# SERV-97's acceptance criterion is that "what dev is running is answerable from the
# workflow run rather than by shelling in". Dev floats on `latest`, so the compose file
# answers nothing at all and `docker compose ps` answers with the same word every time.
# This resolves it to something that identifies code.
#
# THREE COLUMNS, AND THE THIRD IS THE ONE THAT MATTERS
#
#   ref        the image reference the container was created from. What compose asked for.
#   digest     the registry digest that reference resolved to at pull time.
#   revision   `org.opencontainers.image.revision` — the COMMIT the image was built from.
#
# The digest is not the version. SERV-88 read a digest mismatch between `sha-2156151` and
# `0.13.0` as purser running ahead of its release; it was not. The publish workflow runs
# once on the push to `main` and again on the release tag, so it builds the same source
# twice seconds apart and the two digests differ. Both images carried
# `org.opencontainers.image.revision=2156151434…` — the same commit. Comparing digests
# invents version drift that does not exist, and it does it exactly where the stakes are
# highest: the delivery ledger, and a rollback, where "is this the same code" is the whole
# question. So the revision label is printed and is what a human should read.
#
# A blank revision is not an error — third-party images mostly do not set the label, and
# for those the digest is the only identity available.
#
# Usage:
#   ./scripts/report-versions.sh [--markdown] [service ...]
#     --markdown  emit a GitHub-flavoured table, for $GITHUB_STEP_SUMMARY
#
#   DEPLOY_ROOT / COMPOSE_FILE / COMPOSE_PROJECT select the project, same as
#   assert-healthy.sh. `make versions` and `make dev-versions` set them for you.
#
# Exit codes:
#   0  reported
#   2  usage / missing dependency / no deploy root / no containers

set -euo pipefail

DEPLOY_ROOT="${DEPLOY_ROOT:-/opt/construct-server}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
COMPOSE_PROJECT="${COMPOSE_PROJECT:-}"

MARKDOWN=0
services=()

err() { printf '%s\n' "$*" >&2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --markdown) MARKDOWN=1; shift ;;
    -h|--help) sed -n '2,35p' "$0"; exit 0 ;;
    -*) err "ERROR: unknown option '$1'"; exit 2 ;;
    *) services+=("$1"); shift ;;
  esac
done

command -v docker >/dev/null 2>&1 || { err "ERROR: required dependency 'docker' not found in PATH"; exit 2; }

if [ ! -f "$DEPLOY_ROOT/$COMPOSE_FILE" ]; then
  err "ERROR: no $COMPOSE_FILE at DEPLOY_ROOT=$DEPLOY_ROOT"
  exit 2
fi

cd "$DEPLOY_ROOT"

compose() { docker compose -f "$COMPOSE_FILE" ${COMPOSE_PROJECT:+-p "$COMPOSE_PROJECT"} "$@"; }

# -a, not the default: a service that crashed on boot is the one you most want named in
# this report, and `ps -q` omits it entirely (the same trap assert-healthy.sh documents).
if [ ${#services[@]} -gt 0 ]; then
  container_ids="$(compose ps -aq "${services[@]}")"
else
  container_ids="$(compose ps -aq)"
fi

if [ -z "$container_ids" ]; then
  err "ERROR: no containers in project at $DEPLOY_ROOT/$COMPOSE_FILE"
  exit 2
fi

rows=""
for cid in $container_ids; do
  name="$(docker inspect -f '{{.Name}}' "$cid")"; name="${name#/}"
  ref="$(docker inspect -f '{{.Config.Image}}' "$cid")"
  imgid="$(docker inspect -f '{{.Image}}' "$cid")"

  # RepoDigests can hold several entries when one image id is tagged from more than one
  # repository. Take the one matching this container's repo rather than the first, or a
  # first-party service can be reported under some unrelated repo's digest.
  repo="${ref%%@*}"; repo="${repo%:*}"
  digest="$(docker image inspect "$imgid" \
    --format '{{range .RepoDigests}}{{println .}}{{end}}' 2>/dev/null \
    | awk -F@ -v r="$repo" '$1 == r { print $2; exit }')"
  # Locally built images (build:, no registry push) have no RepoDigest at all. Say so
  # rather than printing an empty cell that reads like a lookup failure. Truncated only
  # when it IS a digest — the column width is there to cut 71 hex characters down to
  # something readable, and applying it to this sentence printed `(not from a registr`.
  # Reachable on the prod project today: servo-signal and autosavant-bot both `build:`.
  if [ -n "$digest" ]; then
    digest="${digest:0:19}"
  else
    digest="(not from a registry)"
  fi

  revision="$(docker image inspect "$imgid" \
    --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' 2>/dev/null || true)"
  [ -n "$revision" ] && [ "$revision" != "<no value>" ] || revision="—"

  rows="$rows$name|$ref|$digest|${revision:0:12}"$'\n'
done

rows="$(printf '%s' "$rows" | sort)"

if [ "$MARKDOWN" -eq 1 ]; then
  printf '| Container | Image ref | Digest | Revision |\n'
  printf '|---|---|---|---|\n'
  printf '%s\n' "$rows" | while IFS='|' read -r n r d v; do
    [ -z "$n" ] && continue
    printf '| `%s` | `%s` | `%s` | `%s` |\n' "$n" "$r" "$d" "$v"
  done
else
  printf '%s\n' "$rows" | while IFS='|' read -r n r d v; do
    [ -z "$n" ] && continue
    printf '%-26s %-58s %-20s %s\n' "$n" "$r" "$d" "$v"
  done
fi
