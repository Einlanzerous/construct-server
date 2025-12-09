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

## 🔒 Security Note
This project uses a `.env` file to manage sensitive keys. **Never commit your `.env` file to GitHub.** A `.gitignore` is included to prevent this.
