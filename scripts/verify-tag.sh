#!/usr/bin/env bash
# verify-tag.sh — Check that every image behind a pin actually exists at a version
#
# The pre-flight for promote and rollback (SERV-78, SERV-79). Repointing a pin to a tag
# the registry does not carry is not caught by anything else: versions.env would be
# valid, `docker compose config` would be valid, deploy.yml's assertion only rejects
# `:latest` and empty — and the deploy would then fail at `docker compose pull`, after
# the commit is already on main. Rollback is the case that matters, since it runs when
# prod is already broken and a "rollback" that fails to pull leaves it broken with a bad
# pin now committed.
#
# One pin can cover several images: a repo's backend and frontend ship from one release,
# so SWITCHYARD_TAG covers two images and INTERLOCK_TAG covers two more. All of them are
# checked. A version that exists for the backend but not the frontend is precisely the
# half-deployed state worth refusing.
#
# The image list is derived from docker-compose.yml rather than hardcoded here, so
# adding an eleventh service needs no edit to this script — and so this can never
# disagree with what the stack actually runs.
#
# Usage:
#   verify-tag.sh <KEY> <VERSION> [docker-compose.yml]
#
# Requires a registry login that can read the packages (deploy.yml and promote.yml both
# `docker login ghcr.io` first).
#
# Exit codes:
#   0  every image behind KEY exists at VERSION
#   1  at least one does not
#   2  usage error, missing file, unknown key, or no images found for the key

set -euo pipefail

err() { printf '%s\n' "$*" >&2; }

if [ $# -lt 2 ] || [ $# -gt 3 ]; then
  err "usage: verify-tag.sh <KEY> <VERSION> [docker-compose.yml]"
  exit 2
fi

key="$1"
version="$2"
compose="${3:-docker-compose.yml}"

[ -f "$compose" ] || { err "ERROR: no compose file at $compose"; exit 2; }
command -v docker >/dev/null 2>&1 || { err "ERROR: required dependency 'docker' not found in PATH"; exit 2; }

# Match `image: <repo>:${KEY...}` and keep the repo. Anchoring on the variable name means
# the mapping comes from the same file the stack runs from, and a service that stops
# using this pin drops out of the check automatically.
images="$(grep -oE "image: *[^ ]+:\\\$\{${key}[:-]" "$compose" \
  | sed -E "s/^image: *//; s/:\\\$\{${key}[:-]$//" \
  | sort -u || true)"

if [ -z "$images" ]; then
  err "ERROR: no image in $compose uses \${$key}"
  err
  err "Pins in use:"
  grep -oE 'image: *[^ ]+:\$\{[A-Za-z_][A-Za-z0-9_]*' "$compose" \
    | sed -E 's/.*\$\{//' | sort -u | sed 's/^/  - /' >&2
  exit 2
fi

printf 'Checking %s images behind %s at "%s":\n' "$(printf '%s\n' "$images" | wc -l | tr -d ' ')" "$key" "$version"

missing=""
for img in $images; do
  if docker manifest inspect "$img:$version" >/dev/null 2>&1; then
    printf '  OK      %s:%s\n' "$img" "$version"
  else
    printf '  MISSING %s:%s\n' "$img" "$version"
    missing="$missing $img"
  fi
done

if [ -n "$missing" ]; then
  printf '\nERROR: %s does not exist in the registry for every image behind %s.\n' "$version" "$key" >&2
  err "Refusing to pin to it — the deploy would fail at 'docker compose pull', after the"
  err "commit had already landed on main."
  err
  err "Check the tag really published, and remember the two sha forms differ: argosy"
  err "publishes 'sha-<short>', drydock the full 40-char commit sha (see versions.env)."
  exit 1
fi

printf '\nAll images exist at %s.\n' "$version"
