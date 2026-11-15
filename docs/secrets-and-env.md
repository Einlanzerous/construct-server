# Secrets and the deployed environment

Rationale moved out of the root `CLAUDE.md` (SERV-317). Dev's side is in
`docs/dev-environment.md`; the promote credentials are in `docs/delivery-pipeline.md`.

## Where the stack's secrets come from

Secrets the **stack** consumes reach it as `PROD_ENV_FILE`, a GitHub
Environment secret on `home-server` — not a repo-level secret. Dev's equivalent is
`DEV_ENV_FILE` on `home-server-dev`. **Both are rendered by Signet and neither is set
by hand**: `construct-server` renders `PROD_ENV_FILE`, `construct-server-dev` renders
`DEV_ENV_FILE`, and a `gh secret set` on either appears to work and is reverted by the
next `signet sync` — live now, gone when something unrelated runs. Change the value in
the vault and sync. Seed a project's render target from the **credential source**
(`creds/dev.env`), never from the deployed `.env`: the deploy root already has a writer
in `render-env.sh`, and it carries the `versions.env` tag pins, which belong to git
(SERV-96) and must not acquire a second source in the vault. See
`docs/dev-environment.md` and the ownership invariant below (SERV-94).
Credentials only a **workflow** uses (the reviewer's tokens) are repo-level
and managed by Signet: `signet set --project construct-server --name X`, then
`signet target add --secret construct-server/X --gh-repo owner/name`, then
`signet sync`. Rotation happens in the vault, not per repo. Moving these onto
a GitHub Environment is partly done — `PROMOTE_PUSH_TOKEN` already targets the
`production-promote` environment; the rest are still repo-level.

## The `imperium-loop` Signet project

**The `imperium-loop` Signet project outlived imperium-loop, and must not be
retired with it** (SERV-82). The pipeline's own containers, checkout and runner
are gone, but that Signet project is also where `RELEASE_BOT_APP_ID` and
`RELEASE_BOT_PRIVATE_KEY` live, and those target **six live repos** — purser,
switchyard, lyceum, interlock, signet, amber. They are the release-please bot's
credentials, so deleting the project to finish the decommission would break
version bumps and changelogs across the estate, silently and not at deploy time.
SERV-82 asked for exactly that and it was **not** done; only the pipeline's own
secrets were retired. The name is the whole trap: it records where the credential
was first minted, not what still uses it. Check `signet status --project` before
retiring any project, and read the TARGETS column rather than the project name.
Its `RELEASE_BOT_PRIVATE_KEY_PATH` also pointed into the deleted checkout
(`~/imperium-loop/.secrets/release-bot.pem`) and was repointed at
`~/.config/zerogravity/release-bot.pem` on the way out.

## Signet owns `PROD_ENV_FILE`, and nothing else

**Signet owns `PROD_ENV_FILE` and nothing else — the prod project has no host file
target** (SERV-94). The vault renders one thing, the `home-server` environment secret;
`deploy.yml` turns that into `/opt/construct-server/.env` via `render-env.sh` and is
the only writer of the credentials in it — ansible re-renders the *pin block* of that
same file in place on a cold host, which is a reconcile of git's values and not a
second source. Signet used to claim the path as well, and that one is a second source:
drift stops being a state you can read and becomes a race, and `signet target list` sat
at `changed` for a week and a half saying so with nobody able to act on it. It claimed `~/construct-server/.env` too — a third copy that stopped driving
anything when SERV-76 moved the deploy root, and which reported `in sync` the whole
time, because a render against a file nothing reads always succeeds. **A target whose
destination has another writer, or no consumer, is worse than no target**: both report
a state that means nothing, and the second one reports it in green.
**The vault must never deliver a key `versions.env` owns.** It delivered all ten from
2026-08-15, when SERV-96 moved the pins to git and the vault kept its copies, until
SERV-94 detached them — and eight had gone stale in that time. Nothing broke, for one
reason: `render-env.sh` strips every key the versions file defines from the base
before appending the tracked pins, so git won every time. That is a mitigation sitting
in one script, not a property — take `render-env.sh` out of the path, or let the vault
become the sole source, and prod silently rolls back every service whose vault copy
went stale. `deploy.yml`'s SERV-88 assertion would **not** catch it: a stale pin is a
real version, not `:latest`. The strip now names what it dropped instead of doing it
silently, and `make env-ownership-check` asks the vault directly so the answer does
not depend on that script still being there.
**Signet actively recommends the wrong fix here, and it does so in red.** `signet
render --project construct-server --check --against /opt/construct-server/.env` exits
**non-zero in the correct state**: it reports `WOULD DROP 11 key(s)` and ends `import
them into the vault, then signet target add-key …`. Both are right in general and
wrong for anything git owns, and following that advice re-creates the exact hazard.
The check compares the vault against the *deployed* file, and the deployed file is the
render **plus** what `render-env.sh` appends — so a healthy pipeline reads as a
shortfall. Dev's copy of this reports the same way over its four `DEV_*_TAG` keys. The
answer to a report like that is to confirm the dropped set is **exactly** the versions
file and nothing else — a credential in that list is a real problem — which is what
`make env-ownership-check` asks and exits 0 on.
Two consequences of having no file target, both easy to trip over:
**`import` no longer widens the key set**, because what `import` widens is a *file*
target's. A new stack credential is `signet set --project construct-server --name X`
followed by `signet target add-key --project construct-server --gh-secret
PROD_ENV_FILE --name X` — `signet set` alone mints a value that reaches nothing, which
is how four secrets in this project came to have no destination at all — and then,
**after** `signet sync`, a line in `required-env-keys.txt` (SERV-173, below). And
**do not detach the render target and re-add it**: `--seed-from` reads a file target's
key set, there is no longer one to read, and an unseeded rendered target is created
with an *empty* key set. Use `target add-key` to change what it delivers.
**Dev's allowlist is deliberately not empty**: `construct-server-dev` keeps
`creds/dev.env`, the readable credential source it was seeded from, which
`deploy-dev.yml` never writes. One writer, so it is a state and not a race.

## A key the vault does not hold does not exist

**A key the vault does not hold does not exist, and the deploy asserts the set**
(SERV-173). `LYCEUM_BINDERY_API_KEY` reached the prod lyceum container empty four
times between 2026-07-20 and 2026-09-14, through deploys that were green every time.
Compose reads it as `${LYCEUM_BINDERY_API_KEY:-}`, so its absence is not an error
anywhere: lyceum boots healthy with the no-op acquirer and strands every ingest at
`wanted`. Three losses were rewrites of `PROD_ENV_FILE` from a copy that predated the
key. The fourth was the **restore** — done with `gh secret set` on a secret Signet
renders, so the next `signet sync` rebuilt it from a vault that had never held the key.
The ticket's ask to "move PROD_ENV_FILE to Signet" was already true (SERV-94); Signet
is exactly why the hand restore evaporated. So two things now hold. `deploy.yml` and
`deploy-dev.yml` run `scripts/assert-env-keys.sh` right after the render and **fail
before anything pulls** if the file is missing a key in `required-env-keys.txt` or
carries it empty — names only, never a value. And `render-env.sh` **refuses** a fresh
base that defines non-pin keys below its pins marker: the marker cut is where a key
appended to the bottom of a rendered `.env` used to vanish, `unchanged` and green,
which is what the 09-06 restore attempt hit twice before anyone looked. On the
**in-place** render (ansible's reconcile of the deployed file into itself) the same
finding is a note, not an error, because there the tail is what the previous render
wrote and a pin since retired from `versions.env` looks identical to a stray. **Vault first, then the
manifest.** A manifest line whose key the vault does not deliver blocks every prod
deploy, rollbacks included, until it does; the reverse order is a warning
("delivered, unlisted") on each deploy, which is the cheap direction.
`make assert-env-keys vault=1` asks the vault what the next deploy will carry, for the
interval between `signet sync` and the deploy that renders it. A key that may
legitimately be blank does not belong in the manifest at all — an empty value is not a
value — and dev's tunnel token is the case: it is the edge's on-switch (SERV-93), so
it is deliberately absent from `dev-required-env-keys.txt`.

## A credential is never a literal argument to a process

**`creds/` and `.env` stay gitignored** (SERV-31, #55). Credentials belong on
the host or in a GitHub secret. A secret that reaches a committed file, a
build arg, or an image layer is a rotation, not a revert.
**A credential is never a literal argument to a process — feed it via stdin
or a named env var** (SERV-215). Anything after a command on its own line is
that process's argv, and argv is visible to anyone who runs `ps` on the same
host for as long as the process runs — a `docker run` on the construct
server, not just a long-lived daemon. `backup-receiver/install.sh` had two:
`ensure_credentials()` passed the REST password as a positional argument to
`htpasswd`, and `verify()`'s probes passed it to `curl -u user:pass`. Fixed
by piping it in instead — `htpasswd -Bi` reads the password from stdin,
`curl -K -` reads a config (`user = "name:pass"`) from stdin — with the
value itself only ever reaching a shell builtin (`printf`), which spawns no
process of its own to have argv in the first place. `backup-nightly.sh`
already did this for every `restic` invocation (`docker run -e NAME`,
valueless — the container reads the value from the script's own
environment, never a literal); the eventual Switchyard heartbeat (SERV-218)
needs the same treatment for its bearer token. A masked value (`user:****@host`)
is not the fix — it still teaches the shape, and the guidance in
`install.sh`'s `next_steps()` and the receiver's README is what an operator
goes on to type themselves.
