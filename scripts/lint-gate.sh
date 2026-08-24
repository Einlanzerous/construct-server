#!/usr/bin/env bash
# lint-gate.sh — Run a repo's format/lint checks before `git push`, and block the push
# if they fail (SERV-58).
#
# THE PROBLEM. Agent-authored PRs land with formatting errors, CI goes red, and the fix
# costs a full round trip: a red run, a fix commit, a re-run, and a human noticing. It
# was reported roughly twenty times across ARGY / LYCM / ITLK / SGNT in the June-July
# window. Every one of those was knowable locally in under a second — `gofmt -l` and
# `prettier --check` need no network, no build and no database. The round trip was pure
# waste.
#
# WHAT THIS IS. A Claude Code PreToolUse hook. It reads the hook payload on stdin, and
# when the Bash command about to run is a `git push`, it discovers what the repository is
# written in, runs that language's *check* commands, and answers `deny` with the failing
# output if any of them fail. The agent reads the denial and fixes the code without ever
# having pushed. Installed once at the user level, it covers every repo on the box; see
# install-lint-gate.sh and docs/lint-gate.md.
#
# THE FAILURE DIRECTION IS THE OPPOSITE OF deploy-scope.sh, DELIBERATELY. That script
# fails closed: when it cannot answer, the deploy does the widest safe thing. This one
# fails OPEN — every internal error, missing tool, unreadable payload or timeout ALLOWS
# the push. The asymmetry is not an oversight, and the reasoning is worth keeping:
#
#   * CI is still the backstop. A false allow costs exactly what today already costs —
#     one red run. Nothing regresses.
#   * A false BLOCK is unbounded. This hook sits in front of every `git push` in every
#     repo on the machine, including the self-hosted runner's $HOME. A bug that blocks
#     wrongly cannot be worked around by the thing it is blocking, and the reflex it
#     trains is `CONSTRUCT_LINT_GATE=0`, permanently, which costs the whole feature.
#   * So: this only ever blocks on a check that ran to completion and reported a real
#     finding. Anything it could not run is reported as a SKIP and does not block.
#
# WHAT IT DELIBERATELY DOES NOT RUN. The gate is only worth having if it is cheap enough
# to leave on, and only credible if it never blocks on something CI would accept:
#
#   * `golangci-lint` — argosy's CI pins v2.12.2 and installs it per-run; the box has an
#     unpinned copy on PATH. Different versions disagree, and the gate would block on
#     findings CI does not have. Version skew in a blocking gate is how you teach people
#     to bypass it.
#   * Typecheck, build and test — slow (vue-tsc alone is tens of seconds), and they need
#     installed dependencies and sometimes a database. This gate targets the failure that
#     was actually reported: formatting and lint.
#   * Anything that WRITES. `prettier --write`, `gofmt -w`, `dart format` without
#     `--output=none` all rewrite the tree. A gate that silently edits your files after
#     you have reviewed the diff and during a push is a worse bug than the one it fixes.
#     Every command below is a check. The gate reports; you fix.
#
# USAGE
#   lint-gate.sh                 hook mode: read the payload on stdin, emit a decision
#   lint-gate.sh --check [dir]   run the checks now against dir (default: cwd), human output
#   lint-gate.sh --explain [dir] list the units found and what would run, without running
#   lint-gate.sh --version       print the gate's version stamp
#
# ESCAPE HATCHES
#   CONSTRUCT_LINT_GATE=0        disable entirely
#   git push --no-verify         honoured, on the same reasoning git honours it

set -uo pipefail

LINT_GATE_VERSION=1

# Per-check and whole-run ceilings. The whole-run one matters more than it looks: the
# hook blocks the agent's turn while it runs, so a pathological repo must not hang it.
CHECK_TIMEOUT="${CONSTRUCT_LINT_GATE_CHECK_TIMEOUT:-60}"
TOTAL_TIMEOUT="${CONSTRUCT_LINT_GATE_TOTAL_TIMEOUT:-100}"

# How much failing output reaches the agent. Enough to act on, not enough to flood the
# context window — a bare `eslint .` on a broken tree can print thousands of lines.
MAX_REPORT_LINES="${CONSTRUCT_LINT_GATE_MAX_LINES:-60}"

# ---------------------------------------------------------------------------
# Decisions
#
# Hook mode speaks the PreToolUse JSON contract; --check speaks to a person. Both funnel
# through here so there is one place where "allow" and "deny" are decided.
# ---------------------------------------------------------------------------

MODE=hook
WATCHDOG_PID=""

# The watchdog must die before we exit, and not only so it stops ticking. A background
# child inherits the hook's stdout, and Claude Code reads that pipe to EOF — so a live
# child holds the pipe open and the push appears to hang for the full TOTAL_TIMEOUT even
# though the decision was made in milliseconds. Killing it here, plus the >/dev/null on
# the subshell itself, is what keeps an allow instant.
stop_watchdog() {
  [ -n "$WATCHDOG_PID" ] && kill "$WATCHDOG_PID" 2>/dev/null
  WATCHDOG_PID=""
  return 0
}

allow() {
  # $1: optional reason, for the log only. An allow is silent by design: this fires on
  # every Bash call, and a gate that narrates itself is a gate you turn off.
  stop_watchdog
  if [ "$MODE" = check ]; then
    [ -n "${1:-}" ] && printf '%s\n' "$1"
    exit 0
  fi
  exit 0
}

deny() {
  # $1: the report shown to the agent. jq builds the JSON so that quotes, newlines and
  # backslashes in compiler output cannot break out of the string.
  local report="$1"
  stop_watchdog
  if [ "$MODE" = check ]; then
    printf '%s\n' "$report"
    exit 1
  fi
  jq -cn --arg r "$report" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
  exit 0
}

# HOW FAIL-OPEN IS ACTUALLY ACHIEVED. An earlier version of this line was
# `trap 'allow' ERR`, which does not work and is worse than nothing because it reads like
# a safety net: bash does not inherit an ERR trap into shell functions without `set -E`,
# and everything here runs inside one. Adding `set -E` would be actively harmful — half
# these functions return non-zero as their normal answer (has_script, run_check), so the
# trap would fire on the first failing check and allow the push it was about to block.
#
# The real guarantee is structural, and it is why `set -e` is absent:
#
#   * Nothing aborts. Without `set -e` a failing command just continues, so a bug in one
#     check cannot skip the rest or exit half-decided.
#   * FAILURES is only ever appended to by an explicit record_failure call, so a block
#     requires a check to have run and reported. There is no path where confusion
#     produces a denial.
#   * Every guard (no jq, no git, not a repo, exempt push) ends in an explicit allow.
#   * In hook mode the script never exits 2 — the only exit status Claude Code treats as
#     blocking — so even an outright crash lets the push through.

# ---------------------------------------------------------------------------
# Is this a push we should gate at all?
# ---------------------------------------------------------------------------

# Find the `git push` inside a command string, and hand back its own arguments.
#
# Two requirements pull in opposite directions and this is where they are reconciled.
#
# It must catch `git add -A && git commit -m x && git push`, because that compound form is
# how an agent actually pushes. (It is also why the hook is registered on a bare `Bash`
# matcher rather than with `if: "Bash(git push:*)"` — that filter is a prefix match, so it
# would not match the compound form and the gate would silently never fire. Matching every
# Bash call and bailing here costs one jq parse and one substring test: ~9ms, and flat in
# the length of the command — an 8000-character non-push measures the same as `ls`,
# because the substring test in find_git_push runs before anything else. Only a command
# that actually contains "git push" pays for the segment scan, and that is ~14ms at 8000
# characters. An earlier revision did the scan as a bash character loop, which is
# quadratic: 618ms on that same input. Keep the cheap test first.)
#
# But it must NOT match `git commit -m 'remember to git push'`. Blocking a *commit*
# because its message mentions pushing is a baffling failure, and a gate people cannot
# predict is a gate they switch off.
#
# So: split on shell separators and require `git push` in COMMAND POSITION — the start of
# a segment, not anywhere inside one. Sets PUSH_ARGS to that push's own arguments, which
# is what the exemption parser needs; feeding it the whole command string instead is what
# made `git push origin v1.0.0` parse `push` as a refspec.
# Split into segments a command could START at: on `&&`, `||`, `;` and newline, but only
# outside quotes, and never inside a heredoc body.
#
# Three cases have to hold at once, and each of the first two was a real bug:
#
#   1. `git commit -m "wip; git push later"` must NOT match. A blind split treats that
#      `;` as real, puts `git push later` in command position, and blocks the *commit*.
#   2. `cat > deploy.md <<EOF … git push origin main … EOF` must NOT match. A heredoc body
#      is not shell-quoted, so quote tracking alone does not save you — every line of it
#      looks like command position. This one is worse than (1): the command being blocked
#      is a file WRITE, and the advertised escape hatch cannot be applied, because
#      `--no-verify` is a `git push` flag and there is nowhere to put it on a `cat`.
#      Documenting a push (writing this repo's own docs from a heredoc) would trip it.
#   3. A plain multi-line script MUST still match:
#          git add -A
#          git commit -m x
#          git push
#      This is why newline stays a separator. Dropping it is the cheap fix for (2) and it
#      is the wrong trade — it converts a false block into a SILENT MISS, and a gate that
#      quietly stops firing is the failure this whole design is arranged against.
#
# So: skip heredoc bodies, then split the rest quote-aware.
#
# HEREDOC DETECTION IS PART OF THE CHARACTER PASS, not a regex over the raw line. It was
# a pre-pass once, and being outside the quote state it was bolted onto broke it three
# ways at once — in both directions:
#
#   * It missed `<<\EOF`. Backslash is bash's fourth way of quoting a terminator, exactly
#     equivalent to `<<'EOF'`, and `\` is neither a quote nor a word character, so the
#     match failed, no terminator was recorded, and the body was scanned as code. Same
#     for a terminator that is not a bare identifier, like `<<'EOF-1'`. Both are FALSE
#     BLOCKS on a `cat`, the case this file already calls its worst: `--no-verify` is a
#     `git push` flag and there is nowhere to put it on a write.
#   * It fired on `<<<`, a here-string, which opens no heredoc at all.
#   * It fired on `<<` inside a quoted string — `git commit -m "explain << redirects"` —
#     because the regex ran before any quote tracking.
#
#     The last two are SILENT MISSES: a terminator gets recorded that never arrives, so
#     every following line is swallowed and a real `git push` after it is never seen.
#     By this file's own argument that is the worse direction, and it is the one the test
#     suite structurally cannot notice, because nothing is reported.
#
# Note the general "backslash escaping is not modelled, and a mis-split only ever lints
# early" argument does NOT extend here. It holds for the separator scan; on the heredoc
# path a missed backslash errs toward a false block instead.
#
# Done in one awk pass rather than a bash character loop. `${s:i:1}` in a loop is
# quadratic — measured at 597ms on an 8000-character command, against 3ms for the
# substitution it replaced — and long commands are exactly the heredocs case (2) is about.
# awk is a single linear pass in C and keeps this in the sub-millisecond range.
split_segments() {
  SEGMENTS=()
  local seg
  # NUL-delimited, not newline-delimited. A segment may now legitimately CONTAIN a
  # newline (a multi-line quoted string is one segment), so splitting the awk output on
  # newlines here would undo the fix below and hand back `git push origin main` as its
  # own segment again.
  while IFS= read -r -d "" seg; do
    SEGMENTS+=("$seg")
  done < <(printf '%s' "$1" | awk '
    function emit(s) { printf "%s%c", s, 0 }
    BEGIN { SQ = sprintf("%c", 39); DQ = sprintf("%c", 34); BS = sprintf("%c", 92)
            q = ""; term = ""; cur = "" }
    {
      # Inside a heredoc body: emit nothing until the terminator line.
      if (term != "") {
        t = $0; sub(/^[ \t]+/, "", t)          # <<- allows an indented terminator
        if ($0 == term || t == term) term = ""
        next
      }
      n = length($0)
      for (i = 1; i <= n; i++) {
        c = substr($0, i, 1)
        if (q != "") { if (c == q) q = ""; cur = cur c; continue }
        if (c == SQ || c == DQ) { q = c; cur = cur c; continue }

        # `<<` only counts as a heredoc OUTSIDE quotes, which is the whole point of
        # deciding it here rather than up front.
        if (c == "<" && substr($0, i + 1, 1) == "<") {
          if (substr($0, i + 2, 1) == "<") {    # `<<<` is a here-string, not a heredoc
            cur = cur "<<<"; i += 2; continue
          }
          if (term == "") {                     # first heredoc on the line wins
            j = i + 2
            if (substr($0, j, 1) == "-") j++    # <<-
            while (substr($0, j, 1) == " " || substr($0, j, 1) == "\t") j++
            qq = substr($0, j, 1); w = ""
            if (qq == SQ || qq == DQ) {         # <<"EOF" / <<'"'"'EOF'"'"'
              j++
              while (j <= n && substr($0, j, 1) != qq) { w = w substr($0, j, 1); j++ }
            } else {
              if (qq == BS) j++                 # <<\EOF — same as quoting it
              while (j <= n) {
                ch = substr($0, j, 1)
                if (ch == " " || ch == "\t" || ch == ";" || ch == "&" || ch == "|" \
                    || ch == "<" || ch == ">") break
                w = w ch; j++
              }
            }
            if (w != "") term = w               # body starts on the NEXT line
          }
          cur = cur "<<"; i++; continue
        }

        if (c == "&" || c == "|" || c == ";") { emit(cur); cur = ""; continue }
        cur = cur c
      }
      # End of line is a separator — but ONLY outside quotes. `q` deliberately survives
      # across lines (it is initialised in BEGIN, not per record), so an unterminated
      # quote here means the newline is part of a multi-line string, not a command
      # boundary. Printing unconditionally made every line of a multi-line `-m` or
      # `--body` command position: `git commit -m "…⏎git push origin main⏎"` and
      # `gh pr create --body "…"` both blocked, on commands that are not pushes and
      # where `--no-verify` has nowhere to go.
      #
      # This is the single-line quoted-separator bug one axis over, and it was a
      # regression: the bash character loop this replaced tested the quote state before
      # the separator and got it right.
      if (q != "") { cur = cur "\n"; next }
      emit(cur); cur = ""
    }
    END { if (cur != "") emit(cur) }            # flush an unterminated trailing quote
  ')
}

PUSH_ARGS=""
find_git_push() {
  local seg
  # The overwhelmingly common case is a Bash call with no push in it at all. Answer that
  # without spawning awk: this is what keeps the bare `Bash` matcher cheap enough to
  # leave on, and it is a plain substring test, not a command-position one, so it can
  # only ever send work to the real scan below.
  case "$1" in *"git push"*) ;; *) return 1 ;; esac
  split_segments "$1"
  for seg in ${SEGMENTS+"${SEGMENTS[@]}"}; do
    seg="${seg#"${seg%%[![:space:]]*}"}"   # strip leading whitespace
    case "$seg" in
      "git push")   PUSH_ARGS=""; return 0 ;;
      "git push "*) PUSH_ARGS="${seg#git push }"; return 0 ;;
    esac
  done
  return 1
}

# Decide whether a push is exempt, and say why. Exempt pushes carry no reviewable source
# change, so linting them is pure latency:
#
#   * tag pushes — release-please cuts the tag, the content was linted on the way to main
#   * release-please branches — generated CHANGELOG/version commits, nothing hand-written
#   * --delete — removes a remote ref, pushes no content at all
#   * --dry-run — by definition changes nothing
#   * --no-verify — the user said to skip verification; git honours that and so do we
#
# Returns 0 and echoes the reason when exempt.
push_exemption() {
  local repo="$1"; shift
  local -a positional=()
  local arg tags_only=0

  # $@ here is already only the push's own arguments; positional[0] is the remote.
  for arg in "$@"; do
    case "$arg" in
      --no-verify)             echo "--no-verify"; return 0 ;;
      --dry-run|-n)            echo "--dry-run"; return 0 ;;
      --delete|-d)             echo "--delete (removes a ref, pushes no content)"; return 0 ;;
      --tags)                  tags_only=1 ;;
      # --follow-tags pushes the branch AND its tags, so the branch still wants linting.
      --follow-tags)           ;;
      -*)                      ;;
      *)                       positional+=("$arg") ;;
    esac
  done

  [ "$tags_only" = 1 ] && { echo "--tags (tag push)"; return 0; }

  # positional[0] is the remote; the rest are refspecs. With no refspec, git pushes the
  # current branch, so that is what we have to resolve and judge.
  local -a refs=()
  if [ "${#positional[@]}" -gt 1 ]; then
    refs=("${positional[@]:1}")
  else
    local head
    head="$(git -C "$repo" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
    [ -n "$head" ] && refs=("$head")
  fi

  # No resolvable ref (detached HEAD, or a form we do not model) is not an exemption —
  # it falls through and gets linted. Erring toward running the checks is safe here;
  # erring toward skipping them is the silent pass.
  [ "${#refs[@]}" -eq 0 ] && return 1

  local ref src
  for ref in "${refs[@]}"; do
    # A refspec is [+]<src>[:<dst>]; only the source side names something local.
    src="${ref%%:*}"
    src="${src#+}"
    case "$src" in
      refs/tags/*) continue ;;
      release-please--*|release-please/*) continue ;;
      refs/heads/release-please--*|refs/heads/release-please/*) continue ;;
    esac
    # Ask git rather than pattern-matching version strings: a tag is whatever the repo
    # says is a tag.
    if git -C "$repo" rev-parse --verify --quiet "refs/tags/$src" >/dev/null 2>&1; then
      continue
    fi
    # This ref is neither a tag nor a release branch, so the push carries real source.
    return 1
  done

  echo "only tags and release-please branches"
  return 0
}

# ---------------------------------------------------------------------------
# Unit discovery
#
# "Language-agnostic dispatch" means a repo is not one language — argosy is Go + Vue +
# Flutter, lyceum is Go + TS + Flutter. So we find every buildable unit and check each,
# rather than matching the repo to a single toolchain and stopping.
# ---------------------------------------------------------------------------

# Directories that never contain source we own — or, in `.claude`'s case, contain source
# that is emphatically someone else's. Claude Code puts nested worktrees under
# `.claude/worktrees/`, and lyceum has one: without this prune the gate discovers a second
# copy of the repo, lints a branch nobody is pushing, and reports findings against files
# that are not in the diff.
PRUNE=(-name node_modules -o -name vendor -o -name .git -o -name dist -o -name build
       -o -name .next -o -name .nuxt -o -name target -o -name .venv -o -name .claude)

find_markers() {
  # $1 repo root, $2 marker filename. Depth 4 covers every layout in the estate
  # (argosy/mobile/argosy/pubspec.yaml is the deepest) without walking media trees.
  #
  # Sorted SHALLOWEST FIRST, which covered_by_node_unit depends on: a workspace root can
  # only suppress its members if it has already been seen when they come up. Plain `sort`
  # is lexical, so `<repo>/apps/web/package.json` sorts before `<repo>/package.json` and
  # the root lost to its own member. Depth first, then lexically for a stable order.
  find "$1" -maxdepth 4 \( "${PRUNE[@]}" \) -prune -o -name "$2" -print 2>/dev/null \
    | awk -F/ '{print NF"\t"$0}' | sort -k1,1n -k2 | cut -f2-
}

# Which package manager runs this unit's scripts? The lockfile is the authority; the
# estate is mostly bun with cta-watch on npm.
pkg_manager() {
  local dir="$1"
  if   [ -f "$dir/bun.lockb" ] || [ -f "$dir/bun.lock" ]; then echo bun
  elif [ -f "$dir/pnpm-lock.yaml" ];                      then echo pnpm
  elif [ -f "$dir/yarn.lock" ];                           then echo yarn
  elif [ -f "$dir/package-lock.json" ];                   then echo npm
  else echo ""
  fi
}

# Walk up to the repo root looking for a lockfile — a workspace member has none of its
# own, the root holds it.
pkg_manager_for() {
  local dir="$1" repo="$2" pm
  while :; do
    pm="$(pkg_manager "$dir")"
    [ -n "$pm" ] && { echo "$pm"; return; }
    [ "$dir" = "$repo" ] && break
    dir="$(dirname "$dir")"
  done
  # No lockfile anywhere: bun is the estate default and can run any package.json script.
  command -v bun >/dev/null 2>&1 && echo bun || echo npm
}

has_script() {
  jq -e --arg s "$2" '.scripts // {} | has($s)' "$1/package.json" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Running a check
#
# Every check funnels through here so that the skip-vs-block distinction is made in one
# place, and so that no check can run without a timeout.
# ---------------------------------------------------------------------------

FAILURES=""   # blocking findings, formatted for the report
SKIPS=""      # things we could not run, reported but never blocking
RAN=0

record_failure() {
  FAILURES="${FAILURES}
── $1
$2
"
}

record_skip() {
  SKIPS="${SKIPS}
── skipped: $1 ($2)"
}

# run_check <label> <dir> <command...>
# Exit 0 -> pass. Non-zero -> the caller decides whether the output is a finding or a
# setup failure, because only the caller knows what its tool's setup failures look like.
CHECK_OUT=""
run_check() {
  local label="$1" dir="$2"; shift 2
  RAN=$((RAN + 1))
  CHECK_OUT="$(cd "$dir" && timeout "$CHECK_TIMEOUT" "$@" 2>&1)"
  local rc=$?
  if [ "$rc" = 124 ]; then
    record_skip "$label" "timed out after ${CHECK_TIMEOUT}s"
    return 0
  fi
  return "$rc"
}

# Does this output carry real, file-anchored diagnostics? Used to tell a genuine finding
# from a toolchain that could not start. `go vet` is the case that forces this: argosy's
# CI runs `make ensure-embed` before vet, so on a fresh tree vet fails with a build error
# that says nothing about code quality. Blocking on that would make the gate fire on
# every argosy push forever.
has_diagnostics() {
  printf '%s' "$1" | grep -qE '^[^[:space:]]*\.(go|ts|tsx|js|jsx|vue|dart|rs):[0-9]+'
}

# ---------------------------------------------------------------------------
# The language checks
# ---------------------------------------------------------------------------

check_go() {
  local dir="$1" rel="$2" out files

  # gofmt over git-tracked files rather than `./...`: it is exact about what is ours,
  # and it skips testdata and generated trees that git already knows to ignore.
  files="$(cd "$dir" && git ls-files -- '*.go' 2>/dev/null)"
  if [ -n "$files" ]; then
    # gofmt must be guarded exactly like `go` below, and the omission was not academic.
    # `go` and `gofmt` live in ~/go/bin here, which reaches PATH only through ~/.zshrc —
    # so any non-login shell cannot see them, INCLUDING the self-hosted runner that
    # CLAUDE.md already has a bare-system-PATH invariant about. Unguarded, xargs wrote
    # `xargs: gofmt: No such file or directory` to stderr, the `-s "$errs"` test below
    # turned that into a "could not parse" FAILURE, and every push from every repo with a
    # go.mod was denied — naming a formatting problem that did not exist, on a tree that
    # was correctly formatted, with no way for the agent to fix it. That is the precise
    # scenario the fail-open invariant exists to forbid, arrived at from inside.
    if ! command -v gofmt >/dev/null 2>&1; then
      record_skip "gofmt — $rel" "gofmt is not on PATH"
    else
      RAN=$((RAN + 1))
      local errs rc
      errs="$(mktemp)"
      # stdout is the list of files that need formatting; stderr is parse errors. They mean
      # different things and must not be blended — "needs gofmt: syntax error" reads as a
      # formatting nit and is actually broken code.
      out="$(cd "$dir" && printf '%s\n' "$files" | timeout "$CHECK_TIMEOUT" xargs -r gofmt -l 2>"$errs")"
      rc=$?
      if [ "$rc" = 127 ] || [ "$rc" = 124 ]; then
        # 127: xargs could not exec gofmt at all. 124: the timeout fired. Neither is a
        # statement about the code. stderr is a catch-all, so the exit status is what
        # separates "gofmt spoke" from "gofmt never ran".
        record_skip "gofmt — $rel" "gofmt could not run (exit $rc)"
      else
        if [ -n "$out" ]; then
          record_failure "gofmt — $rel" "$(printf '%s' "$out" | sed 's|^|  needs gofmt: |')"
        fi
        if [ -s "$errs" ]; then
          record_failure "gofmt could not parse — $rel" "$(cat "$errs")"
        fi
      fi
      rm -f "$errs"
    fi
  fi

  if command -v go >/dev/null 2>&1; then
    if ! run_check "go vet — $rel" "$dir" go vet ./...; then
      if has_diagnostics "$CHECK_OUT"; then
        record_failure "go vet — $rel" "$CHECK_OUT"
      else
        # Build/setup failure, not a vet finding. See has_diagnostics.
        record_skip "go vet — $rel" "the package would not build; CI will say why"
      fi
    fi
  else
    record_skip "go vet — $rel" "go is not on PATH"
  fi
}

check_node() {
  local dir="$1" rel="$2" pm="$3" script

  # The package manager is chosen from the lockfile, which says what the repo WANTS, not
  # what this box has. A pnpm or yarn lockfile on a machine with neither installed would
  # otherwise exit 127 and block the push on "command not found" — a false block, and
  # against the rule that we only ever block on a check that actually ran.
  if ! command -v "$pm" >/dev/null 2>&1; then
    record_skip "node — $rel" "$pm is not on PATH"
    return
  fi

  # Without an install there is no eslint and no prettier to run. Skip, loudly: blocking
  # here would fail every fresh checkout, which is exactly how a gate gets disabled.
  if [ ! -d "$dir/node_modules" ]; then
    record_skip "node — $rel" "node_modules is not installed"
    return
  fi

  # Note there is deliberately no has_diagnostics filter here, unlike go vet. Prettier
  # reports a formatting failure as `[warn] src/foo.ts`, which carries no file:line — so
  # filtering on that shape would skip the single most common finding this gate exists to
  # catch. The trade is that a genuinely broken lint setup blocks; the report shows the
  # error verbatim, so it is diagnosable rather than mysterious.
  for script in format:check lint; do
    has_script "$dir" "$script" || continue
    if ! run_check "$script — $rel" "$dir" "$pm" run "$script"; then
      record_failure "$pm run $script — $rel" "$CHECK_OUT"
    fi
  done
}

check_dart() {
  local dir="$1" rel="$2"
  if ! command -v dart >/dev/null 2>&1; then
    record_skip "dart format — $rel" "dart is not on PATH"
    return
  fi
  # --output=none is what makes this a check. Without it, dart format REWRITES the tree.
  if ! run_check "dart format — $rel" "$dir" dart format --output=none --set-exit-if-changed .; then
    record_failure "dart format — $rel" "$CHECK_OUT"
  fi
}

check_rust() {
  local dir="$1" rel="$2"
  if ! command -v cargo >/dev/null 2>&1; then
    record_skip "cargo fmt — $rel" "cargo is not on PATH"
    return
  fi
  if ! run_check "cargo fmt — $rel" "$dir" cargo fmt --check; then
    record_failure "cargo fmt — $rel" "$CHECK_OUT"
  fi
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

PLAN=""   # for --explain

# Is $1 inside a directory we already selected as a Node unit?
#
# interlock's root script is `eslint .`, which already covers apps/* and packages/*, so
# selecting a member as well would run eslint twice and report every finding twice. The
# earlier version of this compared only the FIRST path component, which silently failed
# for the exact case it was written for: a member at `apps/web` never matched a root
# recorded as `.`. Compare real ancestry instead.
NODE_DIRS=()
covered_by_node_unit() {
  local dir="$1" sel
  for sel in ${NODE_DIRS+"${NODE_DIRS[@]}"}; do
    [ "$dir" = "$sel" ] && continue
    case "$dir/" in "$sel"/*) return 0 ;; esac
  done
  return 1
}

gather() {
  local repo="$1" explain_only="${2:-0}"
  local marker dir rel pm

  # `while read` rather than `for x in $(...)`: a path with a space in it would otherwise
  # split into two nonexistent directories.
  while IFS= read -r marker; do
    [ -n "$marker" ] || continue
    dir="$(dirname "$marker")"; rel="${dir#"$repo"/}"; [ "$dir" = "$repo" ] && rel=.
    PLAN="${PLAN}
  go     $rel  ->  gofmt -l, go vet ./..."
    [ "$explain_only" = 1 ] || check_go "$dir" "$rel"
  done < <(find_markers "$repo" go.mod)

  while IFS= read -r marker; do
    [ -n "$marker" ] || continue
    dir="$(dirname "$marker")"; rel="${dir#"$repo"/}"; [ "$dir" = "$repo" ] && rel=.
    # Only a unit if it actually defines a check. "No-op cleanly when a repo has none" is
    # the common case in this estate, not the edge case: switchyard and cta-watch define
    # neither script and correctly come back empty.
    has_script "$dir" lint || has_script "$dir" format:check || continue
    covered_by_node_unit "$dir" && continue
    NODE_DIRS+=("$dir")
    pm="$(pkg_manager_for "$dir" "$repo")"
    PLAN="${PLAN}
  node   $rel  ->  $pm run $(has_script "$dir" format:check && printf 'format:check, ')$(has_script "$dir" lint && printf 'lint')"
    [ "$explain_only" = 1 ] || check_node "$dir" "$rel" "$pm"
  done < <(find_markers "$repo" package.json)

  while IFS= read -r marker; do
    [ -n "$marker" ] || continue
    dir="$(dirname "$marker")"; rel="${dir#"$repo"/}"
    PLAN="${PLAN}
  dart   $rel  ->  dart format --output=none --set-exit-if-changed"
    [ "$explain_only" = 1 ] || check_dart "$dir" "$rel"
  done < <(find_markers "$repo" pubspec.yaml)

  while IFS= read -r marker; do
    [ -n "$marker" ] || continue
    dir="$(dirname "$marker")"; rel="${dir#"$repo"/}"; [ "$dir" = "$repo" ] && rel=.
    PLAN="${PLAN}
  rust   $rel  ->  cargo fmt --check"
    [ "$explain_only" = 1 ] || check_rust "$dir" "$rel"
  done < <(find_markers "$repo" Cargo.toml)
}

build_report() {
  local body count
  body="$(printf '%s' "$FAILURES" | sed '/^$/d')"
  count="$(printf '%s\n' "$body" | grep -c '^── ' || true)"

  if [ "$(printf '%s\n' "$body" | wc -l)" -gt "$MAX_REPORT_LINES" ]; then
    body="$(printf '%s\n' "$body" | head -n "$MAX_REPORT_LINES")
  … output truncated; run the failing command above to see the rest."
  fi

  printf '%s\n\n%s\n\n%s' \
    "Push blocked: $count check(s) failed locally. CI would have failed on these." \
    "$body" \
    "Fix them and push again — this is the same lint/format CI runs, so a green gate here means no lint-only red run there. To bypass once: git push --no-verify"
}

main() {
  [ "${CONSTRUCT_LINT_GATE:-1}" = 0 ] && allow "lint-gate: disabled via CONSTRUCT_LINT_GATE=0"

  local cwd command explain=0
  case "${1:-}" in
    --version) echo "lint-gate.sh v$LINT_GATE_VERSION"; exit 0 ;;
    --check)   MODE=check; cwd="${2:-$PWD}"; command="git push" ;;
    --explain) MODE=check; explain=1; cwd="${2:-$PWD}"; command="git push" ;;
    "")
      command -v jq >/dev/null 2>&1 || allow
      local payload; payload="$(cat)"
      command="$(printf '%s' "$payload" | jq -r '.tool_input.command // ""' 2>/dev/null)"
      cwd="$(printf '%s' "$payload" | jq -r '.cwd // ""' 2>/dev/null)"
      [ -n "$cwd" ] || cwd="$PWD"
      find_git_push "$command" || allow
      ;;
    *) echo "usage: lint-gate.sh [--check|--explain [dir]|--version]" >&2; exit 2 ;;
  esac

  command -v jq >/dev/null 2>&1 || allow "lint-gate: jq is not on PATH"
  command -v git >/dev/null 2>&1 || allow "lint-gate: git is not on PATH"

  local repo
  repo="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" || allow "lint-gate: not a git repository"
  [ -n "$repo" ] || allow "lint-gate: not a git repository"

  if [ "$MODE" = hook ]; then
    local reason
    # Unquoted on purpose: PUSH_ARGS is a flat argument string that must word-split into
    # the push's individual arguments.
    # shellcheck disable=SC2086
    if reason="$(push_exemption "$repo" $PUSH_ARGS)"; then
      allow "lint-gate: exempt ($reason)"
    fi
  fi

  if [ "$explain" = 1 ]; then
    gather "$repo" 1
    [ -n "$PLAN" ] && printf 'lint-gate would run in %s:%s\n' "$repo" "$PLAN" \
                   || printf 'lint-gate found nothing to check in %s\n' "$repo"
    exit 0
  fi

  # The whole-run ceiling. gather() runs in this shell (it accumulates state), so the
  # ceiling is enforced by a watchdog that sends us TERM; the TERM trap below then allows.
  # (Not the ERR trap — see the long note above; that one was removed because it never
  # fired. A signal trap does fire in the main shell, which is why this one works.)
  # >/dev/null 2>&1 detaches the child from our stdout; see stop_watchdog.
  ( sleep "$TOTAL_TIMEOUT" && kill -TERM $$ 2>/dev/null ) >/dev/null 2>&1 &
  WATCHDOG_PID=$!
  trap 'allow' TERM

  gather "$repo" 0
  stop_watchdog

  if [ -n "$(printf '%s' "$FAILURES" | tr -d '[:space:]')" ]; then
    deny "$(build_report)"
  fi

  if [ "$MODE" = check ]; then
    printf 'lint-gate: %d check(s) passed in %s\n' "$RAN" "$repo"
    [ -n "$SKIPS" ] && printf '%s\n' "$SKIPS"
    exit 0
  fi
  allow
}

main "$@"
