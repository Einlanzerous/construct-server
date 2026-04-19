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

### 💬 Matrix Stack (vox-loop)
-   **[vox-loop (Dendrite)](services/vox-loop/)**: Self-hosted Matrix homeserver backed by the `vox_loop` database.
-   **[Sliding Sync](https://github.com/matrix-org/sliding-sync)**: Matrix sliding sync proxy for modern clients (Element X). Uses its own `syncv3` database.
-   **[Caddy](https://caddyserver.com/)**: Reverse proxy routing `.well-known`, sliding sync, and `_matrix/*` traffic to the appropriate service.

### 📋 Task Management & Automation
-   **[Vikunja](https://vikunja.io)**: Self-hosted task board (Kanban) backed by its own `vikunja` database. Used as the task hub for the **Imperium-Loop** automated development pipeline.
-   **[n8n](https://n8n.io)**: Workflow automation engine (codename *Vox-Command*). Hosts the Cogitation Engine and Vox-Dictate workflows that drive Imperium-Loop.
-   **[Servo-Signal](https://github.com/Einlanzerous/imperium-loop)**: Local MCP tool server (Go) that gives n8n and Claude access to git, filesystem, patching, ephemeral Docker execution, and two agentic loops (planning + greenfield). Source lives in `~/imperium-loop`.
-   **[Autosavant](https://github.com/Einlanzerous/imperium-loop/tree/main/autosavant-bot)**: Discord bot that owns the human-in-the-loop approval checkpoints (plan review, greenfield guidance). Posts an embed to a task thread, watches for replies, and resumes the paused n8n execution.

### 🔧 Application Services
-   **[cook_book](services/cook_book/)**: TypeScript/Prisma recipe service with its own `cook_book` database.

### 🎮 Gaming & Remote Play
-   **[Sunshine](https://github.com/LizardByte/Sunshine)**: High-performance game streaming host for Moonlight.

## 🗺️ Roadmap

Items that have shipped live in the [Current Stack](#-current-stack) above. This section tracks what's still planned:

-   [ ] **[Panox](https://panox.io)**: Library Management System for books/games.
-   [ ] **[Strapi](https://strapi.io)**: Headless CMS for the urbanist blog.
-   [ ] **[Betterstack](https://betterstack.com)**: Uptime monitoring and incident alerting.
-   [ ] **[Kourier](https://github.com/Kourier/Kourier)**: Self-hosted modern email client.
-   [ ] **[Rundeck](https://www.rundeck.com)**: Enterprise job scheduler (potential Semaphore replacement if needed).

Previously on the roadmap, now in active use: Copyparty, Vikunja (replaced the earlier Plane plan), n8n, and the full Imperium-Loop pipeline.

## 🛠️ Setup & Installation

1.  **Clone the repository:**
    ```bash
    git clone https://github.com/Einlanzerous/construct-server.git
    cd construct-server
    ```

2.  **Configure Environment Variables:**
    Copy the example file and update it with your secrets. Core vars: Datadog API Key, Postgres/Vikunja/n8n passwords. Imperium-Loop pipeline also needs `ANTHROPIC_API_KEY`, `GITHUB_PAT`, `VIKUNJA_SERVICE_USER`/`VIKUNJA_SERVICE_PASSWORD`, `DISCORD_BOT_TOKEN`/`DISCORD_CHANNEL_ID`/`DISCORD_PLANNING_WEBHOOK_URL`, and `N8N_API_KEY`.
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
| vox-loop (Dendrite) | `vox_loop` | `vox_loop_user` | Dendrite auto-migrates on startup |
| sliding-sync | `syncv3` | `syncv3_user` | Auto-migrates on startup |
| cook_book | `cook_book` | `cook_book_user` | [Prisma Migrate](https://www.prisma.io/docs/concepts/components/prisma-migrate) — `prisma migrate deploy` at entrypoint |
| vikunja | `vikunja` | `vikunja_user` | Vikunja auto-migrates on startup |
| n8n | `n8n` | `n8n_user` | n8n auto-migrates on startup |

- Databases and users are created automatically by `db/init-db.sh` on first volume initialization.
- Each service owns its own migrations and runs them independently at startup — no init-container needed.
- Postgres is internal-only on the `construct_net` bridge network (no exposed port).
- Ollama is dual-homed (default + `construct_net`) so services like n8n and Servo-Signal can reach it by container name. Open WebUI, Uptime Kuma, Copyparty, Datadog, Dozzle, and Aperture remain on the default network for now — migration is incremental.

> **TODO — Uptime Kuma monitoring:** Add Uptime Kuma to `construct_net` so it can monitor services internally (e.g. `http://vox-loop:8008`, `http://cook_book:4001`), then add HTTP monitors via the Kuma UI. Currently deferred because Kuma also monitors AI stack services that aren't on `construct_net` yet.

### Makefile Targets

| Target | Description |
|--------|-------------|
| `make network` | Create the `construct_net` Docker bridge network |
| `make up` | Create network + start full stack |
| `make down` | Stop full stack |
| `make db-up` | Start only the postgres service |
| `make db-shell` | Open a psql shell to postgres |
| `make db-check` | Verify databases and user access |

## 🧰 Helper Tools
- **[Software Page Generator](tools/software-page/README.md)**: Creates a static HTML page with links to essential software downloads.

## 🖥️ System Provisioning (Ansible)

> [!NOTE] 
> For detailed documentation on all playbooks, including **Work Laptop** setup, see **[ansible/README.md](ansible/README.md)**.


## 🔒 Security Note
This project uses a `.env` file to manage sensitive keys. **Never commit your `.env` file to GitHub.** A `.gitignore` is included to prevent this.
