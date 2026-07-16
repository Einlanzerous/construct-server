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

### 🗄️ Database
-   **[PostgreSQL 16](https://www.postgresql.org/)**: Shared instance providing isolated databases for application services. Each service gets its own database and user — see [Architecture](#-database-architecture) below.

### 📋 Task Management & Automation
-   **[Switchyard](https://github.com/Einlanzerous/switchyard)**: Self-hosted, API-first ticketing / project management system (Hono + Bun + Drizzle on the server, Vue 3 on the client) backed by its own `switchyard` database. Task hub for the **Imperium-Loop** automated development pipeline; replaced Vikunja in May 2026.
-   **[n8n](https://n8n.io)**: Workflow automation engine (codename *Vox-Command*). Hosts the Cogitation Engine and Vox-Dictate workflows that drive Imperium-Loop.
-   **[Servo-Signal](https://github.com/Einlanzerous/imperium-loop)**: Local MCP tool server (Go) that gives n8n and Claude access to git, filesystem, patching, ephemeral Docker execution, and two agentic loops (planning + greenfield). Source lives in `~/imperium-loop`.
-   **[Autosavant](https://github.com/Einlanzerous/imperium-loop/tree/main/autosavant-bot)**: Discord bot that owns the human-in-the-loop approval checkpoints (plan review, greenfield guidance). Posts an embed to a task thread, watches for replies, and resumes the paused n8n execution.

### 🔧 Application Services
-   **[cook_book](services/cook_book/)**: TypeScript/Prisma recipe service with its own `cook_book` database.
-   **[Purser](https://github.com/Einlanzerous/purser)**: Cross-service provisioning & invite service (Go, single static binary — CLI + thin HTTP API). One command onboards a person into multiple Construct services: creates their [Switchyard](https://github.com/Einlanzerous/switchyard) user + token and grants Cloudflare Access SSO (email OTP), returning a copy-pasteable credential block. A downstream consumer of this stack — backed by its own `purser` database, and it calls Switchyard's `/v1` API and the Cloudflare Access API. Image: `ghcr.io/einlanzerous/purser`.

### 🎮 Gaming & Remote Play
-   **[Sunshine](https://github.com/LizardByte/Sunshine)**: High-performance game streaming host for Moonlight.

## 🗺️ Roadmap

Items that have shipped live in the [Current Stack](#-current-stack) above. This section tracks what's still planned:

-   [ ] **[Panox](https://panox.io)**: Library Management System for books/games.
-   [ ] **[Strapi](https://strapi.io)**: Headless CMS for the urbanist blog.
-   [ ] **[Betterstack](https://betterstack.com)**: Uptime monitoring and incident alerting.
-   [ ] **[Kourier](https://github.com/Kourier/Kourier)**: Self-hosted modern email client.
-   [ ] **[Rundeck](https://www.rundeck.com)**: Enterprise job scheduler (potential Semaphore replacement if needed).

Previously on the roadmap, now in active use: Copyparty, Switchyard (which replaced Vikunja, which itself replaced the earlier Plane plan), n8n, and the full Imperium-Loop pipeline.

## 🛠️ Setup & Installation

1.  **Clone the repository:**
    ```bash
    git clone https://github.com/Einlanzerous/construct-server.git
    cd construct-server
    ```

2.  **Configure Environment Variables:**
    Copy the example file and update it with your secrets. Core vars: Datadog API Key, Postgres/Switchyard/n8n passwords. Imperium-Loop pipeline also needs `ANTHROPIC_API_KEY`, `GITHUB_PAT`, `SWITCHYARD_DB_PASSWORD`, `SWITCHYARD_BOOTSTRAP_TOKEN`, `DISCORD_BOT_TOKEN`/`DISCORD_CHANNEL_ID`/`DISCORD_PLANNING_WEBHOOK_URL`, and `N8N_API_KEY`.
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
-   **[Watchtower](https://containrrr.dev/watchtower/)**: Automatically updates running Docker containers (excludes AI stack and local-build images like Servo-Signal and Autosavant).
-   **[GitHub Actions Runner](https://github.com/actions/runner)**: Self-hosted runner for deploying changes to this server automatically.
-   **[Semaphore UI](https://semaphoreui.com)**: Modern UI for running Ansible playbooks.

## 🗄️ Database Architecture

A single PostgreSQL 16 instance provides logically isolated databases for application services:

| Service | Database | User | Migrations |
|---------|----------|------|------------|
| cook_book | `cook_book` | `cook_book_user` | [Prisma Migrate](https://www.prisma.io/docs/concepts/components/prisma-migrate) — `prisma migrate deploy` at entrypoint |
| switchyard | `switchyard` | `switchyard_user` | Drizzle migrations run at server entrypoint |
| purser | `purser` | `purser_user` | In-process embedded migrator (`internal/store/migrate.go`) at boot |
| n8n | `n8n` | `n8n_user` | n8n auto-migrates on startup |

- Databases and users are created automatically by `db/init-db.sh` on first volume initialization.
- Each service owns its own migrations and runs them independently at startup — no init-container needed.
- Postgres is internal-only on the `construct_net` bridge network (no exposed port).
- Ollama is dual-homed (default + `construct_net`) so services like n8n and Servo-Signal can reach it by container name. Open WebUI, Uptime Kuma, Copyparty, Datadog, Dozzle, and Aperture remain on the default network for now — migration is incremental.

> **TODO — Uptime Kuma monitoring:** Add Uptime Kuma to `construct_net` so it can monitor services internally (e.g. `http://cook_book:4001`, `http://switchyard:4002`), then add HTTP monitors via the Kuma UI. Currently deferred because Kuma also monitors AI stack services that aren't on `construct_net` yet.

### Makefile Targets

| Target | Description |
|--------|-------------|
| `make network` | Create the `construct_net` Docker bridge network |
| `make up` | Create network + start full stack |
| `make down` | Stop full stack |
| `make recreate [svc=<name>]` | **Recreate** service(s) after a compose edit (see [Operations](#-operations--runbook)) |
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
docker compose up -d argosy           # `up -d` detects config drift and recreates
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
> `docker compose up -d argosy`, which detected the drift and reattached the mount.

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
