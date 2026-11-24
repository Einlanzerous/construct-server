#!/usr/bin/env bash
# publish-base-images.sh — publish the public-only base-images document to the
# `estate-results` branch (SERV-294).
#
#   publish-base-images.sh <base-images.json>
#
# The branch is a world-readable data branch holding exactly one file, base-images.json, in
# exactly one orphan commit that is force-pushed on every publish: it is the current reading,
# not a history. Satlink reads it through the contents API (docs/base-images.md).
#
# It REFUSES (exit 2, nothing pushed) a document that does not parse, whose schema is not 1,
# whose scope is not "public-only", or that has no parseable generatedAt. The scope check is
# the second lock on the privacy filter in check-base-images.sh: an unfiltered document can
# never reach the branch by a workflow mistake.
#
# It publishes nothing, and exits 0 with a notice, when the branch already holds a document
# with a NEWER generatedAt: queued runs can finish out of order, and the older sweep must not
# overwrite the newer one. (Equal is republished.)
#
# First publish: `ls-remote --exit-code` exits 2 for an absent branch, and the push carries
# --force-with-lease=refs/heads/estate-results: (expect absence), so a racing first publisher
# makes this one lose cleanly (exit 1) instead of overwriting it. Otherwise the lease expects
# the sha that was fetched. Any other ls-remote failure is exit 2 and is not read as absent.
#
# The push credential is only ever in the ENVIRONMENT of the git commands that talk to the
# remote (an http extraheader), never an argv element and never a URL. No `set -x`.
#
# ENV
#   PUBLISH_GH_TOKEN   required; the token git authenticates with (the workflow's GITHUB_TOKEN)
#   RUNNER_TEMP        required; the clone lives under it
#   PUBLISH_REMOTE     default https://github.com/Einlanzerous/construct-server.git
#                      (the test points it at a local bare repo)
#
# EXIT  0 published, or skipped as stale   1 the push failed or lost a race
#       2 refused: bad input, missing token, or the remote could not be listed
set -euo pipefail

BRANCH=estate-results
REF="refs/heads/$BRANCH"
die() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }

[ $# -eq 1 ] || die "usage: publish-base-images.sh <base-images.json>"
doc="$1"
[ -n "${PUBLISH_GH_TOKEN:-}" ] || die "PUBLISH_GH_TOKEN is not set"
[ -n "${RUNNER_TEMP:-}" ] || die "RUNNER_TEMP is not set"
REMOTE="${PUBLISH_REMOTE:-https://github.com/Einlanzerous/construct-server.git}"
command -v jq >/dev/null 2>&1 || die "required dependency 'jq' not found in PATH"
command -v git >/dev/null 2>&1 || die "required dependency 'git' not found in PATH"

[ -f "$doc" ] || die "no such file: $doc"
jq -e . "$doc" >/dev/null 2>&1 || die "$doc is not parseable JSON"
[ "$(jq -r '.schema' "$doc")" = 1 ] || die "$doc has schema $(jq -c '.schema' "$doc"), not 1: refusing"
[ "$(jq -r '.scope' "$doc")" = public-only ] || die "$doc has scope $(jq -c '.scope' "$doc"), not \"public-only\": refusing to publish an unfiltered document"
generated="$(jq -r '.generatedAt // empty' "$doc")"
jq -en --arg g "$generated" '$g | fromdateiso8601 | . > 0' >/dev/null 2>&1 || die "$doc has no parseable generatedAt"

work="$(mktemp -d "$RUNNER_TEMP/publish-base-images.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# git's header value is base64 of "x-access-token:<token>"; printf is a builtin and base64
# reads stdin, so the token is in no argv. GitHub masks the raw secret but not its base64.
b64="$(printf 'x-access-token:%s' "$PUBLISH_GH_TOKEN" | base64 -w0)"
[ "${GITHUB_ACTIONS:-}" != true ] || echo "::add-mask::$b64"
gitauth() {
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="http.https://github.com/.extraheader" \
    GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $b64" git "$@"
}
# An explicit identity: the runner has none, and a stray global one must not leak in.
gitc() { git -c user.name=base-images -c user.email=base-images@users.noreply.github.com "$@"; }

repo="$work/repo"
git init -q "$repo"
git -C "$repo" remote add origin "$REMOTE"

rc=0
gitauth -C "$repo" ls-remote --exit-code origin "$REF" >/dev/null 2>&1 || rc=$?
case "$rc" in
  0) present=1;;
  2) present=0;;
  *) die "could not list $REF on the remote (git exit $rc): not treating that as absent";;
esac

if [ "$present" = 1 ]; then
  gitauth -C "$repo" fetch -q --depth=1 origin "$REF" || die "could not fetch $REF"
  prev_sha="$(git -C "$repo" rev-parse FETCH_HEAD)"
  prev_gen="$(git -C "$repo" show FETCH_HEAD:base-images.json 2>/dev/null | jq -r '.generatedAt // empty' 2>/dev/null || true)"
  if [ -n "$prev_gen" ] && jq -en --arg new "$generated" --arg old "$prev_gen" '($old | fromdateiso8601) > ($new | fromdateiso8601)' >/dev/null 2>&1; then
    echo "stale, not published: the branch holds generatedAt $prev_gen, newer than this document's $generated"
    exit 0
  fi
  lease="--force-with-lease=$REF:$prev_sha"
else
  lease="--force-with-lease=$REF:"
fi

# One orphan commit holding only the document (ruling position 7).
git -C "$repo" checkout -q --orphan publish
cp -- "$doc" "$repo/base-images.json"
git -C "$repo" add base-images.json
gitc -C "$repo" commit -q -m "base-images: $generated"

push_rc=0
gitauth -C "$repo" push -q "$lease" origin "HEAD:$REF" || push_rc=$?
if [ "$push_rc" -ne 0 ]; then
  printf 'ERROR: push to %s failed (git exit %s); another publisher may have won, re-run to retry\n' "$BRANCH" "$push_rc" >&2
  exit 1
fi
echo "published $generated to $BRANCH"
