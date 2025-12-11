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

## 🖥️ Server Provisioning (Ansible)

To configure a fresh Ubuntu server with all necessary dependencies (Docker, Nvidia Drivers, Zsh upgrades):

1.  **Install Ansible:**
    ```bash
    sudo apt update
    sudo apt install ansible -y
    ```

2.  **Run the Playbook:**
    ```bash
    # Run from the project root
    ansible-playbook -i ansible/inventory.ini ansible/setup.yml --ask-become-pass
    ```
    *Note: Ensure your `ansible/inventory.ini` points to the correct target IP and user.*

### 📡 Remote Management (e.g., from Laptop)

To manage **Imperial Construct** from another machine (like **Imperial Raven**):

1.  **Ensure Connectivity:**
    Make sure you can SSH into the server from your laptop:
    ```bash
    ssh {{ username }}@<server-ip>
    ```

2.  **Setup SSH Keys (Passwordless Access):**
    Ansible works best with SSH keys. If you haven't already, copy your laptop's public key to the server:
    ```bash
    ssh-copy-id {{ username }}@<server-ip>
    ```

3.  **Run Ansible Remotely:**
    From your laptop (assuming you have this repo cloned):
    ```bash
    # Update inventory.ini to match the server's specific IP address first!
    # Copy the example if you haven't already
    cp ansible/inventory.example.ini ansible/inventory.ini
    nano ansible/inventory.ini
    
    # Run the playbook
    ansible-playbook -i ansible/inventory.ini ansible/setup.yml --ask-become-pass
    ```

## 🔒 Security Note
This project uses a `.env` file to manage sensitive keys. **Never commit your `.env` file to GitHub.** A `.gitignore` is included to prevent this.
