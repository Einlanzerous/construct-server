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
- **Hosts**: `server`, `desktop`

**Role Breakdown:**
*   **`[server]` Role**:
    *   **Docker & Nvidia Drivers**: For running local LLMs and containers.
    *   **Construct Repo**: Clones the main repo for the stack.
    *   **GitHub Runner**: Installs and configures a self-hosted runner.
*   **`[desktop]` Role**:
    *   **Development Tools**: Golang, Node.js, TypeScript.
    *   **IDE**: Visual Studio Code with **Gemini Code Assist** extension.
*   **Shared Config**:
    *   **Shell**: Zsh with Oh-My-Zsh, Powerlevel10k, and Plugins.
    *   **Dotfiles**: Deploys a standardized `.zshrc` and `.p10k.zsh`.
    *   **SSH Keys**: Generates an Ed25519 key if missing.

### 2. `work.yml` (Work Laptop)
A specialized playbook for the work laptop (Genesys environment).
- **Hosts**: `work`
- **Roles**: `common`, `desktop`

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
