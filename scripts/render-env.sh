#!/usr/bin/env bash
# render-env.sh — Compose the deployed .env from the secret and the tracked pins
#
# The stack's environment has two sources with different homes (SERV-96):
#
#   PROD_ENV_FILE   the `home-server` GitHub Environment secret — real credentials
#   versions.env    tracked in git — the first-party image pins, which are not secrets
#
# This merges them into ONE file, because the deployed .env has to stay the complete
# environment compose reads. The alternative — passing
# `--env-file .env --env-file versions.env` at every call site — would mean a bare
# `docker compose up -d` in the deploy root silently resolves every first-party image
# to `:latest`, and that invocation runs no guard. Keeping .env sufficient means the
# Makefile targets, check-compose-drift.sh, ansible, and a human debugging on the box
# all see the same environment without having to know this file exists.
#
# Keys defined in versions.env are STRIPPED from the base before the pins are appended,
# rather than relying on compose taking the last of two duplicate keys. Two
# `LYCEUM_TAG=` lines in a rendered .env would make the deployed value a question of
# precedence, and a grep-vs-compose disagreement of exactly that kind already shipped a
# bug once (see the tag-assertion step in deploy.yml, SERV-88). One definition, no rule
# to remember.
#
# The strip list is read from versions.env itself, so adding an eleventh service needs
# no edit here, and only the keys that file actually defines are touched. A blanket regex
# over `_TAG` would have been simpler and wrong: it would eat any third-party pin the
# secret happened to carry. There are none left as of SERV-105 — the third-party images
# are pinned by digest in docker-compose.yml — but the strip list stays derived rather
# than pattern-matched, because that property should not depend on the current contents
# of a file this script does not own.
#
# Usage:
#   render-env.sh <base> <versions.env> <output>
#     base   file holding the base environment, or `-` to read it from stdin.
#            May be the SAME path as <output>: it is read in full before any write,
#            which is what lets ansible reconcile the pins in a deployed .env in place
#            without touching the credentials already in it.
#     output written 0600 via a temp file and an atomic rename; a failure part-way
#            leaves the previous .env intact rather than a half-written one.
#
# Prints `updated` or `unchanged` on stdout, so a caller can report honestly whether it
# changed the deployed environment.
#
# Exit codes:
#   0  rendered (stdout says whether anything changed)
#   2  usage error, missing input, or a malformed versions file

set -euo pipefail

err() { printf '%s\n' "$*" >&2; }

if [ $# -ne 3 ]; then
  err "usage: render-env.sh <base|-> <versions.env> <output>"
  exit 2
fi

base="$1"
versions="$2"
out="$3"

[ -f "$versions" ] || { err "ERROR: no versions file at $versions"; exit 2; }

if [ "$base" = "-" ]; then
  base_content="$(cat)"
else
  [ -f "$base" ] || { err "ERROR: no base env file at $base"; exit 2; }
  base_content="$(cat "$base")"
fi

# The sentinel that opens the rendered block. Cutting from it to EOF before rendering
# again is what makes this idempotent when <base> is a file this script already wrote —
# ansible reconciles the deployed .env in place, so that is the normal case and not an
# edge one. Without the cut, each run would leave another header and pin block behind.
MARKER='# --- first-party image pins, rendered from versions.env (SERV-96) ---'
base_content="$(printf '%s\n' "$base_content" | awk -v m="$MARKER" '$0 == m { exit } { print }')"

# An empty base is never a value (the CLAUDE.md invariant). Rendering one would produce
# an .env holding nothing but tags, and compose would then interpolate every credential
# to empty — the silent half-configured deploy that SERV-33/40 and #74 both were.
if [ -z "${base_content//[[:space:]]/}" ]; then
  err "ERROR: the base environment is empty — refusing to render an .env with no credentials"
  exit 2
fi

# Anything that is neither a comment nor KEY=VALUE is a typo, not a pin. Fail here
# rather than let it through to be silently ignored: a pin that does not parse is a
# service that floats.
malformed="$(grep -vE '^[[:space:]]*(#|$)' "$versions" | grep -vE '^[A-Za-z_][A-Za-z0-9_]*=' || true)"
if [ -n "$malformed" ]; then
  err "ERROR: $versions has lines that are neither a comment nor KEY=VALUE:"
  printf '%s\n' "$malformed" | sed 's/^/  /' >&2
  exit 2
fi

# Same invariant, at the earliest point it can be caught. `LYCEUM_TAG=` interpolates to
# `image: …/lyceum:`, which is neither an error nor `latest`. deploy.yml's assertion
# would catch it, but failing before anything is written is cheaper and names the line.
blank="$(grep -E '^[A-Za-z_][A-Za-z0-9_]*=[[:space:]]*$' "$versions" || true)"
if [ -n "$blank" ]; then
  err "ERROR: $versions has pins with no value:"
  printf '%s\n' "$blank" | sed 's/^/  /' >&2
  exit 2
fi

pins="$(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$versions")"
pinned_keys="$(printf '%s\n' "$pins" | cut -d= -f1)"

# Exact key matches only — no regex built from the key names, so a key can never be
# read as a pattern.
stripped="$(printf '%s\n' "$base_content" | awk -v keys="$pinned_keys" '
  BEGIN {
    n = split(keys, k, "\n")
    for (i = 1; i <= n; i++) if (k[i] != "") drop[k[i]] = 1
  }
  {
    eq = index($0, "=")
    if (eq > 1 && (substr($0, 1, eq - 1) in drop)) next
    print
  }
')"

# The MARKER itself is a fixed sentinel — it is what the cut above searches for, so it
# must read identically no matter which pin file produced the block. The line under it
# names the actual source instead, because dev renders from dev-versions.env (SERV-97) and
# a deployed dev .env telling you to go edit versions.env sends you to the wrong file.
rendered="$(printf '%s\n\n%s\n%s\n%s\n%s\n' \
  "$stripped" \
  "$MARKER" \
  "# Do not edit below here: this block is regenerated on every deploy and an edit made" \
  "# on the host is lost without warning. Change $(basename "$versions") and merge it." \
  "$pins")"

if [ -f "$out" ] && [ "$(cat "$out")" = "$rendered" ]; then
  printf 'unchanged\n'
  exit 0
fi

tmp="$(mktemp "${out}.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
chmod 600 "$tmp"
printf '%s\n' "$rendered" > "$tmp"
mv "$tmp" "$out"
trap - EXIT

printf 'updated\n'
