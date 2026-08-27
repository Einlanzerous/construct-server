#!/usr/bin/env bash
# deploy-scope.sh — Decide which services a deploy actually needs to touch (SERV-109).
#
# THE PROBLEM. `deploy.yml` runs a whole-stack `docker compose pull && up -d`, and every
# pin in versions.env is a major.minor tag that MOVES on a patch release. That
# float is deliberate — it is how a security fix lands without an edit — but it means a
# pull moves every service that published since the last deploy, not just the one being
# repointed. Roll purser back 0.14 -> 0.13 while lyceum has cut 1.10.4 and you recreate
# lyceum too. Only purser was named.
#
# SERV-105 removed the third-party half of this by pinning those images to a digest. This
# is the first-party half, and it lands harder: these services have dependents, and per
# SERV-102 the Node ones do not recover on their own from a peer recreate that moves an
# address. A rollback runs when prod is already broken, and its whole value is being
# predictable.
#
# WHAT THIS DOES. Given the commit range a deploy is for, it answers one question: is this
# a pure pin change, and if so which compose services does it cover? A promote or rollback
# commit touches versions.env and nothing else (see promote.yml), so that is the shape it
# recognises. Everything else keeps pulling the whole stack, because everything else can
# legitimately change anything — a compose edit, a config change, a manual dispatch.
#
# THE FAILURE DIRECTION IS THE POINT. Every way this script can fail — a bad ref, a diff
# it cannot read, a pin it cannot map, a missing dependency — exits non-zero, and the
# caller's contract is that non-zero means PULL EVERYTHING. It can only ever narrow a
# deploy; if it cannot answer, the deploy is byte-for-byte what it was before SERV-109.
# The opposite bias would be catastrophic in a way that is hard to see: "scoped to
# nothing" is a deploy that reports success and ships no change at all, which is the same
# silent-no-op class as the stale-image incident recorded in deploy.yml's rsync step.
#
# WHAT IT DELIBERATELY DOES NOT BOUND. Scoping the pull bounds what MOVES. It does not
# make the deploy touch exactly one container in every sense:
#
#   * One pin can cover several services, and four of the twelve do: APERTURE_TAG,
#     CENTRIFUGE_TAG and SWITCHYARD_TAG (backend + frontend) and INTERLOCK_TAG (web +
#     worker). A repo's images ship from one release (versions.env), so those recreate
#     together, which is correct — they are one version — but only six pins name exactly
#     one container.
#   * The pinned tag is still major.minor, so pulling purser at 0.13 gets the newest 0.13
#     patch, not the exact image that was running at 0.13 before. That float is the
#     deliberate one; removing it is option 2 of SERV-109 and was not taken.
#   * A caller that then runs an UNSCOPED `up -d` re-converges the whole stack anyway.
#     Scoping the pull is necessary for a bounded blast radius, not sufficient — see how
#     deploy.yml uses this.
#
# AND ONE THING IT GIVES UP, which is the honest cost of the trade. A scoped deploy does
# not converge anything it did not name, so if an EARLIER deploy left a compose change
# unapplied — it failed before `up -d`, or it was CANCELLED while still queued, since
# `concurrency` supersedes a pending run and `cancel-in-progress: false` only protects the
# running one — a promote landing afterwards rsyncs that compose file to the deploy root
# and does not apply it. The cancelled case leaves nothing red in the Actions tab to
# prompt a re-run, which is what makes it the easy one to miss. Before this, the promote's
# whole-stack `up -d` would have. So a green promote no longer implies the running stack
# matches main. That is the right trade for a rollback — it runs when prod is broken, and
# "also apply whatever the last failed deploy was attempting" is not what you want from it
# — but it is a trade, and the way to settle it is to re-run deploy.yml from the Actions
# tab: a workflow_dispatch carries no push range, so it always takes the FULL path.
#
# Do NOT reach for check-compose-drift.sh to answer this. It compares declared vs live
# MOUNTS and the compose project root, and nothing else — not the image, env, ports,
# networks or command — so an unapplied env or digest change is invisible to it and it
# will print "No drift" on exactly the question being asked.
#
# Usage:
#   deploy-scope.sh <BASE> <HEAD> [docker-compose.yml]
#     BASE   the commit the deploy is moving FROM (github.event.before on a push)
#     HEAD   the commit being deployed
#
# Output:
#   stdout  the compose services to pull and recreate, one per line. MAY BE EMPTY, which
#           means "versions.env changed but no pin did" — a comment-only edit — and is a
#           real answer: nothing needs pulling.
#   stderr  why, in prose. Always written, so a deploy log explains its own scope.
#
# Exit codes:
#   0  scope determined; stdout is authoritative (and may legitimately be empty)
#   2  usage error or missing dependency
#   3  cannot scope this deploy
#
#   ANY non-zero exit means "pull the whole stack". Do not read a non-zero exit, or an
#   empty stdout on a non-zero exit, as "pull nothing".

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd)"

# The pins file, as a path INSIDE the tree — it is read with `git show <rev>:<path>` at two
# different commits, not from the working directory, so this is a repo-relative path and
# not a filesystem one.
PINS="versions.env"

err() { printf '%s\n' "$*" >&2; }

refuse() {
  err "Cannot scope this deploy: $*"
  err "Falling back to a whole-stack pull — which is exactly what every deploy did"
  err "before SERV-109, so this is a lost optimisation and not a broken deploy."
  exit 3
}

if [ $# -lt 2 ] || [ $# -gt 3 ]; then
  err "usage: deploy-scope.sh <BASE> <HEAD> [docker-compose.yml]"
  exit 2
fi

BASE="$1"
HEAD="$2"
COMPOSE="${3:-$REPO_ROOT/docker-compose.yml}"

for dep in git python3; do
  command -v "$dep" >/dev/null 2>&1 || { err "ERROR: required dependency '$dep' not found in PATH"; exit 2; }
done
[ -f "$COMPOSE" ] || { err "ERROR: no compose file at $COMPOSE"; exit 2; }

git rev-parse --git-dir >/dev/null 2>&1 || refuse "not inside a git repository"

# A push that creates a branch reports an all-zero `before`, and so does the very first
# push to a repo. That is an ordinary event, not a malformed one — it just carries no
# range to diff, so there is nothing to scope from.
case "$BASE" in
  "" ) refuse "no BASE commit was given" ;;
  *[!0]* ) ;;
  * ) refuse "the push reports no previous commit (all-zero SHA), so there is no range to diff" ;;
esac

for ref in "$BASE" "$HEAD"; do
  git rev-parse --verify --quiet "${ref}^{commit}" >/dev/null 2>&1 \
    || refuse "'$ref' is not a commit this checkout can resolve — a shallow clone or a force-push will do that"
done

# ── Is this a pure pin change? ───────────────────────────────────────────────────────
#
# Exact match against the whole changed-file list, not a grep for versions.env. A commit
# that repoints a pin AND edits docker-compose.yml is not a promote, and treating it as
# one would skip pulling a service whose image reference just changed for another reason.
changed="$(git diff --name-only "$BASE" "$HEAD")" \
  || refuse "git diff $BASE..$HEAD failed"

if [ -z "$changed" ]; then
  refuse "$BASE and $HEAD have identical trees, so nothing says what this deploy is for"
fi

if [ "$changed" != "$PINS" ]; then
  err "This deploy is not a pure version change. Files in $BASE..$HEAD:"
  printf '%s\n' "$changed" | sed 's/^/  - /' >&2
  refuse "a commit that touches anything besides $PINS can change any service"
fi

# ── Which pins moved? ────────────────────────────────────────────────────────────────
#
# Last occurrence of a key wins, which is what compose does with a duplicated key — a
# first-wins read here would disagree with the environment the stack is actually given.
pins_at() {
  git show "$1:$PINS" | awk '
    /^[A-Za-z_][A-Za-z0-9_]*=/ { v[substr($0, 1, index($0, "=") - 1)] = $0 }
    END { for (k in v) print v[k] }
  ' | sort
}

old_pins="$(pins_at "$BASE")" || refuse "cannot read $PINS at $BASE"
new_pins="$(pins_at "$HEAD")" || refuse "cannot read $PINS at $HEAD"

# Raw text comparison, deliberately. Compose strips surrounding quotes, so `PURSER_TAG=0.14`
# and `PURSER_TAG="0.14"` resolve identically while differing here — which puts purser in
# scope for a change that did not move it. That is the harmless direction: an extra service
# pulled costs a recreate, a missed one ships nothing.
diff_pins() {
  awk -v old="$old_pins" -v new="$new_pins" -v want="$1" '
    function key(line) { return substr(line, 1, index(line, "=") - 1) }
    BEGIN {
      n = split(old, a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") O[key(a[i])] = a[i]
      n = split(new, b, "\n"); for (i = 1; i <= n; i++) if (b[i] != "") N[key(b[i])] = b[i]
      if (want == "gone")    { for (k in O) if (!(k in N)) print k }
      if (want == "changed") { for (k in N) if (!(k in O) || O[k] != N[k]) print k }
    }
  ' | sort
}

removed="$(diff_pins gone)"
if [ -n "$removed" ]; then
  err "These pins were REMOVED from $PINS:"
  printf '%s\n' "$removed" | sed 's/^/  - /' >&2
  err "A removed pin does not fail — it silently floats that service back to :latest via"
  err "the compose fallback, which is the empty-environment-variable invariant in CLAUDE.md."
  refuse "a pin removal is not a version change and should not be scoped like one"
fi

changed_pins="$(diff_pins changed)"

if [ -z "$changed_pins" ]; then
  err "$PINS changed but no pin value did — a comment or formatting edit."
  err "Nothing to pull: no image reference in the stack is different."
  exit 0
fi

err "Pins changed in $BASE..$HEAD:"
printf '%s\n' "$changed_pins" | while IFS= read -r k; do
  was="$(printf '%s\n' "$old_pins" | grep "^${k}=" | cut -d= -f2- || true)"
  now="$(printf '%s\n' "$new_pins" | grep "^${k}=" | cut -d= -f2- || true)"
  err "  - $k: ${was:-<unset>} -> ${now:-<unset>}"
done

# ── Which services do those pins cover? ──────────────────────────────────────────────
#
# Derived from the compose file rather than a table in here, for the reason verify-tag.sh
# gives about the same mapping: a hardcoded list goes stale the day an eleventh service is
# added, and it can disagree with what the stack actually runs. The RAW file is parsed, not
# `docker compose config` — the resolved view has already interpolated the tag, so the
# variable that would identify the service is gone by then.
#
# Python's stderr is captured to a file rather than folded into stdout with 2>&1: this
# command substitution IS the service list, and a stray warning merged into it would be
# read as a service name and passed to `docker compose pull`.
map_err="$(mktemp)"
trap 'rm -f "$map_err"' EXIT

services="$(printf '%s\n' "$changed_pins" | python3 -c '
import re
import sys

try:
    import yaml
except ImportError:
    sys.exit("python3 yaml module not available")

compose_path = sys.argv[1]
keys = [line.strip() for line in sys.stdin if line.strip()]

with open(compose_path) as fh:
    doc = yaml.safe_load(fh)

by_key = {}
for name, svc in ((doc or {}).get("services") or {}).items():
    image = (svc or {}).get("image")
    if not isinstance(image, str):
        continue  # built rather than pulled, e.g. cf-access-guard
    for var in re.findall(r"\$\{([A-Za-z_][A-Za-z0-9_]*)", image):
        by_key.setdefault(var, set()).add(name)

unmapped = [k for k in keys if k not in by_key]
if unmapped:
    sys.exit("no image in %s interpolates %s" % (compose_path, ", ".join(sorted(unmapped))))

print("\n".join(sorted({n for k in keys for n in by_key[k]})))
' "$COMPOSE" 2>"$map_err")" || refuse "$(cat "$map_err")"

# A pin that maps to no service is caught above; a pin that maps to zero services after a
# successful parse cannot happen, but an empty result here would mean "deploy nothing" and
# is worth refusing rather than trusting.
[ -n "$services" ] || refuse "the changed pins map to no compose service at all"

err "Services covered:"
printf '%s\n' "$services" | sed 's/^/  - /' >&2

printf '%s\n' "$services"
