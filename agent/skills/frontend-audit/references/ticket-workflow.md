# Filing and driving tickets

## Filing: one ticket per project

For each project with at least one `high` fix, create one ticket in that
project (`create_ticket`) titled for the sweep, for example
`Frontend quality pass: <n> high-priority fixes (<month year>)`. The body
lists each high fix with title, file:line, Firefox support and effort, and
links the scorecard. Targets from the local targets file with no project get
no ticket; report their fixes to the operator instead.

- Check the project's `default_review_mode` and the ticket's `review_mode`.
  `evidence` may be finished alone. `decision` needs a plan first; `full` is
  for a human. Unset is not `evidence`: ask. You may raise a mode, never lower.
- Keep off the board anything a project's description says stays off it:
  health values (Plimsoll), personal figures (Sextant), private surfaces and
  their names. Write fixes in generic terms; leave the figure or surface out.
- If a project's repo is shown to other people, write as if they will read it.
- Med and low fixes stay on the scorecard; do not file them.

## Driving (optional)

Where the operator asks for the fixes to be done, hand each `evidence` ticket
to a worker subagent using `references/worker-brief.md`, one ticket each,
matched to the work's tier. Do not start `decision` or `full` tickets.
