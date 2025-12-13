# Imperial Construct 🏗️

Welcome to **Imperial Construct**, a localized Home Operations Center designed to provide AI services, observability, and storage capabilities in a secure, self-hosted environment.

## 🚀 Current Stack

The following services are currently active:

### 🧠 Artificial Intelligence
-   **[Ollama](https://ollama.com/)**: Backend for running large language models (LLMs) like Gemma 3 and Llama 3 locally.
-   **[Open WebUI](https://docs.openwebui.com/)**: A beautiful, feature-rich interface for interacting with your local LLMs (similar to ChatGPT).

### 📊 Observability (Monitoring)
-   **[Datadog Agent](https://www.datadoghq.com/)**: Cloud-based infrastructure monitoring for metrics, traces, and logs.
-   **[Dozzle](https://dozzle.dev/)**: Real-time log viewer for Docker containers.

### 🏠 Dashboard
-   **[Homer](https://github.com/bastienwirtz/homer)**: A static homepage to access all services from a single dashboard.

## 🗺️ Roadmap

-   [ ] **File Sharing**: Implementation of **Copyparty** for lightweight file server capabilities (drag-and-drop uploads, media streaming).
-   [ ] **Server Migration**: Transitioning this stack from a local workstation to a dedicated Linux server.

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

4.  **Access the Dashboard:**
    Navigate to `http://localhost` in your browser.

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

### 💻 Desktop Specifics
The `[desktop]` role handles:
-   **Development Tools**: Golang, Node.js, TypeScript.
-   **IDE**: Visual Studio Code with **Gemini Code Assist** extension.

### 🔄 Shared Configuration
Both roles receive:
-   **Shell**: Zsh with Oh-My-Zsh, Powerlevel10k, and Plugins.
-   **Dotfiles**: Deploys a standardized `.zshrc` and `.p10k.zsh` matching the primary layout.
-   **SSH Keys**: Generates an Ed25519 key if missing.

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

## 🔒 Security Note
This project uses a `.env` file to manage sensitive keys. **Never commit your `.env` file to GitHub.** A `.gitignore` is included to prevent this.
