# Software Landing Page Generator

A simple Go-based tool to generate a static HTML landing page for essential software downloads. This is useful for quickly setting up a new workstation with links to preferred tools.

## 🚀 Features
- **Configurable**: Define software list, icons, and links in `config.yml`.
- **Single Static File**: Generates a self-contained `index.html` with embedded CSS.
- **Clean Design**: Uses a card-based layout inspired by modern UI frameworks.

## 🛠️ Usage

### 1. Configure
Edit `config.yml` to add or remove software.
```yaml
software:
  - name: Cursor
    icon: "🖱️"
    link: "https://cursor.sh/"
```

### 2. Generate
Run the Go script to build the page.
```bash
# From this directory
go run main.go
```

### 3. Open
Open the generated `index.html` in your browser.
```bash
# WSL
explorer.exe index.html

# Linux
xdg-open index.html
```

## 📋 Requirements
- **Go**: 1.18+ (Verified with 1.22)
- **Dependencies**: `gopkg.in/yaml.v3` (Run `go mod tidy` if missing)
