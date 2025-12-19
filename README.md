# Imperial Construct 🏗️
![Deploy to Construct](https://github.com/Einlanzerous/construct-server/actions/workflows/deploy.yml/badge.svg)

Welcome to **Imperial Construct**, a localized Home Operations Center designed to provide AI services, observability, and storage capabilities in a secure, self-hosted environment.

## 🚀 Current Stack

The following services are currently active:

### 🧠 Artificial Intelligence
-   **[Ollama](https://ollama.com/)**: Backend for running large language models (LLMs) like Gemma 3 and Llama 3 locally.
-   **[Open WebUI](https://docs.openwebui.com/)**: A beautiful, feature-rich interface for interacting with your local LLMs (similar to ChatGPT).

### 🛡️ Observability
-   **[Uptime Kuma](https://github.com/louislam/uptime-kuma)**: Self-hosted monitoring tool for services.
-   **[Datadog](https://datadoghq.com)**: Cloud-based monitoring and logging.
-   **[Dozzle](https://dozzle.dev)**: Real-time log viewer for Docker containers.

### 🏠 Dashboard
-   **[Homer](https://github.com/bastienwirtz/homer)**: A static homepage to access all services from a single dashboard.

### 📂 Storage & File Sharing
-   **[Copyparty](https://github.com/9001/copyparty)**: Lightweight file server serving files from the 1TB NVMe drive (`/data`).

### 🎮 Gaming & Remote Play
-   **[Sunshine](https://github.com/LizardByte/Sunshine)**: High-performance game streaming host for Moonlight.

## 🗺️ Roadmap

-   [x] **[Copyparty](https://github.com/9001/copyparty)**: File server capabilities (drag-and-drop uploads, media streaming).
-   [ ] **[Panox](https://panox.io)**: Library Management System for books/games.
-   [ ] **[Strapi](https://strapi.io)**: Headless CMS for the urbanist blog.
-   [ ] **[Plane](https://plane.so)**: Project management for political dashboard.
-   [x] **[n8n](https://n8n.io)**: Workflow automation (The AI Secretary).
-   [ ] **[Betterstack](https://betterstack.com)**: Uptime monitoring and incident alerting.
-   [ ] **[Kourier](https://github.com/Kourier/Kourier)**: Self-hosted modern email client.

## 🛠️ Setup & Installation

1.  **Clone the repository:**
    ```bash
    git clone https://github.com/Einlanzerous/construct-server.git
    cd construct-server
    ```

2.  **Configure Environment Variables:**
    Copy the example file and update it with your secrets (specifically your Datadog API Key).
    ```bash
    cp .env.example .env
    # Edit .env with your favorite text editor
    nano .env
    ```

3.  **Start the Stack:**
    ```bash
    docker-compose up -d
    ```

### 🔄 Automation & CI/CD
-   **[Watchtower](https://containrrr.dev/watchtower/)**: Automatically updates running Docker containers (excludes AI stack).
-   **[GitHub Actions Runner](https://github.com/actions/runner)**: Self-hosted runner for deploying changes to this server automatically.
-   **[n8n](https://n8n.io)**: Workflow automation.

## 🗺️ Roadmap

## 🖥️ System Provisioning (Ansible)

To configure a machine, whether it be a fresh Server or a new Desktop/Laptop:

1.  **Install Ansible:**
    ```bash
    sudo apt update
    sudo apt install ansible -y
    ```

2.  **Setup Inventory:**
    Copy the example inventory and edit it.
    ```bash
    cp ansible/inventory.example.ini ansible/inventory.ini
    nano ansible/inventory.ini
    ```
    *   For **Server**: Fill in the `[server]` group with IP and User.
    *   For **Desktop**: Enable the `[desktop]` group (usually localhost).

3.  **Run the Playbook:**
    ```bash
    # Run from the project root
    ansible-playbook -i ansible/inventory.ini ansible/site.yml --ask-become-pass
    ```

### 📡 Server Specifics
The `[server]` role handles:
-   **Docker & Nvidia Drivers**: For running local LLMs and containers.
-   **Construct Repo**: Clones the main repo for the stack.
-   **GitHub Runner**: Installs and configures a self-hosted runner.
    *   *Requires `github_runner_token` in `ansible/secrets.yml`.*

### 💻 Desktop Specifics
The `[desktop]` role handles:
-   **Development Tools**: Golang, Node.js, TypeScript.
-   **IDE**: Visual Studio Code with **Gemini Code Assist** extension.

### 🔄 Shared Configuration
Both roles receive:
-   **Shell**: Zsh with Oh-My-Zsh, Powerlevel10k, and Plugins.
-   **Dotfiles**: Deploys a standardized `.zshrc` and `.p10k.zsh` matching the primary layout.
-   **SSH Keys**: Generates an Ed25519 key if missing.

### 🔐 Secrets Management (SOPS)
We use [Mozilla SOPS](https://github.com/getsops/sops) with [Age](https://github.com/FiloSottile/age) encryption to manage secrets.

1.  **Install Tools:**
    The `common` role installs `sops` and `age` automatically.

2.  **Generate Key:**
    ```bash
    age-keygen -o key.txt
    mkdir -p ~/.config/sops/age
    mv key.txt ~/.config/sops/age/keys.txt
    ```

3.  **Edit Secrets:**
    ```bash
    sops ansible/secrets.sops.yml
    ```
    *This opens the file in your default editor, decrypts it for editing, and re-encrypts it on save.*

### 📡 Remote Management
To manage the Server from your Laptop:

1.  **Ensure Connectivity:**
    ```bash
    ssh-copy-id {{ username }}@<server-ip>
    ```

2.  **Run Ansible Remotely:**
    ```bash
    ansible-playbook -i ansible/inventory.ini ansible/site.yml --ask-become-pass --limit server
    ```
    *Use `--limit server` or `--limit desktop` to target specific groups if your inventory contains both.*

### 💻 Multi-Machine Setup (Laptop)
To configure a second machine (like your Laptop) to work with this repo:

1.  **Clone the Repo:**
    ```bash
    git clone https://github.com/Einlanzerous/construct-server.git
    cd construct-server
    ```

2.  **Bootstrap Tools:**
    Run the playbook against localhost to install `age` and `sops`.
    ```bash
    cp ansible/inventory.example.ini ansible/inventory.ini
    # Ensure [desktop] section has localhost uncommented
    ansible-playbook -i ansible/inventory.ini ansible/site.yml --tags common -K
    ```

3.  **Sync Secrets Key:**
    Securely copy the `keys.txt` from your Desktop to your Laptop.
    **On Laptop:**
    ```bash
    mkdir -p ~/.config/sops/age
    # Paste the content of keys.txt from Desktop into:
    nano ~/.config/sops/age/keys.txt
    ```

4.  **Verify:**
    Try decrypting the secrets file:
    ```bash
    sops --decrypt ansible/secrets.sops.yml
    ```

## 🔒 Security Note
This project uses a `.env` file to manage sensitive keys. **Never commit your `.env` file to GitHub.** A `.gitignore` is included to prevent this.
