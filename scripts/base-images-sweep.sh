#!/usr/bin/env bash
# base-images-sweep.sh — run the estate sweep for base-images.yml and say whether a document
# exists to publish (SERV-294).
#
# A workflow step cannot tell exit 1 from exit 2 (`steps.<id>.outcome` is just "failure"), and
# the two mean opposite things here: exit 1 is "the sweep found something", and the week with
# findings is exactly the week the published file must still move; exit 2 is "the sweep could
# not run" and leaves no document. So the exit code is captured and re-raised, and
# `published=true` is written to $GITHUB_OUTPUT only when a document was produced (exit 0 or
# 1 with the file present). The job still fails on findings, so the Monday email still comes.
#
# The sweep is --public-only: the file this writes is already filtered, so the artifact and
# the branch downstream never hold private data. It is also --redact (SERV-350), passed
# explicitly even though GITHUB_ACTIONS implies it: the run log and step summary of a public
# repo's workflow are world-readable, so a private repo is reported as counts only there. The
# flag is the contract; the environment detection is the backstop. See docs/base-images.md.
#
# ENV
#   RUNNER_TEMP        where the document is written ($RUNNER_TEMP/out/base-images.json)
#   GITHUB_OUTPUT      where `published=true` goes
#   GH_TOKEN           the sweep token (reads private repos so they are still swept)
#   PRIVACY_GH_TOKEN   the low-privilege token that decides which repos are public
#   BASE_IMAGES_CHECK  the check script to run (default: check-base-images.sh beside this
#                      file); the test points it at a fake
#
# EXIT: the check's own exit code (0, 1 or 2); 2 also for this wrapper's own setup errors.
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd)"
die() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }

[ -n "${RUNNER_TEMP:-}" ] || die "RUNNER_TEMP is not set (nothing is written to a fixed path)"
[ -n "${GITHUB_OUTPUT:-}" ] || die "GITHUB_OUTPUT is not set"
check="${BASE_IMAGES_CHECK:-$SCRIPT_DIR/check-base-images.sh}"
out_dir="$RUNNER_TEMP/out"
out="$out_dir/base-images.json"
mkdir -p "$out_dir" || die "cannot create $out_dir"
# A leftover from an earlier step must never read as this run's document.
rm -f -- "$out"

rc=0
"$check" --estate "$REPO_ROOT/docker-compose.yml" --json-out "$out" --public-only --redact || rc=$?

if [ "$rc" -le 1 ] && [ -s "$out" ]; then
  echo "published=true" >>"$GITHUB_OUTPUT"
else
  # Exit 2, or a document nobody should trust: nothing to publish.
  rm -f -- "$out"
fi
exit "$rc"
