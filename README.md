# Imperial Construct 🏗️
![Deploy to Construct](https://github.com/Einlanzerous/construct-server/actions/workflows/deploy.yml/badge.svg)

Welcome to **Imperial Construct**, a localized Home Operations Center designed to provide AI services, observability, and storage capabilities in a secure, self-hosted environment.

## 🚀 Current Stack

The following services are currently active:

### 🧠 Artificial Intelligence
-   **[Ollama](https://ollama.com/)**: Backend for running local LLMs — primary models are **Gemma 4** (26B + e4b) for diff generation and ticket normalization, plus Phi-4 Reasoning and Gemma 3 12B for fallback/testing.
-   **[Open WebUI](https://docs.openwebui.com/)**: A beautiful, feature-rich interface for interacting with your local LLMs (similar to ChatGPT).

### 🛡️ Observability
-   **[Uptime Kuma](https://github.com/louislam/uptime-kuma)**: Self-hosted monitoring tool for services.
-   **[Datadog](https://datadoghq.com)**: Cloud-based monitoring and logging.
-   **[Dozzle](https://dozzle.dev)**: Real-time log viewer for Docker containers.

### 🏠 Dashboard
-   **[Aperture](https://github.com/Einlanzerous/aperture)**: A custom dashboard to access all services from a single page, with live Docker container status.

### 📂 Storage & File Sharing
-   **[Copyparty](https://github.com/9001/copyparty)**: Lightweight file server serving files from the 1TB NVMe drive (`/data`).

### 🎬 Media & Library
-   **[Argosy](https://github.com/Einlanzerous/argosy)**: Self-hosted media streaming — a single Go binary with the Vue SPA embedded, plus an ffmpeg/Intel-QSV runtime for hardware transcoding (`/dev/dri`). Libraries span the NVMe (`/data/media`) and the 2TB SSD (`/mnt/ssd_storage`), mounted read-only.
-   **[Lyceum](https://github.com/Einlanzerous/lyceum)**: Self-hosted ebook reader + sync. One Go binary serving the JSON API *and* the embedded Vue reader SPA same-origin; EPUB/cover blobs on a named volume, folder-ingest watching the books library. Native Android/Windows shells and the browser reader all hit `:4005`. Household accounts are on (`LYCEUM_AUTH=true`) with Cloudflare Access SSO.

### 🗄️ Database
-   **[PostgreSQL 16](https://www.postgresql.org/)**: Shared instance providing isolated databases for application services. Each service gets its own database and user — see [Architecture](#-database-architecture) below.

### 📋 Task Management & Automation
-   **[Switchyard](https://github.com/Einlanzerous/switchyard)**: Self-hosted, API-first ticketing / project management system (Hono + Bun + Drizzle on the server, Vue 3 on the client) backed by its own `switchyard` database. Task hub for the **Imperium-Loop** automated development pipeline; replaced Vikunja in May 2026.
-   **[n8n](https://n8n.io)**: Workflow automation engine (codename *Vox-Command*). Hosts the Cogitation Engine and Vox-Dictate workflows that drive Imperium-Loop.
-   **[Servo-Signal](https://github.com/Einlanzerous/imperium-loop)**: Local MCP tool server (Go) that gives n8n and Claude access to git, filesystem, patching, ephemeral Docker execution, and two agentic loops (planning + greenfield). Source lives in `~/imperium-loop`.
-   **[Autosavant](https://github.com/Einlanzerous/imperium-loop/tree/main/autosavant-bot)**: Discord bot that owns the human-in-the-loop approval checkpoints (plan review, greenfield guidance). Posts an embed to a task thread, watches for replies, and resumes the paused n8n execution.

### 🔧 Application Services
-   **[cook_book](services/cook_book/)**: TypeScript/Prisma recipe service with its own `cook_book` database.
-   **[Purser](https://github.com/Einlanzerous/purser)**: Cross-service provisioning & invite service (Go, single static binary — CLI + thin HTTP API). One command onboards a person into multiple Construct services: creates their [Switchyard](https://github.com/Einlanzerous/switchyard) user + token, creates their [Lyceum](https://github.com/Einlanzerous/lyceum) account, and grants Cloudflare Access SSO (email OTP), returning a copy-pasteable credential block. A downstream consumer of this stack — backed by its own `purser` database, and it calls Switchyard's `/v1` API, Lyceum's `/admin` API, and the Cloudflare Access API. Image: `ghcr.io/einlanzerous/purser`.
-   **[Interlock](https://github.com/Einlanzerous/interlock)**: City + state legislation tracker (Nuxt/Nitro SSR) serving its UI and `/api` behind single-user session auth. A `worker` sidecar handles scheduled LegiScan syncs and alerting.
-   **[Centrifuge](https://github.com/Einlanzerous/centrifuge)**: Newsletter curation — HTTP API plus a decoupled scoring worker that calls the in-stack Ollama by service name for relevance scoring.
-   **[Signet](https://github.com/Einlanzerous/signet)**: Credential vault + outbound GitHub-secret sync (Go, single binary). Unlike the rest of the stack it runs as a **host systemd daemon**, not a container — deployed by the `signet` ansible role and bound to `127.0.0.1:4010`. Switchyard's owner-gated Credentials surface (SWY-165) reaches it through a server-side proxy over `host.docker.internal`; the bearer token never touches the browser. Vault (master key + SQLite ledger) lives under the `magos` home, deliberately off the shared Postgres.
-   **[Amber](https://github.com/Einlanzerous/amber)**: Claude Code transcript capture & preservation (Go, single static binary). Redacts and archives transcript data to `/mnt/ssd_storage/amber` before Claude Code's rolling retention sweep deletes it, then indexes what it archived into its own `amber` database. The archive is the source of truth and the index is rebuildable from it, so a Postgres outage degrades search without stopping capture. Reads two host paths **read-only** — `~/.claude/projects` and `~/.claude/history.jsonl`, mounted individually because `~/.claude` as a whole holds `.credentials.json`. `/readyz` on port 4008 goes 503 when capture has stalled or when uncaptured data is approaching its deletion date. Image: `ghcr.io/einlanzerous/amber`.

-   **[Drydock](https://github.com/Einlanzerous/drydock)**: Durable web terminal multiplexer for AI CLIs — agent sessions survive disconnects, so a run started from one machine is still running when you open another. Split across the host/container boundary like Signet, and for the same kind of reason: the **daemon** is a systemd **user** unit on `:4318` (`drydock-daemon`, checkout under `~/.drydock/prod`) because it spawns `claude` and shell PTYs as the host user and needs that user's repos, toolchain and `~/.claude`; only the **shell** — a static Vite bundle behind nginx, `drydock-shell` on `:5321` — is a container here. The browser loads the bundle and then talks to the daemon directly, so the container joins no internal network. Workspace state, session history and accounts live in the shared Postgres (`drydock` database); a database outage degrades the desk without touching a running agent. Image: `ghcr.io/einlanzerous/drydock/shell`.

### 🎮 Gaming & Remote Play
-   **[Sunshine](https://github.com/LizardByte/Sunshine)**: High-performance game streaming host for Moonlight.

### 🌐 Public Edge
Public hostnames under `zerogravity.industries` are served through a Cloudflare Tunnel — **no open ports**. See **[docs/zerogravity-edge.md](docs/zerogravity-edge.md)** for the full architecture, the split-entrypoint security model, and the bring-up runbook.

-   **[Traefik v3](https://traefik.io)**: Reverse proxy with split entrypoints — `internal` (tunnel-only, never published to the host) and `public` (Argosy's direct path, not yet bound). Strips spoofable identity headers on ingress.
-   **[cloudflared](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/)**: In-stack tunnel connector; origins point at `http://traefik:9080`.
-   **Cloudflare Access**: Email one-time-PIN SSO in front of the tunneled apps. A shared `zerogravity-members` group is the single allow-list; Switchyard and Lyceum both match the CF-verified email against their own user records and **never auto-provision**, so accounts are created up-front via Purser.

> **Identity invariant:** a person needs *both* a Cloudflare Access entry and an app account with the same email. Provision with `purser invite --to switchyard,lyceum,cloudflare` so both halves land together — adding only one side leaves them able to pass the edge gate and then be refused by the app.

## 🗺️ Roadmap

Items that have shipped live in the [Current Stack](#-current-stack) above. This section tracks what's still planned:

-   [ ] **[Strapi](https://strapi.io)**: Headless CMS for the urbanist blog.
-   [ ] **[Betterstack](https://betterstack.com)**: Uptime monitoring and incident alerting.
-   [ ] **[Kourier](https://github.com/Kourier/Kourier)**: Self-hosted modern email client.
-   [ ] **[Rundeck](https://www.rundeck.com)**: Enterprise job scheduler (potential Semaphore replacement if needed).
-   [ ] **Authentik**: Self-hosted identity as the single source of truth, replacing Cloudflare Access's built-in email-OTP IdP. Authored and gated behind the `identity` compose profile — not started by a plain `docker compose up -d`. See [docs/zerogravity-edge.md](docs/zerogravity-edge.md).
-   [ ] **Direct/Argosy path**: A DNS-only record → WAN 443 → Traefik's `public` entrypoint, so media bypasses the tunnel. Blocked by CGNAT; needs a relay.

Previously on the roadmap, now in active use: Copyparty, Switchyard (which replaced Vikunja, which itself replaced the earlier Plane plan), n8n, the full Imperium-Loop pipeline, and **Lyceum** (which supersedes the earlier Panox plan for book library management).

## 🛠️ Setup & Installation

1.  **Clone the repository:**
    ```bash
    git clone https://github.com/Einlanzerous/construct-server.git
    cd construct-server
    ```

2.  **Configure Environment Variables:**
    Copy the example file and update it with your secrets. Core vars: Datadog API Key, Postgres/Switchyard/n8n passwords. Imperium-Loop pipeline also needs `ANTHROPIC_API_KEY`, `GITHUB_PAT`, `SWITCHYARD_DB_PASSWORD`, `SWITCHYARD_BOOTSTRAP_TOKEN`, `DISCORD_BOT_TOKEN`/`DISCORD_CHANNEL_ID`/`DISCORD_PLANNING_WEBHOOK_URL`, and `N8N_API_KEY`. The public edge needs `CLOUDFLARE_TUNNEL_TOKEN` (and `CF_DNS_API_TOKEN` once the direct path is unblocked); Purser's connectors need `PURSER_CF_*` and `PURSER_LYCEUM_OWNER_TOKEN`.

    > **Deploys don't read this file.** CI writes `.env` on the server from the **`PROD_ENV_FILE`** secret on the `home-server` environment. A var added here but not there will vanish on the next deploy — update both (`gh secret set PROD_ENV_FILE --env home-server < .env`).
    ```bash
    cp .env.example .env
    nano .env
    ```

3.  **Create the Docker network:**
    The postgres and application services communicate over an external bridge network.
    ```bash
    make network
    ```

4.  **Start the Stack:**
    ```bash
    make up
    # or: docker compose up -d
    ```

5.  **Verify the database** *(optional)*:
    ```bash
    make db-check
    ```

### 🔄 Automation & CI/CD
-   **[Watchtower](https://containrrr.dev/watchtower/)**: Auto-updates a deliberately small opt-in set of third-party containers, Mondays at 04:00 (SERV-75). It monitors only containers labelled `com.centurylinklabs.watchtower.enable=true` — currently dozzle, uptime-kuma, datadog and itself. No first-party image is auto-rolled; `deploy.yml` owns those.
-   **[GitHub Actions Runner](https://github.com/actions/runner)**: Self-hosted runner for deploying changes to this server automatically.
-   **[Semaphore UI](https://semaphoreui.com)**: Modern UI for running Ansible playbooks.

## 🗄️ Database Architecture

A single PostgreSQL 16 instance provides logically isolated databases for application services:

| Service | Database | User | Migrations |
|---------|----------|------|------------|
| cook_book | `cook_book` | `cook_book_user` | [Prisma Migrate](https://www.prisma.io/docs/concepts/components/prisma-migrate) — `prisma migrate deploy` at entrypoint |
| switchyard | `switchyard` | `switchyard_user` | Drizzle migrations run at server entrypoint |
| purser | `purser` | `purser_user` | In-process embedded migrator (`internal/store/migrate.go`) at boot |
| argosy | `argosy` | `argosy_user` | Run by the Go binary at startup |
| lyceum | `lyceum` | `lyceum_user` | Run by the Go binary at startup |
| interlock | `interlock` | `interlock_user` | Custom SQL migrator (`packages/db`), advisory-locked so web + worker can't race at boot |
| centrifuge | `centrifuge` | `centrifuge_user` | `centrifuge migrate` in the entrypoint |
| amber | `amber` | `amber_user` | In-process embedded migrator (`internal/store/migrate.go`) at boot; append-only, each file's sha256 recorded |
| authentik | `authentik` | `authentik_user` | Django migrations on boot (`identity` profile — authored, not deployed) |
| n8n | `n8n` | `n8n_user` | n8n auto-migrates on startup |
| drydock | `drydock` | `drydock_user` | In-process migrator (`daemon/src/state/migrations/*.sql`), checksummed and **lazy** — nothing connects at boot, so an unreachable database can't stop a daemon holding live agent PTYs |

- Databases and users are created by `db/init-db.sh` — on first volume initialization via the Postgres entrypoint, and again on every deploy, which pipes the same script into the running container (`.github/workflows/deploy.yml`). It is idempotent, and skips any role whose `<SERVICE>_DB_PASSWORD` is empty rather than blanking it.
- `drydock_user` is the exception: it was provisioned directly against the running cluster and has no `ensure_db` line yet, because adding one changes the `postgres` service spec and therefore bounces every service that depends on it. That lands as its own deliberate change (SERV-72).
- Each service owns its own migrations and runs them independently at startup — no init-container needed.
- Postgres runs on the `construct_net` bridge network and additionally publishes `127.0.0.1:5432` — loopback only, never the LAN. That published port is what lets host-resident services (Drydock's daemon) use the cluster without being containers.
- Ollama is dual-homed (default + `construct_net`) so services like n8n and Servo-Signal can reach it by container name. Open WebUI, Uptime Kuma, Copyparty, Datadog, Dozzle, and Aperture remain on the default network for now — migration is incremental.

> **TODO — Uptime Kuma monitoring:** Add Uptime Kuma to `construct_net` so it can monitor services internally (e.g. `http://cook_book:4001`, `http://switchyard:4002`), then add HTTP monitors via the Kuma UI. Currently deferred because Kuma also monitors AI stack services that aren't on `construct_net` yet.

### Makefile Targets

| Target | Description |
|--------|-------------|
| `make network` | Create the `construct_net` Docker bridge network |
| `make up` | Create network + start full stack |
| `make down` | Stop full stack |
| `make recreate [svc=<name>] [deps=1]` | **Recreate** service(s) after a compose edit — scoped to `svc` alone unless `deps=1` (see [Operations](#-operations--runbook)) |
| `make force-recreate svc=<name>` | Recreate one container whose spec did **not** change (e.g. to re-read an `env_file`) |
| `make drift-check [svc=<name>]` | Detect containers running a stale spec vs `docker-compose.yml` |
| `make db-up` | Start only the postgres service |
| `make db-shell` | Open a psql shell to postgres |
| `make db-check` | Verify databases and user access |

## 🛠️ Operations & Runbook

### ⚠️ After editing `docker-compose.yml`: recreate, never restart

`docker restart <svc>` **reuses the existing container's config** — it does **not** pick up
mount, env, image, port, or any other change you just made to `docker-compose.yml`. The
container keeps running its old spec, silently, until it is recreated.

After **any** edit to `docker-compose.yml`, recreate the affected service so the new spec
takes effect:

```bash
make recreate svc=argosy
# or directly:
docker compose up -d --no-deps argosy   # `up -d` detects config drift and recreates
```

`docker compose up -d` is safe to run repeatedly: it recreates only the services whose
config changed and leaves the rest untouched. Data on **named volumes survives** a
recreate (e.g. postgres data lives on a named volume — recreating the container does not
touch it).

> **Why this matters — the SSD Library outage (SERV-8, 2026-06-29):** the `/mnt/ssd_storage/media → /media-ssd:ro`
> bind was added to `docker-compose.yml`, but the live `argosy` container had only been
> `docker restart`ed afterward, so it never gained the mount. Every SSD-Library title
> (Futurama, 24, …) 503'd then 404'd with `open /media-ssd/shows/...: no such file or directory`,
> even though the host SSD was healthy and the DB had valid rows. The fix was a single
> recreate of `argosy` — today `make recreate svc=argosy` — which detected the drift and
> reattached the mount.

### ⚠️ Recreating one service: keep it to one service

Compose actions follow `depends_on`. Every service with a database declares
`depends_on: postgres` — nine in the default stack, eleven counting the `identity`
profile — so a command aimed at **one** container can reach the shared database and
bounce the entire stack. `--no-deps` scopes it to the service you named — `make recreate svc=<name>` and
`make force-recreate svc=<name>` both bake the flag in, so the safe form is the shortest
one to type.

```bash
make recreate svc=purser              # compose edit — mounts, env, image, ports
make force-recreate svc=purser        # spec unchanged, but force a fresh container
make recreate svc=purser deps=1       # cold start: dependencies SHOULD come up
```

Use `deps=1` (or plain `make up`) when the dependency genuinely isn't running yet —
`--no-deps` will happily start a service into a missing database.

> **Why this matters — the postgres bounce (SERV-63, 2026-08-01):** `docker compose up -d
> --force-recreate purser` also recreated `postgres`, because `--force-recreate`
> propagates to dependencies. Every dependent absorbed it — argosy logged
> `terminating connection due to administrator command (57P01)` and reconnected on a 1s
> backoff, the rest logged nothing — so nothing needed repair. But that depended on
> postgres restarting in about a second and nothing being mid-transaction. Widen the
> startup window with a migration, WAL replay, or a larger dataset and the same command is
> an outage. The intent was one container; the reach was every service on the box.

### Checking for drift

To verify that the live containers actually match `docker-compose.yml` — i.e. nothing has
been left on a stale spec — run the drift checker:

```bash
make drift-check              # check every service
make drift-check svc=argosy   # check one service
```

It compares each running container's live mounts (`docker inspect`) against the mounts
declared in the resolved compose file (`docker compose config`) and flags:

- **DRIFT** (exit 1) — a declared mount is **missing** or has the wrong type/read-only
  flag, or a stale bind lingers that compose no longer declares. Fix with `make recreate svc=<name>`.
- **warn** (exit 0) — informational only, e.g. a bind source that differs because the
  stack was deployed from a different checkout (the CI runner), or an image-declared
  anonymous volume.

Because it exits non-zero on real drift, it's also suitable as a periodic / pre-deploy check.

## 🧰 Helper Tools
- **[Software Page Generator](tools/software-page/README.md)**: Creates a static HTML page with links to essential software downloads.

## 🖥️ System Provisioning (Ansible)

> [!NOTE] 
> For detailed documentation on all playbooks, including **Work Laptop** setup, see **[ansible/README.md](ansible/README.md)**.


## 🔒 Security Note
This project uses a `.env` file to manage sensitive keys. **Never commit your `.env` file to GitHub.** A `.gitignore` is included to prevent this.
