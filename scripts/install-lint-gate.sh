#!/usr/bin/env bash
# install-lint-gate.sh — Put the SERV-58 push gate in front of every repo on this box.
#
# WHAT IT DOES. Copies lint-gate.sh to ~/.claude/hooks/ and registers one PreToolUse hook
# in ~/.claude/settings.json. User-level, so every repository is covered by default with
# no per-repo setup — which was the point of the ticket. A repo that wants different
# behaviour overrides it in its own .claude/settings.json; a machine that wants none sets
# CONSTRUCT_LINT_GATE=0.
#
# WHY IT COPIES RATHER THAN POINTING AT THE CHECKOUT. The tempting version of this
# registers `~/construct-server/scripts/lint-gate.sh` and skips the copy, so the gate
# updates itself on every `git pull`. Do not: `~/construct-server` is a plain working copy
# that is routinely on a feature branch, and sessions share it — a concurrent `git
# checkout` would silently change the gate in front of your push, which is a strange thing
# to debug at the moment it happens. The same reasoning is why the stack deploys from
# /opt/construct-server and not from a checkout (SERV-76).
#
# The cost of copying is drift: the installed copy can fall behind git. So the copy is
# stamped with the source's content hash and `--check` reports when they differ, which is
# the same shape as check-compose-drift.sh. Drift you can see is a chore; drift you cannot
# is the actual hazard.
#
# Usage:
#   ./scripts/install-lint-gate.sh            install or update
#   ./scripts/install-lint-gate.sh --check    report whether it is installed and current
#   ./scripts/install-lint-gate.sh --uninstall remove the hook and the installed copy

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lint-gate.sh"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
HOOK_DIR="$CLAUDE_DIR/hooks"
DEST="$HOOK_DIR/lint-gate.sh"
SETTINGS="$CLAUDE_DIR/settings.json"
STAMP="$HOOK_DIR/.lint-gate.sha256"

# The command Claude Code runs. $HOME is stored LITERALLY and expanded by the shell
# Claude Code runs the hook in, so the settings file stays portable between machines and
# readable to a person. The single quotes are the point, not an oversight.
# shellcheck disable=SC2016
HOOK_CMD='"$HOME"/.claude/hooks/lint-gate.sh'

command -v jq >/dev/null 2>&1 || { echo "install-lint-gate: jq is required" >&2; exit 1; }
[ -f "$SRC" ] || { echo "install-lint-gate: cannot find $SRC" >&2; exit 1; }

src_hash() { sha256sum "$SRC" | cut -d' ' -f1; }

# Does settings.json already carry our hook? Matched on the command containing
# lint-gate.sh rather than on an exact string, so a hand-tweaked timeout still counts as
# installed and does not get silently duplicated.
installed_in_settings() {
  [ -f "$SETTINGS" ] || return 1
  jq -e '(.hooks.PreToolUse // [])[]?.hooks[]? | select(.command? // "" | test("lint-gate\\.sh"))' \
    "$SETTINGS" >/dev/null 2>&1
}

case "${1:-install}" in
  --check)
    rc=0
    if installed_in_settings; then echo "hook:      registered in $SETTINGS"
    else echo "hook:      NOT registered in $SETTINGS"; rc=1; fi

    if [ -x "$DEST" ]; then
      if [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$(src_hash)" ]; then
        echo "gate:      $DEST ($("$DEST" --version)), matches this checkout"
      else
        echo "gate:      $DEST is INSTALLED BUT STALE — re-run 'make lint-gate-install'"
        rc=1
      fi
    else
      echo "gate:      not installed at $DEST"; rc=1
    fi
    exit "$rc"
    ;;

  --uninstall)
    if [ -f "$SETTINGS" ]; then
      tmp="$(mktemp)"
      jq '(.hooks.PreToolUse // []) |= (map(.hooks |= map(select((.command? // "") | test("lint-gate\\.sh") | not)))
            | map(select((.hooks | length) > 0)))
          | if (.hooks.PreToolUse | length) == 0 then del(.hooks.PreToolUse) else . end
          | if (.hooks | length) == 0 then del(.hooks) else . end' \
        "$SETTINGS" > "$tmp"
      mv "$tmp" "$SETTINGS"
      echo "removed the hook from $SETTINGS"
    fi
    rm -f "$DEST" "$STAMP"
    echo "removed $DEST"
    exit 0
    ;;

  install) ;;
  *) echo "usage: install-lint-gate.sh [--check|--uninstall]" >&2; exit 2 ;;
esac

mkdir -p "$HOOK_DIR"
install -m 0755 "$SRC" "$DEST"
src_hash > "$STAMP"
echo "installed $DEST ($("$DEST" --version))"

[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"

# Refuse to write a settings file we cannot parse. A malformed settings.json silently
# disables EVERY setting in it, so clobbering one would take permissions and model choice
# down with it and the symptom would look nothing like this script.
jq -e . "$SETTINGS" >/dev/null 2>&1 || {
  echo "install-lint-gate: $SETTINGS is not valid JSON; fix it first, refusing to write" >&2
  exit 1
}

cp "$SETTINGS" "$SETTINGS.bak"

# Drop any previous registration, then append exactly one. Idempotent by construction:
# running this twice leaves one hook, not two.
#
# The matcher is a bare "Bash", not `if: "Bash(git push:*)"`. See the long note in
# lint-gate.sh — that filter is a prefix match and would miss `git add -A && ... && git
# push`, which is the form agents use, so the gate would silently never fire.
tmp="$(mktemp)"
jq --arg cmd "$HOOK_CMD" '
  .hooks //= {} |
  .hooks.PreToolUse //= [] |
  .hooks.PreToolUse |= (map(.hooks |= map(select((.command? // "") | test("lint-gate\\.sh") | not)))
                        | map(select((.hooks | length) > 0))) |
  .hooks.PreToolUse += [{
    matcher: "Bash",
    hooks: [{
      type: "command",
      command: $cmd,
      timeout: 120,
      statusMessage: "Checking format and lint before push"
    }]
  }]' "$SETTINGS" > "$tmp"

jq -e . "$tmp" >/dev/null 2>&1 || { echo "install-lint-gate: refused to write invalid JSON" >&2; exit 1; }
mv "$tmp" "$SETTINGS"

echo "registered the PreToolUse hook in $SETTINGS (previous copy at $SETTINGS.bak)"
echo
echo "Claude Code reloads settings on its own, but a session that was already running"
echo "may need /hooks opened once before the gate fires."
