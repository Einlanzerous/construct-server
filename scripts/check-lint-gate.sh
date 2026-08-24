#!/usr/bin/env bash
# check-lint-gate.sh — Prove the SERV-58 push gate actually blocks, and actually exempts.
#
# WHY THIS EXISTS. lint-gate.sh fails open by design: anything it cannot run is allowed
# through. That is the right bias for a gate in front of every push, but it has an
# unpleasant consequence — a gate that has silently stopped working looks exactly like a
# gate that has nothing to complain about. Both are green. This script is the difference:
# it builds a repository that is *known* to be misformatted and asserts the gate says no.
#
# It runs against fixtures in a temp directory, never against the estate's repos, so it is
# safe to run at any time and cannot leave a working tree dirty.
#
# Usage: ./scripts/check-lint-gate.sh   (or: make lint-gate-test)

set -uo pipefail

GATE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lint-gate.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
SKIP=0

ok()   { printf '  \033[32mok\033[0m   %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; printf '       %s\n' "$2"; FAIL=$((FAIL + 1)); }
skip() { printf '  \033[33m--\033[0m   skipped: %s (%s)\n' "$1" "$2"; SKIP=$((SKIP + 1)); }

# Every fixture here is a Go repo, so a *finding* can only be produced when gofmt exists.
# Without it the gate correctly allows everything, and asserting "deny" would report the
# fail-open behaviour as a failure. Degrade to skips instead, so this suite stays
# meaningful in exactly the environment the gofmt bug was found in — see the note in
# docs/lint-gate.md about running it with PATH stripped.
HAVE_GOFMT=1; command -v gofmt >/dev/null 2>&1 || HAVE_GOFMT=0

# decision <repo> <command> -> prints "deny" or "allow"
decision() {
  local repo="$1" cmd="$2" out
  out="$(printf '{"tool_name":"Bash","cwd":%s,"tool_input":{"command":%s}}' \
          "$(jq -Rn --arg v "$repo" '$v')" "$(jq -Rn --arg v "$cmd" '$v')" \
        | timeout 30 "$GATE" 2>/dev/null)"
  [ -z "$out" ] && { echo allow; return; }
  printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null || echo allow
}

expect() {
  local want="$1" repo="$2" cmd="$3" got
  if [ "$want" = deny ] && [ "$HAVE_GOFMT" = 0 ]; then
    skip "deny <- $cmd" "no gofmt, so no finding is possible"
    return
  fi
  got="$(decision "$repo" "$cmd")"
  if [ "$got" = "$want" ]; then ok "$want  <- $cmd"
  else bad "$cmd" "expected $want, got $got"; fi
}

# --------------------------------------------------------------------------
# Fixture: a Go repo whose only file is valid Go but deliberately misformatted.
# --------------------------------------------------------------------------
mkgo() {
  local d="$1" fmt="$2"
  mkdir -p "$d" && cd "$d" || return 1
  git init -q -b main . && git config user.email t@example.com && git config user.name t
  printf 'module fixture\n\ngo 1.22\n' > go.mod
  if [ "$fmt" = bad ]; then
    printf 'package fixture\n\nfunc  Add(a int,b int) int {\n\t\t\treturn a+b\n}\n' > add.go
  else
    printf 'package fixture\n\n// Add sums two ints.\nfunc Add(a int, b int) int {\n\treturn a + b\n}\n' > add.go
  fi
  git add -A && git commit -qm fixture
  git tag v1.0.0
  git branch release-please--branches--main
  cd - >/dev/null || return 1
}

echo "lint-gate: blocking"
mkgo "$TMP/dirty" bad
expect deny  "$TMP/dirty" "git push"
expect deny  "$TMP/dirty" "git push origin main"
# The shape an agent actually uses. A prefix-matching filter would miss this one.
expect deny  "$TMP/dirty" "git add -A && git commit -m 'x' && git push"
expect deny  "$TMP/dirty" "git push -u origin HEAD"
# --follow-tags still pushes the branch, so the branch still gets checked.
expect deny  "$TMP/dirty" "git push --follow-tags"

echo "lint-gate: exemptions (SERV-58 requires these never fire)"
expect allow "$TMP/dirty" "git push --tags"
expect allow "$TMP/dirty" "git push origin v1.0.0"
expect allow "$TMP/dirty" "git push origin refs/tags/v1.0.0"
expect allow "$TMP/dirty" "git push origin release-please--branches--main"
expect allow "$TMP/dirty" "git push --no-verify"
expect allow "$TMP/dirty" "git push --dry-run"
expect allow "$TMP/dirty" "git push origin --delete stale"

echo "lint-gate: not a push, or nothing to say"
expect allow "$TMP/dirty" "ls -la"
expect allow "$TMP/dirty" "git status"
expect allow "$TMP/dirty" "git commit -m 'mentions git push in the message'"
mkgo "$TMP/clean" good
expect allow "$TMP/clean" "git push"
mkdir -p "$TMP/norepo"
expect allow "$TMP/norepo" "git push"

echo "lint-gate: escape hatch"
if [ "$(CONSTRUCT_LINT_GATE=0 decision "$TMP/dirty" "git push")" = allow ]; then
  ok "allow <- CONSTRUCT_LINT_GATE=0"
else
  bad "CONSTRUCT_LINT_GATE=0" "expected allow"
fi

echo "lint-gate: a repo with no configured checks no-ops"
mkdir -p "$TMP/plain" && ( cd "$TMP/plain" && git init -q -b main . \
  && git config user.email t@example.com && git config user.name t \
  && echo hi > README.md && git add -A && git commit -qm init )
expect allow "$TMP/plain" "git push"

# --------------------------------------------------------------------------
# Discovery: a workspace root that lints everything must suppress its members,
# and must stop suppressing them the moment it stops linting them.
#
# This has been wrong twice. First the ancestor test compared only the first path
# component, so a member at `apps/web` never matched a root recorded as `.`. Then the
# ordering was lexical, so `<repo>/apps/web/package.json` was visited BEFORE
# `<repo>/package.json` and the root had not been recorded yet when its member came up.
# Both produced doubled findings, which is the sort of thing that reads as "the linter is
# broken" rather than "the gate is broken".
# --------------------------------------------------------------------------
echo "lint-gate: workspace discovery"
WS="$TMP/ws"
mkdir -p "$WS/apps/web" "$WS/packages/db" "$WS/node_modules"
( cd "$WS" && git init -q -b main . && git config user.email t@example.com && git config user.name t )
echo '{}' > "$WS/bun.lock"
echo '{"name":"web","scripts":{"lint":"eslint ."}}' > "$WS/apps/web/package.json"
echo '{"name":"db","scripts":{"lint":"eslint ."}}'  > "$WS/packages/db/package.json"

units() { "$GATE" --explain "$WS" | grep -c '^  node' || true; }

echo '{"name":"root","workspaces":["apps/*"],"scripts":{"lint":"eslint ."}}' > "$WS/package.json"
n="$(units)"
[ "$n" = 1 ] && ok "a linting workspace root suppresses its members (1 unit)" \
             || bad "workspace root" "expected 1 node unit, got $n"

echo '{"name":"root","workspaces":["apps/*"]}' > "$WS/package.json"
n="$(units)"
[ "$n" = 2 ] && ok "a root with no lint script leaves members visible (2 units)" \
             || bad "workspace members" "expected 2 node units, got $n"

# --------------------------------------------------------------------------
# Fail-open. The gate must never block on a check it could not finish — see the
# failure-direction note in lint-gate.sh. A slow linter is a skip, not a denial.
# --------------------------------------------------------------------------
echo "lint-gate: fail-open"
# The regression from PR #158's review. gofmt was guarded nowhere while `go` was guarded
# for vet, so with gofmt off PATH xargs wrote "No such file or directory" to stderr and
# the gate reported it as a parse FAILURE — denying every push from every repo with a
# go.mod, against a correctly formatted tree. On this box `go`/`gofmt` live in ~/go/bin,
# which only ~/.zshrc adds, so any non-login shell (the self-hosted runner included)
# is in exactly that state.
#
# $TMP/dirty IS misformatted, so this asserts the harder direction: with no gofmt to
# prove it, the gate must still allow rather than invent a finding.
got="$(PATH=/usr/bin:/bin decision "$TMP/dirty" "git push")"
[ "$got" = allow ] && ok "gofmt off PATH is a skip, not a block" \
                   || bad "gofmt off PATH" "expected allow, got $got"

# A shell separator inside a quoted commit message must not put `git push` in command
# position — it would block the COMMIT, not a push.
for msg in 'wip; git push later' 'wip && git push later' 'remember to git push'; do
  got="$(decision "$TMP/dirty" "git commit -m \"$msg\"")"
  [ "$got" = allow ] && ok "allow  <- git commit -m \"$msg\"" \
                     || bad "git commit -m \"$msg\"" "expected allow, got $got"
done
# …while a real separator outside quotes still must be found.
expect deny "$TMP/dirty" "git commit -m 'wip' && git push"

SLOW="$TMP/slow"
mkdir -p "$SLOW/node_modules"
( cd "$SLOW" && git init -q -b main . && git config user.email t@example.com && git config user.name t )
echo '{}' > "$SLOW/bun.lock"
echo '{"name":"slow","scripts":{"lint":"sleep 30"}}' > "$SLOW/package.json"
got="$(CONSTRUCT_LINT_GATE_CHECK_TIMEOUT=1 CONSTRUCT_LINT_GATE_TOTAL_TIMEOUT=20 decision "$SLOW" "git push")"
[ "$got" = allow ] && ok "a check that times out is a skip, not a block" \
                   || bad "timed-out check" "expected allow, got $got"

# --------------------------------------------------------------------------
# Multi-line commands. Every case above is a single line, which is exactly why the
# heredoc bug survived the round-one command-position fix.
# --------------------------------------------------------------------------
echo "lint-gate: multi-line commands"

# A heredoc body is NOT shell-quoted, so quote tracking alone does not save this: every
# line of it looks like command position. The command being gated is a file WRITE, and
# `--no-verify` cannot be applied to a `cat`, so a false block here has no escape hatch
# short of disabling the gate outright.
expect allow "$TMP/dirty" 'cat > docs/deploy.md <<EOF
Then run:
git push origin main
EOF'
expect allow "$TMP/dirty" "cat > f <<'SH'
git push origin main
SH"
expect allow "$TMP/dirty" 'cat > f <<-EOF
	git push origin main
	EOF'
# …but newline MUST stay a separator, or a plain multi-line script silently stops being
# gated. Dropping `\n` is the cheap fix for the heredoc case and it trades a false block
# for a silent miss, which is the worse of the two by this design's own argument.
expect deny "$TMP/dirty" 'git add -A
git commit -m x
git push'
# The terminator must close the heredoc, so a real push after one is still found.
expect deny "$TMP/dirty" 'cat > f <<EOF
git push origin main
EOF
git push'

echo "lint-gate: the gate answers fast enough to leave on"
start=$(date +%s%N)
decision "$TMP/clean" "ls" >/dev/null
elapsed=$(( ($(date +%s%N) - start) / 1000000 ))
if [ "$elapsed" -lt 1000 ]; then ok "non-push bail took ${elapsed}ms"
else bad "non-push bail" "took ${elapsed}ms, expected well under 1000ms"; fi

# A long command must not be quadratic. The bash character loop this replaced took 618ms
# on this input; the substring bail plus one awk pass is ~14ms. The threshold is loose on
# purpose — this is a guard against reintroducing quadratic scanning, not a benchmark.
big="$(head -c 8000 /dev/zero | tr '\0' 'y')"
start=$(date +%s%N)
decision "$TMP/clean" "cat > f <<EOF
$big
git push origin main
EOF" >/dev/null
elapsed=$(( ($(date +%s%N) - start) / 1000000 ))
if [ "$elapsed" -lt 250 ]; then ok "8000-char heredoc scanned in ${elapsed}ms"
else bad "large-command scan" "took ${elapsed}ms; expected <250ms (quadratic scan back?)"; fi

if [ "$SKIP" -gt 0 ]; then
  printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
  printf 'Skips are the fail-open paths: with no gofmt on PATH nothing can produce a\n'
  printf 'finding, so the gate allows and the deny assertions cannot be made.\n'
else
  printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
fi
[ "$FAIL" -eq 0 ]
