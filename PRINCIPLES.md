# Platform Principles

The single source of truth for what counts as "good" across the Construct estate.
Unlike `CLAUDE.md` and `REVIEW.md`, which are per-repo, this file is **cross-repo**:
it holds the defaults every project inherits.

If you are an agent reading this, treat it as binding. If a request appears to
conflict with these principles, surface the conflict explicitly rather than
silently complying.

> Salvaged from `imperium-loop/PRINCIPLES.md` (v1, 2026-05-21) when that pipeline
> was decommissioned (SERV-83). The pipeline is gone; the standards are not.

---

## 1. Languages

**Default to Go or TypeScript.** Both for new projects and for additions to
existing ones — use whatever the surrounding repo already uses. Pick the right one
for the job; they have different sweet spots:

- **Standalone backend services, CLIs, systems-y work, anything where a single
  static binary matters:** Go. Default here unless there's a reason to deviate.
- **Full-stack web apps (frontend + backend in one product):** TypeScript on
  **both** sides is the natural pick. One language, one toolchain, types shared
  across the boundary, no impedance at the API layer. This is the case where a
  TS backend is the *better* choice, not merely an acceptable one.
- **Frontend (any):** TypeScript.
- **Scripts / one-offs / glue:** TypeScript (Bun is fine) or Go. Shell only for
  tiny operational scripts (≤ ~20 lines).

**Rust is accepted for new standalone tools.** The Go/Rust boundary is not settled;
absent a specific reason to prefer Rust, Go remains the default for new services,
and an existing repo's language always wins.

**Do not propose Python for new project code.** Especially for full-stack work —
LLMs tend to reach for Python + FastAPI/Flask plus a separate JS frontend by
default, which is exactly the wrong choice here: two languages, two toolchains,
hand-written API types on both sides. Even for ML-shaped tasks, prefer a Go/TS
service that calls into a local model (Ollama) over a Python microservice. Notebook
one-offs for analysis are fine but never ship.

**Why:** the platform owner maintains the whole stack; consistency across two or
three ecosystems is dramatically cheaper than five, *and* the full-stack-Python
default is a common-but-wrong instinct worth pushing back on explicitly.

## 2. Stack defaults

| Layer | Default | Notes |
|---|---|---|
| Frontend | **Vue 3** + Vite | Prefer over React. Composition API. |
| Backend (standalone) | Go (stdlib HTTP first; chi if routing) | Don't reach for a framework on day one. |
| Backend (full-stack web) | TypeScript (Bun preferred, Node fine) | Share types with the Vue frontend across the API boundary. |
| Database | PostgreSQL | Single shared instance on `construct_net`, one database per service. |
| LLM (local) | Ollama + `gemma4:31b` | Local-first. See §6. |
| LLM (cloud) | Claude 5 family (Opus 5 / Sonnet 5) | Escalation, not default. |
| Auth | Per-actor bearer tokens | Switchyard-style: one token per service. |
| Secrets | Signet | Vault is the source of truth; `.env` files are rendered, not authored. |
| Containers | Docker Compose, `construct-server` | All services on `construct_net`. |
| CI | GitHub Actions, self-hosted runners under `~/runners/<repo>/` | |

When deviating, say so out loud and explain why — usually the deviation is the
right call, but it should be visible.

## 3. Release discipline

**All repos follow Conventional Commits + release-please.** New repos go on this
flow on day one — it is not optional. Release-please owns `CHANGELOG.md` and
version bumps; don't hand-edit either.

Keep the type vocabulary small. In practice there are four:

| Type | Releases? | Use for |
|---|---|---|
| `feat!:` | yes (major) | Breaking changes; major re-architecture; UI refreshes |
| `feat:` | yes (minor) | New features. **Most tickets land here.** |
| `fix:` | yes (patch) | Bugfixes, small tweaks, and **sub-feature work** — small UI changes, polish, follow-up adjustments inside an already-shipped feature |
| `chore:` | **NO** | Docs only, or genuinely minor CI/tooling tweaks |

**The non-obvious rule: `fix:` covers sub-feature work**, not just bugs. A small UI
tweak inside an existing feature is a `fix:`, not a `feat:`. "Feat" is reserved for
net-new functionality the user couldn't do before; "fix" handles everything from
real bugs to polish on already-shipped code.

**Critical: `chore:` skips the release cut.** Mistype a shipping change as `chore:`
and the deploy quietly does not happen — the bug only surfaces when someone notices
"the new feature isn't in prod."

**Default to `feat:` or `fix:`.** `chore:` is deliberate, not a catch-all. When
unsure, ask: *does this give the user something they couldn't do before?* Yes →
`feat:`. No → `fix:`.

PR titles must match the type of the merge commit (squash-merge is the default).
Put the ticket key in the subject. Branches are `{type}/{slug}-{key}`.

## 4. Ticket and agent operations

**Switchyard is the system of record for work.** Every non-trivial task gets a
ticket.

**Prefer the Switchyard MCP server over raw HTTP** when an agent needs to interact
with Switchyard. The MCP is whitelistable per tool, which is how the platform owner
controls agent permissions. Fall back to `curl` only when the MCP doesn't yet expose
what you need — and **call that out explicitly** so the gap can be filed against the
MCP itself.

Per-actor token discipline:

- Every agent and service authenticates as its own Switchyard user.
- **Never share a token across components.** The audit log relies on
  one-process-one-bearer-one-actor.
- This applies to third-party credentials too. A single GitHub PAT serving several
  consumers has broken this estate three times by scope (SERV-3, SERV-4, LOOP-28):
  a token scoped for one job silently fails another, and on GitHub a scope failure
  reads as `404`, not `403`. **Mint per-consumer, scope minimally, record in Signet.**

Status changes go *only* through `transition_ticket`. `update_ticket` (PATCH) cannot
change status — invariant, baked into both the REST API and the MCP tool
descriptions.

`project_key` is immutable. Mis-routed tickets get deleted and recreated.

## 5. Status hygiene

Keep the status accurate while working a ticket. "In Progress is In Progress"
applies equally to human and agent work; there is no separate human track.

**Use canonical status names.** Switchyard's base enum across all projects:

| Status | Category | Use when |
|---|---|---|
| `Backlog` | `backlog` | Filed, not yet picked up |
| `Planning` | `planning` | Plan being authored / awaiting plan review |
| `In Progress` | `in_progress` | Active coding (human or agent) |
| `Blocked` | `blocked` | Waiting on something external; cannot proceed |
| `Closed` | `closed` | Done — with `resolution: done` or `cancelled` |

A project *may* add statuses for project-specific needs, but **don't invent statuses
that just rename a canonical one** ("Building" for "In Progress", "PR Open" for
"In Progress", "Shipped" for "Closed"). The base five are sufficient; renames
fragment the surface without adding signal.

**PR state is tracked separately, not as a status.** Title the PR per §3 —
a conventional-commit subject carrying the ticket key, e.g.
`fix(signet): render the sudoers rule via template (SERV-62)` — and name the branch
`{type}/{slug}-{key}`. Do **not** prefix the title with the bare key
(`SERV-62: …`): squash-merge makes the PR title the commit subject, so a
non-conventional title means release-please skips the release and the deploy
silently does not happen. Auto-attach reads the key from anywhere in the title or
branch, so the prefix buys nothing and costs a release.

Auto-attach links the external ref; the poller then observes merge and fires
`ticket.external_ref_state_changed`, which the close-on-merge rule converts into a
transition to `Closed` with `resolution: done`. **The ticket stays `In Progress` the
whole time the PR is open** — there is no "PR Open" status and there shouldn't be.

Move a ticket to `In Progress` when active coding starts. Don't leave tickets in
`Backlog` while coding against them — the board should reflect reality.

## 6. Local-first model use

The local LLM (`gemma4:31b` on Ollama) is the default for codegen and
normalization. Cloud is escalation, not the default:

- Don't reach for a cloud model in a new prompt if a local one can do it.
- Tune prompts to the local model's behavior first; the cloud handoff is for
  genuinely cloud-shaped work — deep reasoning, large context, novel domains.
- New candidate local models go through a bake-off (`bakeoff/`, results in
  `docs/bakeoffs/`) before becoming a default.

## 7. Code quality

These complement, and do not duplicate, an agent's base prompt — they are the rules
the platform owner has surfaced explicitly:

- **No half-finished implementations.** If you can't complete a feature, leave the
  existing code unchanged and surface the blocker.
- **No backwards-compat scaffolding for code you're removing.** Delete it cleanly;
  no `// removed` comments, no shim re-exports.
- **No premature abstractions.** During initial implementation, three similar lines
  beats a layer introduced for hypothetical future use.
- **Comments: WHY, not WHAT.** Default to none. Add one only when the reason for the
  code is non-obvious — a workaround, a constraint, a surprising invariant.
- **Don't validate scenarios that can't happen** in internal code. Validate at
  system boundaries (user input, external APIs) and trust the rest.

### 7a. DRY sweep on major work

**Selective, not universal.** It applies to:

- Major features, significant refactors, or work spanning multiple files or commits
  — when the surface area warrants a cleanup pass.
- Any time the user explicitly asks for a "DRY pass" / "clean-code pass" / "tidy up
  before PR". Treat the ask as binding even if the change looks small.

It does **not** apply to small bugfixes or single-file tweaks. The
overhead-to-value ratio is wrong there.

This is the *opposite timing* from the no-premature-abstractions rule in §7. That
rule governs the *first* pass, when usage is hypothetical. The sweep governs the
*last* pass, when usage exists and duplication is no longer speculative.

**DRY is the primary focus.** Look for real duplication — three or more places doing
the same thing → pull out a helper. Two is usually still fine; rule of three.

While already in the cleanup mindset, also check:

- **Dead code.** Functions, imports, branches, flags, tests referencing something
  you removed.
- **Naming drift.** Variables holding something other than what their name says,
  after a refactor.
- **Inconsistent patterns within the change.** Same-shape operations done three
  different ways → pick one.
- **Comments that became wrong.** Edits often invalidate the comment above them.

The sweep is part of the work, not a follow-up ticket — land it in the same PR. If
you surface something larger ("this whole module wants restructuring"), file a
separate ticket and call it out in the PR description rather than silently expanding
scope.

## 8. What the reviewer and verifier do with this file

Both the PR reviewer and the post-deploy verifier are expected to flag violations of
this file. Concrete checks:

- A Python file added to a non-Python repo → finding.
- A `package.json` for a new project not on TypeScript → finding.
- A shipping change typed `chore:` → finding. It silently skips the release cut,
  so this one has a real production consequence.
- A scaffolded React project without explicit justification → finding.
- A credential reused across consumers rather than minted per-consumer → finding.
- A new status that renames a canonical one → finding.

**A principles violation is a 🟡 Nit unless it has a concrete consequence**, in
which case severity comes from the consequence, not from the violation. The
`chore:`-on-a-shipping-change case is Important because the deploy silently does not
happen; a stylistic deviation is not.

**Concerns do not automatically reject.** They are surfaced for human review. The
pattern is: *if this file says no, and the change does it anyway, raise it.*
Deviations are frequently correct — §2 says to state them out loud, so a deviation
that is explained in the PR description has already met the bar. Flag the unexplained
ones.

---

*Cross-repo standards. When changing a principle here, check whether `REVIEW.md` or
`CLAUDE.md` in an affected repo restates it — a rule in two places drifts.*
