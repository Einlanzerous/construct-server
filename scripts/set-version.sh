#!/usr/bin/env bash
# set-version.sh — Repoint one first-party version pin
#
# Two files use it, and it does not need to know which: versions.env for the container
# images, and versions-host.env for signet, the one first-party service that is a host
# binary rather than a container (SERV-130). Both are KEY=VALUE and both are tracked, so
# the write is the same; what differs is which workflow fires on the resulting commit.
# Pass the file as $3.
#
# The single write behind promote and rollback (SERV-78, SERV-79). Both are the same
# operation — "make prod run this exact version" — so both come through here; the only
# difference between them is which version you name and what you say about it.
#
# It edits the tracked file and nothing else. It does not commit, push, pull an image or
# touch a container: the deploy is what happens *after* the commit lands, because
# deploy.yml already fires on a push that changes versions.env (SERV-96). Keeping this a
# pure file edit is what makes it testable and what keeps the deploy path single —
# a promote that recreated containers itself would be a second way for prod to change,
# which is the thing SERV-76 spent a whole ticket removing.
#
# Refuses to create a key that is not already in the file. A promote naming a service
# that does not exist is a typo, and silently appending `LYCEM_TAG=1.11` would leave the
# real pin untouched, report success, and change nothing — the failure would surface
# later as "the version did not take" with no obvious cause.
#
# Usage:
#   set-version.sh <KEY> <VERSION> [FILE]
#     KEY      the pin to change, e.g. LYCEUM_TAG or SIGNET_VERSION
#     VERSION  the value to pin to, e.g. 1.11 (an image tag) or v1.9.1 (a release tag)
#     FILE     defaults to versions.env; versions-host.env for signet
#
# The alphabet check below is common to both, but the SHAPE each file wants is enforced
# by its consumer, not here: promote.yml and deploy-signet.yml both require
# `^v[0-9]+\.[0-9]+\.[0-9]+$` for signet, because a host pin has no registry to resolve
# a major.minor against.
#
# Prints `<KEY>: <old> -> <new>`, or `<KEY>: already <value>` when it is a no-op.
#
# Exit codes:
#   0  the file now pins KEY to VERSION (stdout says whether it changed)
#   2  usage error, missing file, unknown key, or a malformed version

set -euo pipefail

err() { printf '%s\n' "$*" >&2; }

if [ $# -lt 2 ] || [ $# -gt 3 ]; then
  err "usage: set-version.sh <KEY> <VERSION> [versions.env]"
  exit 2
fi

key="$1"
version="$2"
file="${3:-versions.env}"

[ -f "$file" ] || { err "ERROR: no versions file at $file"; exit 2; }

case "$key" in
  [A-Za-z_]*) ;;
  *) err "ERROR: '$key' is not a valid variable name"; exit 2 ;;
esac
case "$key" in
  *[!A-Za-z0-9_]*) err "ERROR: '$key' is not a valid variable name"; exit 2 ;;
esac

# An empty or whitespace-only version is the empty-environment-variable invariant
# (CLAUDE.md). Both files suffer it, differently: `LYCEUM_TAG=` interpolates to
# `image: …/lyceum:`, which is neither an error nor `latest`, so it sails past a naive
# check and floats the service; `SIGNET_VERSION=` reaches deploy-signet.yml, which
# refuses it rather than resolving it to anything. Neither is a state worth writing.
if [ -z "${version//[[:space:]]/}" ]; then
  err "ERROR: refusing to set $key to an empty value"
  err "An empty image pin interpolates to a bare 'image: …/service:', which is not an"
  err "error and not 'latest' — it silently deploys something nobody chose. An empty"
  err "host pin has no release to download and stops the deploy instead."
  exit 2
fi

# A restricted alphabet, and this value is about to be written into a file that a shell
# reads — and, for the image pins, docker too. Anything outside it is a typo or an
# injection. The set is docker's, which is the stricter of the two and a superset of
# what a git release tag needs, so one check covers both files.
case "$version" in
  *[!A-Za-z0-9._-]*)
    err "ERROR: '$version' is not a valid pin"
    err "Letters, digits, and . _ - only (docker's tag alphabet, which also covers a"
    err "release tag like v1.9.1)."
    exit 2
    ;;
esac
case "$version" in
  [.-]*) err "ERROR: a pin may not start with '.' or '-' (got '$version')"; exit 2 ;;
esac

current="$(grep -E "^${key}=" "$file" | tail -1 | cut -d= -f2- || true)"
if [ -z "$current" ]; then
  err "ERROR: $file has no pin named '$key'"
  err
  err "Known pins:"
  grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' "$file" | tr -d '=' | sed 's/^/  - /' >&2
  err
  err "This script will not add a new key: a promote naming a service that does not"
  err "exist is a typo, and appending it would report success while changing nothing."
  exit 2
fi

if [ "$current" = "$version" ]; then
  printf '%s: already %s\n' "$key" "$version"
  exit 0
fi

# Exact-key rewrite via awk rather than sed, so neither the key nor the version is ever
# interpreted as a regex or as part of a replacement expression — a tag containing `.`
# or `&` would otherwise mean something to sed that it does not mean here.
tmp="$(mktemp "${file}.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
awk -v k="$key" -v v="$version" '
  {
    eq = index($0, "=")
    if (eq > 1 && substr($0, 1, eq - 1) == k) print k "=" v
    else print
  }
' "$file" > "$tmp"

# Preserve the original mode: versions.env is tracked and world-readable by design
# (it holds no secret), and mktemp creates 0600.
chmod --reference="$file" "$tmp" 2>/dev/null || chmod 644 "$tmp"
mv "$tmp" "$file"
trap - EXIT

printf '%s: %s -> %s\n' "$key" "$current" "$version"
