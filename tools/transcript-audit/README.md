# transcript-audit

Re-runs the **SERV-320** measures of Claude Code usage and workflow compliance
from the session transcripts under `~/.claude/projects`, so the same numbers can
be taken again and compared with the baseline below. Stdlib-only Go; one binary,
two subcommands.

```
cd tools/transcript-audit && go build -o transcript-audit .
transcript-audit usage      --since 2026-11-15 --until 2026-12-14
transcript-audit compliance --since 2026-11-15 --until 2026-12-14
```

Flags: `--since` / `--until` (UTC dates, both inclusive, required), `--root`
(default `~/.claude/projects`), `--json`, and for `usage` `--top N` directories in
the text table (default 15, `0` for all). Compare like with like: the baseline
window is 31 days, so use a 31-day window.

Never prints a prompt, a tool input or a tool output (transcripts contain
credentials): only counts, shares, model families, tool names and project
directory names. A test plants a canary in every kind of content and fails if it
reaches either output format.

## What it measures

`usage`
- sessions, turns and tokens by **kind**: `interactive`, `runner` (directory under
  `~/runners`) or `dispatch` (`dispatch` in the directory name, or a drydock
  worktree). The kind comes from the directory name only.
- total tokens (input + output + cache read + cache write), and the **subagent
  share** (sidechain messages and `subagents/` files).
- per model family (opus, fable, sonnet, haiku), tokens on the main thread and in
  subagents, and each family's subagent tokens as a **share of all tokens**. The
  SERV-320 "Opus/top-tier share" is `opus` in that column.
- `Agent`/`Task` spawns that **named a model** versus **named none** (inherit).
- tokens by **starting directory**.

`compliance`
- of sessions that ran `gh pr create`, the share that also called
  `attach_external_ref`, by kind. The headline is `interactive`.
- operator prompts containing `file a ticket` and `I don't see`.
- Switchyard plan-tool calls (`open_plan_draft`, `submit_plan`, `revise_plan`,
  `get_plan`, `get_plan_feedback`) and the `get_plan` error rate.
- permission denials, by deciding source / reason type / classifier category.

## Definitions worth knowing

- A message is counted once per (session, message id): a streamed message is
  written several times and the copy with the most output tokens wins. A forked
  subagent's file replays its parent's history, so the same message can appear in
  a main and a `subagents/` file; the main-thread copy is the one counted.
  `<synthetic>` messages are ignored.
- A tool call, and the result of a `get_plan` call, is counted once per
  (session, tool_use id), for the same reason.
- "Operator prompt": a typed main-thread user turn. Excluded: tool results,
  subagent briefs, meta entries, compaction summaries (which quote earlier prompts
  and double-count them) and entries whose `origin.kind` is not `human` (task
  notifications). Deduplicated by (session, uuid), since a resumed session copies
  earlier turns. Matching is a case-insensitive substring; curly apostrophes are
  folded to straight.
- `get_plan` error rate counts results with `is_error` set. Results whose text
  starts with `Error` but have no `is_error` are reported separately: in the
  baseline window these were all the client refusing an oversize result, not the
  server failing.
- Switchyard tools are matched under both MCP prefixes (`mcp__switchyard__` and
  `mcp__claude_ai_Switchyard__`).
- Permission denials are user entries whose `permissionDecision.decision` is
  `reject`. The transcript records *what decided* (config / hook, classifier or
  safety check, and a classifier category when there is one), not the text of a
  permission rule, so "by rule" here means by that triple. More than half of classifier
  denials carry no category (`config/classifier/-`).

## Baseline: 2026-10-15 to 2026-11-14

Run on 2026-11-15 (UTC) over the live transcripts. It matches the original
Python inspection scripts on sessions, turns, per-model tokens and the PR,
prompt and denial counts. It differs in one deliberate way: forked subagents
replay their parent's history in their own file, and the Python counted those
replays again (39 spawns, 23 API messages, one `get_plan` call). Here each is
counted once.

| Measure | Baseline |
|---|---|
| Sessions | 582: interactive 135, runner 425, dispatch 22 |
| Total tokens | 5,914,658,960 |
| Subagent share of tokens | 61.1% (3,611,436,869) |
| Subagent tokens as share of all tokens, opus | 27.2% |
| ... sonnet | 30.0% |
| ... fable | 3.9% |
| ... haiku | 0.03% |
| Subagent spawns | 574: named a model 233 (40.6%), named none 341 |
| Tokens by directory (top 3) | `-home-magos-projects` 24.7%, `-home-magos-projects-genzo` 24.5%, `-home-magos-projects-catenary` 8.4% |
| Interactive sessions that ran `gh pr create` | 40, of which 22 called `attach_external_ref` (55.0%) |
| Operator prompts "file a ticket" / "I don't see" | 26 / 10 |
| Plan tools: open / submit / revise / get / feedback | 61 / 75 / 121 / 414 / 209 |
| `get_plan` errors (`is_error`) | 98 of 414 (23.7%); 193 more results start `Error` without `is_error` |
| Permission denials | 142 |

The 26 / 10 prompt figures agree with `~/.claude/history.jsonl` for the same
window. An earlier hand count of 39 for "file a ticket" included compaction
summaries that quote prompts.

## Known limits

- **Retention.** Claude Code prunes old transcripts. Check the baseline window
  still returns the same session count before reading a later run as a trend; the
  figures in this file are the record.
- Lines are prefiltered on the literal text `"type":"assistant"` /
  `"type":"user"` (the compact form Claude Code writes). Other event kinds are
  not parsed. A line that is not valid JSON is counted in `malformed lines` and
  skipped; a malformed line that does not start with `{` is counted too, but one
  that lacks both literals is invisible.
- Dates are the UTC date of each event's timestamp. A session is counted if any
  of its events falls inside the window, so a session that straddles the start
  counts in full for sessions but only its in-window turns for tokens.
- The kind classifier hardcodes the `-home-magos-` prefix of this box.
- `gh pr create` is matched in Bash commands whether or not it succeeded.
- Tokens are those the API reported; cache reads are included, so totals are
  dominated by them and are not a bill.
