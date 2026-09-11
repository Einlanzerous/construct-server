#!/usr/bin/env bash
# runner-node-path.sh — Make every self-hosted runner resolve the same node, on purpose
#
# A runner's `.path` is written by `config.sh` from the configuring shell's PATH, and
# `runsvc.sh` exports it verbatim when the systemd unit starts. On this host the
# configuring shell has fnm active, so `.path` captured a PER-SHELL multishell
# directory under /run/user/<uid>/fnm_multishells/ — tmpfs, owned by a shell that has
# long since exited. It resolves until the next reboot and then silently falls
# through to /usr/bin/node, which is v18 and went EOL in April 2025 (SERV-135). Nine of
# thirteen runners carried one; five had already flipped. "Which node does CI run" had
# no answer you could state.
#
# The answer this script enforces: fnm's `default` alias, a symlink fnm maintains under
# $HOME (survives reboots, moves only when someone runs `fnm default`). It is what the
# developer's shell already runs, so CI and local agree; the system node is not a
# candidate while it is EOL. Override with NODE_BIN_DIR to choose differently — the
# point is that it is chosen, not inherited.
#
# What --fix does to each `.path`: drops every fnm_multishells entry, de-duplicates
# (drydock had three copies of its shell PATH concatenated), and inserts NODE_BIN_DIR
# where the first dead entry was — or ahead of the system directories if there was
# none — then proves `node` resolves there and nothing earlier shadows it. Atomic
# rename, so a runner starting mid-write reads one version or the other.
#
# A rewritten `.path` changes NOTHING until the runner's unit restarts: runsvc.sh reads
# it once. The check therefore reports the LIVE listener's PATH (from /proc) next to
# the file, and --restart bounces exactly the idle runners whose two disagree. A busy
# runner (a Runner.Worker in flight) is skipped, never killed — re-run later.
#
# Usage:
#   ./scripts/runner-node-path.sh            check: per-runner table, exit 1 on any defect
#   ./scripts/runner-node-path.sh --fix      rewrite every .path, then check
#   ./scripts/runner-node-path.sh --restart  restart idle runners whose live PATH != .path (sudo)
#   RUNNERS_ROOT   where the runner directories live      (default: $HOME/runners)
#   NODE_BIN_DIR   the directory node must resolve from   (default: fnm's default alias)
set -euo pipefail

RUNNERS_ROOT="${RUNNERS_ROOT:-$HOME/runners}"
NODE_BIN_DIR="${NODE_BIN_DIR:-$HOME/.local/share/fnm/aliases/default/bin}"
MULTISHELL_RE='^/run/user/[0-9]+/fnm_multishells/'
SYSTEM_DIR_RE='^/(usr|bin|sbin)(/|$)'

mode=check
case "${1:-}" in
  "" ) ;;
  --fix ) mode=fix ;;
  --restart ) mode=restart ;;
  -h|--help ) sed -n '2,36p' "$0"; exit 0 ;;
  * ) echo "unknown argument: $1" >&2; exit 2 ;;
esac

if [ ! -x "$NODE_BIN_DIR/node" ]; then
  echo "NODE_BIN_DIR=$NODE_BIN_DIR holds no executable node — nothing to point runners at" >&2
  exit 2
fi

runner_dirs() {
  local d
  for d in "$RUNNERS_ROOT"/*/; do
    [ -f "$d.path" ] && printf '%s\n' "${d%/}"
  done
}

# PATH of the running Runner.Listener whose cwd is this runner dir; empty if none.
live_path() {
  local dir="$1" pid
  for pid in $(pgrep -x Runner.Listener 2>/dev/null || true); do
    if [ "$(readlink "/proc/$pid/cwd" 2>/dev/null)" = "$dir" ]; then
      tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | sed -n 's/^PATH=//p'
      return 0
    fi
  done
  return 0
}

# A job is in flight when a Runner.Worker runs out of this runner's bin directory.
busy() {
  pgrep -f "^$1/bin[^/]*/Runner\.Worker( |$)" >/dev/null 2>&1
}

# Rewrite one .path: drop dead multishell entries, de-duplicate, ensure NODE_BIN_DIR.
rewrite() {
  local file="$1" old new="" seen=":" inserted=0 entry
  old=$(cat "$file")
  local IFS=':'
  # shellcheck disable=SC2086
  set -- $old
  for entry in "$@"; do
    [ -n "$entry" ] || continue
    if [[ "$entry" =~ $MULTISHELL_RE ]]; then
      # The dead entry sat where node was meant to come from — put the real one there.
      if [ "$inserted" = 0 ] && [[ "$seen" != *":$NODE_BIN_DIR:"* ]]; then
        new+="${new:+:}$NODE_BIN_DIR"; seen+="$NODE_BIN_DIR:"; inserted=1
      fi
      continue
    fi
    [[ "$seen" == *":$entry:"* ]] && continue
    if [ "$inserted" = 0 ] && [[ "$seen" != *":$NODE_BIN_DIR:"* ]] && [[ "$entry" =~ $SYSTEM_DIR_RE ]]; then
      new+="${new:+:}$NODE_BIN_DIR"; seen+="$NODE_BIN_DIR:"; inserted=1
    fi
    [ "$entry" = "$NODE_BIN_DIR" ] && inserted=1
    new+="${new:+:}$entry"; seen+="$entry:"
  done
  if [[ "$seen" != *":$NODE_BIN_DIR:"* ]]; then
    new+="${new:+:}$NODE_BIN_DIR"
  fi
  unset IFS
  local resolved
  resolved=$(PATH="$new" command -v node || true)
  if [ "$resolved" != "$NODE_BIN_DIR/node" ]; then
    echo "  refusing to write: node would resolve to '${resolved:-nothing}', not $NODE_BIN_DIR/node" >&2
    return 1
  fi
  if [ "$new" = "$old" ]; then
    echo "  unchanged"
    return 0
  fi
  printf '%s\n' "$new" > "$file.tmp"
  mv -f "$file.tmp" "$file"
  echo "  rewritten"
}

check() {
  local dir name file_path node ver live state defects=0 pending=0 first_node="" disagree=0
  printf '%-20s %-14s %-10s %-16s %s\n' RUNNER NODE VERSION LIVE FILE
  for dir in $(runner_dirs); do
    name=$(basename "$dir")
    file_path=$(cat "$dir/.path")
    node=$(PATH="$file_path" command -v node || echo none)
    ver=$( [ "$node" != none ] && "$node" --version 2>/dev/null || echo -)
    live=$(live_path "$dir")
    if [ -z "$live" ]; then state="not-running"
    elif [ "$live" = "$file_path" ]; then state="applied"
    else state="RESTART-NEEDED"; pending=$((pending + 1)); fi
    local label=ok
    if grep -Eq "(^|:)/run/user/[0-9]+/fnm_multishells/" <<<"$file_path"; then
      label="MULTISHELL"; defects=$((defects + 1))
    elif [ "$node" != "$NODE_BIN_DIR/node" ]; then
      label="WRONG-NODE"; defects=$((defects + 1))
    fi
    [ -z "$first_node" ] && first_node="$node"
    [ "$node" != "$first_node" ] && disagree=1
    printf '%-20s %-14s %-10s %-16s %s\n' "$name" "$label" "$ver" "$state" "$node"
  done
  echo
  if [ "$defects" = 0 ] && [ "$disagree" = 0 ]; then
    echo "every .path resolves node to $NODE_BIN_DIR/node"
  else
    echo "$defects runner(s) resolve node from somewhere other than $NODE_BIN_DIR — run: $0 --fix"
  fi
  if [ "$pending" != 0 ]; then
    echo "$pending runner(s) are running an older .path — run: $0 --restart"
  fi
  [ "$defects" = 0 ] && [ "$disagree" = 0 ] && [ "$pending" = 0 ]
}

case "$mode" in
  fix )
    for dir in $(runner_dirs); do
      echo "$(basename "$dir"):"
      rewrite "$dir/.path"
    done
    echo
    check
    ;;
  restart )
    rc=0
    for dir in $(runner_dirs); do
      name=$(basename "$dir")
      live=$(live_path "$dir")
      if [ -z "$live" ] || [ "$live" = "$(cat "$dir/.path")" ]; then continue; fi
      if [ ! -f "$dir/.service" ]; then
        echo "$name: no .service file (not installed via svc.sh?) — restart it yourself"; rc=1; continue
      fi
      unit=$(cat "$dir/.service")
      if busy "$dir"; then
        echo "$name: job in flight, skipped — re-run --restart when it is idle"; rc=1; continue
      fi
      echo "$name: restarting $unit"
      sudo systemctl restart "$unit"
    done
    echo
    check || exit 1
    exit "$rc"
    ;;
  check )
    check
    ;;
esac
