# Estate-wide skills

Claude Code skills that apply to every session on this box, whatever the repo.
Each one is symlinked into `~/.claude/skills/<name>`:

    ln -s ~/construct-server/agent/skills/switchyard-plan ~/.claude/skills/switchyard-plan

A skill here is inert until that symlink exists. `~/.claude/skills/synced/` is
managed separately and is not part of this directory.

## Skills here

- `switchyard-plan`: writing, submitting and revising a plan for a Switchyard ticket.
- `frontend-audit`: quarterly Firefox-first quality audit of the estate's frontends.
  Reads extra targets from the local, untracked `~/.config/frontend-audit/targets`
  (format in its `references/targets-format.md`). Link it the same way:
  `ln -s ~/construct-server/agent/skills/frontend-audit ~/.claude/skills/frontend-audit`
