# Reviewer subagent prompt

Launch one subagent per ~3 frontends, in parallel, read-only. Fill the
placeholders and send:

> You are auditing frontends read-only. Do not edit, install, build or run
> anything in the checkouts; your only write is one JSON file per frontend.
>
> Frontends: `<KEY | NAME | path to web dir>` for each.
> Rubric: read `~/construct-server/agent/skills/frontend-audit/references/rubric.md`
> and follow it exactly, including the Firefox-primary rule.
> Output schema: `references/result-schema.md` in the same directory; write
> `<scratchpad>/results/<key>.json` for each.
> Legacy scan: `<legacy-scan JSON for this frontend, or "denied: grep for the
> rubric's legacy patterns by hand">`.
>
> Read the repo's CLAUDE.md/AGENTS.md, build config (vite/browserslist) and
> the web source. Grep for the rubric's patterns, then read the hot files.
> Cite file:line for every strength, risk and fix. Verify a line before
> citing it. State Firefox support for every fix; say "unsure" when unsure.
> Never read data (health, personal, messages, photos) and never put such
> values, or any private surface's name, in your output. Report only the
> paths of the files you wrote.
