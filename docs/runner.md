# Self-hosted runner

Rationale moved out of the root `CLAUDE.md` (SERV-317): the runner's PATH, its shared
`$HOME`, and the one deploy root.

**The runner is a systemd service with a bare system PATH.** It never sources
a login shell, so anything installed under `$HOME` — ansible, bun, node, fnm
shims — is invisible to it. Add it via `$GITHUB_PATH` in a step and check for
it explicitly so failures read as "not on PATH" rather than `command not
found` from three layers down. SERV-62 hit this twice (#85).
**The one deliberate exception is `node`, and it is pinned by
`scripts/runner-node-path.sh`** (SERV-135). Each runner's `.path` is whatever PATH
the shell that ran `config.sh` had, and an fnm shell's PATH names a per-shell
`/run/user/…/fnm_multishells/` directory — tmpfs, gone on reboot, after which node
silently falls through to the system v18 (EOL April 2025). Nine of thirteen runners
carried one; five had already flipped. Every `.path` under `~/runners/` now names
fnm's `default` alias instead, so they all resolve the same node and the answer was
chosen rather than inherited. **Runners are registered by hand, and ansible has no
role for them** (SERV-181). The `github_runner` role that used to exist passed
`--replace` with no `--name`, so a completed `site.yml` run would have re-registered
the live `imperial-construct` runner from a second directory, `~/actions-runner`, on
the tarball's 2.321.0 and a bare system PATH. It never got that far — its
registration token had expired — and the role and the directory are both gone.
`runsvc.sh` reads `.path` **once, at unit start**, so a
rewrite changes nothing until the runner restarts; the script reports the live
listener's PATH beside the file for that reason. **Never copy another runner's
`.path`** when adding one — run the script, which is what `~/runners/POOL-README.md`
now says.
**Every runner shares one `$HOME`, so a job must never write a fixed path under
it** (SERV-114). All fourteen runners run as `magos`, which makes `~` and `/tmp`
one namespace across every repo's CI. `claude-code-action` installed Claude Code
on every run into `$HOME/.claude/downloads/claude-<version>-linux-x64` and the
install script `rm -f`s that path on any failure — so two reviews in flight in
different repos deleted each other's binary and both went red, on the day the
estate was busiest, and each install's `claude install` repointed
`~/.local/bin/claude` so CI was also deciding the interactive version. The
reviewer and the verifier now pass `path_to_claude_code_executable` and the
action installs nothing; a `Locate Claude Code` step asserts the host's
`~/.local/bin/claude` runs and fails **naming it**, because left to the action
the death lands inside the Review step as `malfunction (turns: 0)`. Two costs,
both deliberate: **CI runs whatever `claude` the box has**, so `claude update`
on the host is a CI version change (the step prints a notice when it differs
from the action's pin), and a host with no install cannot review. The `/tmp` half
of the same namespace is SERV-137/143, closed by moving reviewer scratch to
`$RUNNER_TEMP`. Do not fix the next collision by serialising reviews —
`concurrency` is per-repo, and SERV-92 made the repos reviewable, which is the
same thing as concurrent. And do not reach for per-runner `HOME` without reading
SERV-190: SERV-127's sidecar and Switchyard's usage sweep both read
`~/.claude/projects` under the shared home, so splitting it moves every CI
transcript out of the ledger without anything going red.
**The stack deploys from `/opt/construct-server`, and no other path** (SERV-76).
Neither checkout on this box is what runs: `~/construct-server` is a plain git
working copy, and the runner's `_work/…` directory is CI scratch that
`actions/checkout` resets on every run — `pr-review.yml` fires on
`pull_request`, so it regularly holds an *unmerged* PR merge ref. Both used to
be bound compose projects at once, which is why "what is live" was a question
you had to answer by inspection. `deploy.yml` now rsyncs the stack files to the
deploy root and runs compose there; ansible bootstraps the same path. Editing
`docker-compose.yml` in a checkout changes nothing until it is merged and
deployed — `make recreate svc=<svc>` deliberately targets the deploy root from
wherever you invoke it. **Adoption is gradual, so `docker compose ls` reporting
more than one config file is expected for now, not a failed deploy**: a
container keeps the root it was created from until it is next recreated, and
nothing force-recreates the stack to hurry that along. Use
`./scripts/check-compose-drift.sh`, which flags every container created from a
foreign root, to see what is left; the list should only ever shrink. A *new*
root appearing in that list is the real regression.
