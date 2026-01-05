package main

import (
	"html/template"
	"log"
	"os"

	"gopkg.in/yaml.v3"
)

type SoftwareItem struct {
	Name string `yaml:"name"`
	Icon string `yaml:"icon"`
	Link string `yaml:"link"`
}

type Config struct {
	Software []SoftwareItem `yaml:"software"`
}

const htmlTemplate = `
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Workstation Setup</title>
    <style>
        :root {
            --bg-color: #f3f4f6;
            --card-bg: #ffffff;
            --text-color: #1f2937;
            --secondary-text: #6b7280;
            --accent-color: #4f46e5;
            --hover-shadow: 0 10px 15px -3px rgba(0, 0, 0, 0.1), 0 4px 6px -2px rgba(0, 0, 0, 0.05);
            --shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.1), 0 2px 4px -1px rgba(0, 0, 0, 0.06);
        }

        body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
            background-color: var(--bg-color);
            color: var(--text-color);
            margin: 0;
            padding: 40px;
            display: flex;
            flex-direction: column;
            align-items: center;
        }

        header {
            margin-bottom: 40px;
            text-align: center;
        }

        h1 {
            font-size: 2.5rem;
            font-weight: 800;
            margin-bottom: 10px;
            color: #111827;
        }

        p.subtitle {
            font-size: 1.125rem;
            color: var(--secondary-text);
        }

        .grid {
            display: grid;
            grid-template-columns: repeat(auto-fill, minmax(250px, 1fr));
            gap: 24px;
            width: 100%;
            max-width: 1000px;
        }

        .card {
            background-color: var(--card-bg);
            border-radius: 12px;
            padding: 24px;
            box-shadow: var(--shadow);
            transition: all 0.3s ease;
            text-decoration: none;
            color: inherit;
            display: flex;
            flex-direction: column;
            align-items: center;
            justify-content: center;
            text-align: center;
            border: 1px solid transparent;
        }

        .card:hover {
            transform: translateY(-4px);
            box-shadow: var(--hover-shadow);
            border-color: var(--accent-color);
        }

        .icon {
            font-size: 3rem;
            margin-bottom: 16px;
        }

        .name {
            font-size: 1.25rem;
            font-weight: 600;
            color: var(--text-color);
        }

        .action {
            margin-top: 12px;
            font-size: 0.875rem;
            color: var(--accent-color);
            font-weight: 500;
        }

        @media (prefers-color-scheme: dark) {
            :root {
                --bg-color: #111827;
                --card-bg: #1f2937;
                --text-color: #f9fafb;
                --secondary-text: #9ca3af;
                --shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.5);
            }
            h1 { color: #f9fafb; }
        }
    </style>
</head>
<body>
    <header>
        <h1>Workstation Software</h1>
        <p class="subtitle">Essential tools for the new setup</p>
    </header>

    <div class="grid">
        {{range .Software}}
        <a href="{{.Link}}" target="_blank" class="card">
            <span class="icon">{{.Icon}}</span>
            <span class="name">{{.Name}}</span>
            <span class="action">Get Installer &rarr;</span>
        </a>
        {{end}}
    </div>
</body>
</html>
`

func main() {
	// Read config
	data, err := os.ReadFile("config.yml")
	if err != nil {
		log.Fatalf("Error reading config file: %v", err)
	}

	// Parse YAML
	var config Config
	err = yaml.Unmarshal(data, &config)
	if err != nil {
		log.Fatalf("Error parsing YAML: %v", err)
	}

	// Create Output File
	f, err := os.Create("index.html")
	if err != nil {
		log.Fatalf("Error creating output file: %v", err)
	}
	defer f.Close()

	// Parse and Execute Template
	tmpl, err := template.New("index").Parse(htmlTemplate)
	if err != nil {
		log.Fatalf("Error parsing template: %v", err)
	}

	err = tmpl.Execute(f, config)
	if err != nil {
		log.Fatalf("Error executing template: %v", err)
	}

	log.Println("Successfully generated index.html")
}
