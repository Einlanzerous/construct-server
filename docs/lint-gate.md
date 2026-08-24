# The pre-push lint gate

A Claude Code hook that runs a repository's own format and lint checks before any
`git push`, and blocks the push if they fail (SERV-58).

## Why

Agent-authored PRs were landing with formatting errors. The cost of each one is a full
CI round trip — a red run, a fix commit, a re-run, and a human noticing in between. It
was reported roughly twenty times across ARGY / LYCM / ITLK / SGNT in the June–July
window, always in the same words:

> CI is broken on the PR you just pushed up (looks like formatting errors throughout,
> good idea to always run linters before pushing).

Every one of those was knowable locally in well under a second. `gofmt -l` and
`prettier --check` need no network, no build, no database. The round trip was pure waste.

## Shape

One script, `scripts/lint-gate.sh`, registered once in `~/.claude/settings.json` as a
`PreToolUse` hook on `Bash`. It reads the hook payload on stdin; when the command about
to run is a `git push`, it discovers what the repository is written in, runs that
language's *check* commands, and answers `deny` with the failing output. The agent reads
the denial and fixes the code without ever having pushed.

Install it with `make lint-gate-install`. That is the whole per-repo setup: there is
none. User-level installation was the ticket's requirement and is the reason this is
worth doing at all — a mechanism that needs eleven repos to opt in gets nine of them.

**A session that was already running when you installed it will not have the gate.**
Claude Code picks up settings changes on its own, but a session started before the hook
existed may need `/hooks` opened once, or a restart. This is worth knowing because the
symptom is indistinguishable from the gate being broken: your push simply succeeds.
`make lint-gate-status` answers whether it is *installed*; only a new session answers
whether it is *live*.

| Command | What it does |
|---|---|
| `make lint-gate` | Run the checks against this repo, as the hook would |
| `make lint-gate dir=~/projects/argosy` | …against another repo |
| `make lint-gate explain=1` | List the units found and what would run, run nothing |
| `make lint-gate-install` | Install or update the user-level hook |
| `make lint-gate-status` | Is it installed, and does the copy match this checkout? |
| `make lint-gate-test` | Prove it still blocks (see *Verifying* below) |
| `make lint-gate-uninstall` | Remove it |

## Language-agnostic dispatch

A repo is not one language. argosy is Go + Vue + Flutter; lyceum is Go + TS + Flutter.
So the gate finds every **unit** in the tree and checks each, rather than matching the
repo to a single toolchain and stopping at the first hit.

| Marker | Runs | Notes |
|---|---|---|
| `go.mod` | `gofmt -l` over git-tracked `*.go`, `go vet ./...` | |
| `package.json` with a `lint` or `format:check` script | `<pm> run format:check`, `<pm> run lint` | Package manager from the lockfile; walks up for workspace members |
| `pubspec.yaml` | `dart format --output=none --set-exit-if-changed` | |
| `Cargo.toml` | `cargo fmt --check` | |

What it finds today, from `make lint-gate explain=1`:

```
argosy    go .            node web        dart mobile/argosy
lyceum    go .            go wrappers/wails   node web   dart mobile/lyceum
interlock node .
signet    go .
purser    go .
construct-server  go pkg/cfaccess   go services/cf-access-guard   go tools/software-page
switchyard  (nothing)
cta-watch   (nothing)
```

The empty rows are honest, not a bug. **switchyard and cta-watch define no `lint` or
`format:check` script at all** — switchyard's CI runs `typecheck`, which this gate
deliberately does not (see below). "No-op cleanly when a repo has none" is the common
case in this estate, not the edge case. If you want those repos gated, the fix is to add
a `lint` script there, and the gate picks it up with no change here.

Two discovery rules earn their keep:

- **Nested worktrees are pruned.** Claude Code puts them under `.claude/worktrees/`, and
  lyceum has one. Without the prune the gate discovers a second copy of the repo and
  reports findings against a branch nobody is pushing.
- **Nearest ancestor wins** for Node units. interlock's root `eslint .` already covers
  its workspace members; running both would double every finding.

## What it deliberately does not run

The gate is only worth having if it is cheap enough to leave on, and only credible if it
never blocks on something CI would accept.

- **`golangci-lint`.** argosy's CI pins v2.12.2 and installs it per run; this box has an
  unpinned copy on `PATH`. Different versions disagree. Version skew in a *blocking*
  gate is how you teach people to bypass it.
- **Typecheck, build, test.** Slow — `vue-tsc` alone is tens of seconds — and they need
  installed dependencies and sometimes a database. This targets the failure that was
  actually reported.
- **Anything that writes.** `prettier --write`, `gofmt -w`, and `dart format` without
  `--output=none` all rewrite the tree. A gate that silently edits your files *during a
  push*, after you have reviewed the diff, is a worse bug than the one it fixes. Every
  command above is a check. The gate reports; you fix.

### What it does execute, which is worth being explicit about

Selecting a repo's `lint` / `format:check` script means **running a command the repository
controls**, from a hook, for every repo on the box — outside the tool-permission path the
same command would go through if an agent ran it directly. Inside the estate that is
fine and is the point: argosy, lyceum and interlock all define read-only `eslint` /
`prettier --check`, and the *writing* `format` script is deliberately not selected. But
the property is "this machine only holds repos you trust", not something the gate
enforces. A hostile `package.json` dropped into any directory you `git push` from would
execute. If that stops being true of this box, narrow the dispatch to fixed binaries
(`eslint`, `prettier`) rather than named scripts, or drop back to the language checks
that take no repo input at all — `gofmt`, `cargo fmt`, `dart format`.

## It fails open, and that is the opposite of `deploy-scope.sh`

`scripts/deploy-scope.sh` fails **closed**: when it cannot answer, the deploy does the
widest safe thing. This one fails **open** — every internal error, missing tool,
unreadable payload, or timeout allows the push. The asymmetry is deliberate:

- CI is still the backstop. A false allow costs exactly what today already costs: one red
  run. Nothing regresses.
- A false *block* is unbounded. This sits in front of every `git push` in every repo on
  the machine, **including the self-hosted runner's `$HOME`**, which is shared. A bug
  that blocks wrongly cannot be worked around by the thing it is blocking, and the reflex
  it trains is `CONSTRUCT_LINT_GATE=0`, permanently — which costs the whole feature.

So it only ever blocks on a check that **ran to completion and reported a real finding**.
Anything it could not run is reported as a skip and does not block. Concretely:

- `node_modules` missing → skip. Blocking here would fail every fresh checkout.
- `go vet` failing to *build* (argosy's CI runs `make ensure-embed` first) → skip. A vet
  finding is a line matching `file.go:12:3:`; a build error is not, and the gate tells
  them apart rather than blocking on both.
- `dart` or `cargo` not on `PATH` → skip. Neither is installed on this box today, so the
  Flutter units are discovered and skipped, visibly.
- The **package manager** not on `PATH` → skip. The lockfile says what the repo *wants*,
  not what the machine has, so a `pnpm-lock.yaml` on a box without pnpm would otherwise
  exit 127 and block on "command not found". This is not hypothetical on the runner:
  CLAUDE.md's own invariant is that it runs as a systemd service with a bare system
  `PATH` and cannot see anything under `$HOME` — **`bun` included**. Every Node check
  skips there, which is correct; the runner is not where pushes are authored.
- **`gofmt` or `go` not on `PATH` → skip**, and this one bit for real. `gofmt` was
  unguarded while `go` was guarded for vet, so with `gofmt` absent `xargs` wrote
  `xargs: gofmt: No such file or directory` to stderr and the gate reported it as a
  *parse failure* — denying every push from every repo with a `go.mod`, against a
  correctly formatted tree, with nothing the agent could fix. It is not an exotic state:
  `go` and `gofmt` live in `~/go/bin` here, which only `~/.zshrc` adds to `PATH`, so
  every non-login shell is in it — the runner included, and the PR reviewer that caught
  this. Both are guarded now, a 127 or 124 out of the `gofmt` pipeline is a skip rather
  than a finding, and `make lint-gate-test` asserts it with `PATH` stripped.

## Exemptions

SERV-58 requires the gate never fire on release-please branches or tag pushes. It also
exempts three cases that carry no content:

| Push | Why exempt |
|---|---|
| `git push --tags`, `git push origin v1.0.0` | The content was linted on its way to `main`; the tag adds none |
| `git push origin release-please--branches--main` | Generated CHANGELOG and version commits |
| `git push origin --delete <ref>` | Removes a remote ref, pushes no content |
| `git push --dry-run` | Changes nothing by definition |
| `git push --no-verify` | The user said to skip verification, and git honours that |

`--follow-tags` is **not** exempt: it pushes the branch as well as its tags, so the
branch still wants checking.

Whether something is a tag is settled by asking git (`rev-parse refs/tags/…`), not by
pattern-matching version strings.

## Two implementation details that are easy to get wrong

**The matcher is a bare `Bash`, not `if: "Bash(git push:*)"`.** The `if` filter would be
cheaper — it avoids spawning the hook at all — but it is a *prefix* match against the
command string, and the form an agent actually uses is
`git add -A && git commit -m x && git push`. That would not match, and the gate would
silently never fire: the same silent-pass class as the `concurrency` incidents in
`pr-review-reusable.yml`. So the gate matches every `Bash` call and bails in-script.
Measured cost of the bail: **8ms**.

The corollary is that `git push` must be recognised in **command position** only. Early
on it matched anywhere in the string, which meant
`git commit -m 'remember to git push'` blocked a *commit*. A gate people cannot predict
is a gate they switch off.

Command position is decided by splitting on `&&`, `||`, `;` and newline **outside quotes
and outside heredoc bodies**. Three cases have to hold at once, and each of the first two
was a real bug caught in review:

| Command | Must | Why it is not obvious |
|---|---|---|
| `git commit -m "wip; git push later"` | allow | A blind split treats that `;` as real and blocks the **commit** |
| `cat > deploy.md <<EOF … git push … EOF` | allow | A heredoc body is **not shell-quoted**, so quote tracking alone does not save it |
| `git add -A`⏎`git commit -m x`⏎`git push` | deny | So newline must stay a separator |
| `git commit -m "…⏎git push origin main⏎"` | allow | …but only **outside quotes** — a newline inside a quoted string is text |

The heredoc case is the worse of the two failures, and not only because it is easy to hit
— writing this very document from a heredoc trips it. The command being blocked is a file
**write**, and the advertised escape hatch does not apply: `--no-verify` is a `git push`
flag and there is nowhere to put it on a `cat`. The only way through would be
`CONSTRUCT_LINT_GATE=0`, which is the reflex the whole fail-open design exists to avoid.

The cheap fix — drop `\n` as a separator — is the wrong trade, and the third row is why:
it converts a false block into a **silent miss**, and a gate that quietly stops firing is
the failure mode this design is arranged against.

**Heredoc detection happens inside the character pass, not as a regex over the raw
line.** It was a pre-pass once, and sitting outside the quote state it was bolted onto it
broke three ways at once, in both directions:

| Command | Was | Why |
|---|---|---|
| `cat > f <<\EOF … git push … EOF` | **false block** | `\` is bash's fourth way of quoting a terminator, equivalent to `<<'EOF'` — the regex matched neither a quote nor a word char |
| `cat > f <<'EOF-1' …` | **false block** | a terminator is not always a bare identifier |
| `grep -q foo <<< bar` ⏎ `git push` | **silent miss** | `<<<` is a here-string and opens no heredoc |
| `git commit -m "explain << redirects"` ⏎ `git push` | **silent miss** | the regex ran before any quote tracking |

The last two are the ones worth dwelling on: a terminator recorded from something that
never arrives swallows *every following line*, so a real `git push` after it is never
seen. Nothing is reported, so **the test suite structurally cannot notice** — it can only
assert on answers the gate gives.

So `<<` is recognised only outside quotes, `<<<` is skipped, and `\WORD` is accepted
alongside `WORD`, `'WORD'` and `"WORD"`.

Backslash escaping is deliberately not modelled **in the separator scan** — there it does
not change what a `git push` segment looks like, and a mis-split errs toward linting when
it need not have, which is the safe direction. That argument does **not** extend to the
heredoc path, which is exactly the mistake above: there a missed backslash errs toward a
false block on a write, the worst case this document names.

All six forms are in the test suite, which until this round contained **no multi-line
command at all** — which is precisely why the heredoc case survived the first fix.

### Latency

The bare `Bash` matcher means this runs on every Bash tool call, so the cost of *not*
being a push is the number that matters. It is **~9ms and flat in command length**: a
plain substring test for `git push` runs before anything else, so an 8000-character
non-push measures the same as `ls`. Only a command that does contain `git push` pays for
the segment scan, at ~14ms on that same input.

That scan is one `awk` pass. It was briefly a bash character loop, which is quadratic —
**618ms** on an 8000-character command, and long commands are exactly the heredocs above.
The suite has a loose upper bound on it to catch a reintroduction.

**The installer copies the script; it does not point at the checkout.** Registering
`~/construct-server/scripts/lint-gate.sh` would keep the gate current on every `git
pull`, but `~/construct-server` is a plain working copy that is routinely on a feature
branch and is shared between sessions — a concurrent `git checkout` would change the gate
in front of your push, which is a strange thing to debug at the moment it happens. Same
reasoning as SERV-76's "the stack deploys from `/opt/construct-server`, and no other
path".

The cost of copying is drift, so the copy is stamped with the source's content hash and
`make lint-gate-status` reports when they differ — the same shape as
`check-compose-drift.sh`. **Re-run `make lint-gate-install` after pulling a change to
`lint-gate.sh`.**

## Verifying

`make lint-gate-test` builds fixture repos in a temp directory — one knowingly
misformatted, one clean, one with no checks configured, one a workspace — and asserts the
gate's answer for each. It never touches the estate's repos. It covers every exemption
above, both directions of workspace discovery, the multi-line and heredoc forms, the
fail-open paths (`gofmt` off `PATH`, a check that outruns its timeout), and a loose upper
bound on scan latency.

This exists because the gate **fails open**: a gate that has quietly stopped working
looks exactly like a clean tree. Both are green. The test is the difference between the
two.

**Run it in the environment you doubt, not just a working one.** Every finding in this
document's history was caught that way, and one of them the suite already covered and
would have caught the whole time: the unguarded `gofmt` reports 22 passed / 1 failed the
moment you run it with `~/go/bin` off `PATH`, and it had simply never been run like that.
`PATH=/usr/bin:/bin make lint-gate-test` is a cheap habit.

## Turning it off

- Once: `git push --no-verify`.
- For a session or a machine: `CONSTRUCT_LINT_GATE=0`.
- For one repo: override the hook in that repo's `.claude/settings.json` — project
  settings layer over user settings.
- Permanently: `make lint-gate-uninstall`.
