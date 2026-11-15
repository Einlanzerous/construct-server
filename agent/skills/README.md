# Estate-wide skills

Claude Code skills that apply to every session on this box, whatever the repo.
Each one is symlinked into `~/.claude/skills/<name>`:

    ln -s ~/construct-server/agent/skills/switchyard-plan ~/.claude/skills/switchyard-plan

A skill here is inert until that symlink exists. `~/.claude/skills/synced/` is
managed separately and is not part of this directory.
