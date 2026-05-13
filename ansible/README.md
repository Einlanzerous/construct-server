# Ansible Deployment

This directory contains the Ansible playbooks for managing the various environments in the **Construct Server** project.

## 🚀 Quick Start

1.  **Install Ansible:**
    ```bash
    sudo apt update
    sudo apt install ansible -y
    ```

2.  **Setup Inventory:**
    Copy the example inventory and edit it.
    ```bash
    cp inventory.example.ini inventory.ini
    nano inventory.ini
    ```
    *   For **Server**: Fill in the `[server]` group with IP and User.
    *   For **Desktop**: Enable the `[desktop]` group (usually localhost).

3.  **Run the Playbook:**
    ```bash
    # Run from this directory
    ansible-playbook -i inventory.ini site.yml --ask-become-pass
    ```

## 📖 Playbooks

### 1. `site.yml` (Server & Desktop)
The main playbook for managing personal infrastructure.
- **Hosts**: `server`, `desktop` (desktop inherits the `common` play via `hosts: all`)

**Role Breakdown:**
*   **`common` (all hosts)**:
    *   **Shell**: Zsh with Oh-My-Zsh, Powerlevel10k, autosuggestions/syntax-highlighting/autocomplete.
    *   **Dotfiles**: Deploys a standardized `.zshrc` and `.p10k.zsh`.
    *   **SSH Keys**: Generates an Ed25519 key if missing.
    *   **Secrets tooling**: `age`, `sops`.
    *   **Language runtimes & version managers**:
        *   Node.js via [`fnm`](https://github.com/Schniz/fnm) (Node 24 LTS as default).
        *   Go via [`g`](https://github.com/stefanmaric/g).
        *   Python via [`uv`](https://docs.astral.sh/uv/) (Astral).
        *   [`bun`](https://bun.sh) (JS runtime / package manager).
    *   **Global npm CLIs**: TypeScript, [`@google/gemini-cli`](https://github.com/google-gemini/gemini-cli), [`@anthropic-ai/claude-code`](https://docs.claude.com/claude-code).
*   **`server` (server host only)**:
    *   **Docker & GPU drivers**: For running local LLMs and containers.
    *   **Construct Repo**: Clones the main repo for the stack.
*   **`tailscale`, `github_runner`, `sunshine`**: server-only roles for VPN mesh, CI runner, and game streaming respectively.

### 2. `work.yml` (Work Laptop)
A specialized playbook for the work laptop (Genesys environment).
- **Hosts**: `work`
- **Roles**: `common`

**Features:**
*   **Directory**: Creates `~/genesys` directory.
*   **Git**: Configures conditional git settings for work emails (only inside `~/genesys`).
*   **Tools**: Installs Java, Python, and Genesys DevOps CLI + dependencies.
*   **Repos**: Clones specific work repositories.

**Usage:**
```bash
# Deploy to Work Laptop (Local)
ansible-playbook -i work_inventory.ini work.yml
```

## 🔐 Secrets Management (SOPS)
We use [Mozilla SOPS](https://github.com/getsops/sops) with [Age](https://github.com/FiloSottile/age) encryption.

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
    sops secrets.sops.yml
    ```
    *This opens the file in your default editor, decrypts it for editing, and re-encrypts it on save.*

## 💻 Multi-Machine Setup
To configure a secondary machine (like a Laptop) to work with this repo:

1.  **Clone the Repo** and cd into `ansible`.
2.  **Bootstrap:**
    Run the playbook against localhost to install `age` and `sops`.
    ```bash
    ansible-playbook -i inventory.ini site.yml --tags common -K
    ```
3.  **Sync Secrets Key:**
    Securely copy `keys.txt` from your Desktop to your Laptop's `~/.config/sops/age/keys.txt`.
4.  **Verify:**
    `sops --decrypt secrets.sops.yml`

## 📡 Remote Management
To manage the Server from your Laptop:

1.  **Ensure Connectivity:**
    ```bash
    ssh-copy-id {{ username }}@<server-ip>
    ```
2.  **Run Ansible Remotely:**
    ```bash
    ansible-playbook -i inventory.ini site.yml --ask-become-pass --limit server
    ```
