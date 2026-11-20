# Per-frontend result file

One JSON file per frontend, `<scratchpad>/results/<key>.json`. A real example
is `assets/example-result.json`.

| Field | Type | Notes |
|---|---|---|
| `name` | string | display name |
| `key` | string | Switchyard project key, or the targets-file KEY |
| `path` | string | checkout path plus web dir that was read |
| `stack` | string | framework, bundler, test tool, notable deps |
| `overall` | int 0-100 | |
| `categories` | object | keys `baseline legacy overlays css motion forms a11y perf security`, each int 0-10 or `null` for N/A |
| `strengths` | string[] | with file:line |
| `firefox_risks` | string[] | Chromium-only code, webkit-only CSS, missing fallbacks |
| `fixes` | object[] | `{priority: high\|med\|low, title, detail (file:line, what to change), firefox (support statement), effort: S\|M\|L}` |
| `notes` | string | two-sentence verdict |

No health values, personal figures or private-surface names in any field: the
results feed a shared page and tickets.
