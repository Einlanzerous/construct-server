# CLAUDE.md — Construct Server

The Imperial Construct: a self-hosted home operations center. This repo is the
**stack definition**, not a service — `docker-compose.yml` plus the edge config,
database bootstrap, and Ansible that stand it up. The services themselves
(Argosy, Switchyard, Lyceum, Purser, Signet, Centrifuge, Interlock, Aperture,
Cook Book) live in their own repos and land here as images.

Tracked in Switchyard under the **SERV** project. Cross-service delivery design
lives in `docs/delivery-pipeline.md` (IDEA-19) — read it before changing how
anything deploys or gets versioned.

## Layout

- `docker-compose.yml` — the whole stack, ~30 services, single file.
- `config/` — Traefik, CrowdSec, and Copyparty config mounted into containers.
- `caddy/`, edge routing — public 443 paths and Cloudflare Access.
- `db/init-db.sh` — idempotent role/database bootstrap, runs on **every** deploy.
- `ansible/` — host-level ops (`ops/` playbooks, roles). Not container config.
- `scripts/check-compose-drift.sh` — the SERV-8 guardrail (see Invariants).
- `services/` — first-party service source that hasn't graduated to its own repo.
- `agent/rules/`, `bakeoff/` — local-model rules and the model bakeoff harness.
- `creds/` — gitignored. Real credentials live here on the host and never in git.

## Conventions

- Conventional commits, with the Switchyard key in the subject:
  `fix(signet): render the sudoers rule via template, not copy content (SERV-62)`.
  Scope is the service or subsystem. Branches are `type/short-slug-serv-NN`.
- Release-please owns `CHANGELOG.md` and version bumps. Don't hand-edit either.
- Deploys are GitHub Actions on the self-hosted `imperial-construct` runner.
  `deploy.yml` fires on push to `main` touching stack paths; service repos fire
  `repository_dispatch`.
- Secrets reach the stack as `PROD_ENV_FILE`, a **GitHub Environment secret on
  `home-server`** — not a repo-level secret. Update it with
  `gh secret set PROD_ENV_FILE --env home-server`.
- Text files are LF via `.gitattributes` (SERV-52). A diff that looks like a
  whole-file rewrite is usually a line-ending regression.

## Invariants — don't break these

- **An empty environment variable is not a value.** Never let an unset or empty
  env propagate into compose or SQL as if it were set. `db/init-db.sh` learned
  this the hard way: Postgres stores an empty password as NULL, so
  `ALTER ROLE … PASSWORD ''` silently *blanks* the role and every SCRAM login
  fails with 28P01 — it bit Purser three times (SERV-33/40, #64). The same class
  of bug crash-looped Switchyard through an empty `SIGNET_API_TOKEN` (#74). The
  fix in both cases is to **skip loudly**, not to substitute a default: an
  existing role keeps working, and a missing one surfaces as a clear "can't
  connect" rather than silently broken auth.
- **Recreate containers, never restart them.** `docker restart <svc>` keeps the
  container's OLD spec, so mount, env, and image edits in `docker-compose.yml`
  never take effect — the SERV-8 `/media-ssd` drift incident (2026-06-29). Use
  `docker compose up -d <svc>`. `scripts/check-compose-drift.sh` exists to catch
  the drift after the fact; it is not a substitute for getting it right.
- **`db/init-db.sh` must stay idempotent.** It runs on every single deploy
  against the live Postgres. Anything that isn't safe to re-run belongs in a
  service's own migrator, not here.
- **The runner is a systemd service with a bare system PATH.** It never sources
  a login shell, so anything installed under `$HOME` — ansible, bun, node, fnm
  shims — is invisible to it. Add it via `$GITHUB_PATH` in a step and check for
  it explicitly so failures read as "not on PATH" rather than `command not
  found` from three layers down. SERV-62 hit this twice (#85).
- **Deploys run from the runner's checkout, not `~/construct-server`.** Two
  compose projects are bound to different files on this host; edits in the home
  directory are not necessarily what is live. Verify with `docker compose ls`
  before concluding a config change took effect.
- **Every first-party image is `:latest`, and watchtower rolls the stack
  Mondays at 04:00.** A merge can therefore go live unattended, and the running
  version is not deterministic. Pinning tags is the prerequisite for everything
  in `docs/delivery-pipeline.md` — until it lands, treat "what's deployed" as a
  question you have to answer by inspection.
- **`creds/` and `.env` stay gitignored** (SERV-31, #55). Credentials belong on
  the host or in a GitHub secret. A secret that reaches a committed file, a
  build arg, or an image layer is a rotation, not a revert.
- **Render config files from templates, not copied content.** A sudoers rule
  written with `copy: content=` silently loses validation and ownership
  semantics that `template:` gives you (#84). This generalizes: if a file has a
  validator, wire it up.

## Validating a change

There is no test suite — this repo is configuration, so validation is mostly
"does the thing it configures still come up".

- `ansible-lint` runs in CI on `ansible/**`; run it locally before pushing.
- `docker compose config` catches compose syntax and interpolation errors.
- `./scripts/check-compose-drift.sh [service]` after any mount or env change.
- For edge or auth changes, the only real check is a request through the public
  path — internal container-to-container success proves nothing about Access.
