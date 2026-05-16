#!/usr/bin/env bash
# Bakeoff: Claude Code vs multiple Gemma 4 variants via Ollama.
#
# Usage:
#   ./run.sh                                    # all prompts, all default models
#   ./run.sh 03 07                              # only prompts 03 and 07
#   GEN_MODELS=gemma4:31b,gemma4:e4b ./run.sh   # override the gemma list
#   CLAUDE_MODEL=opus ./run.sh                  # pin claude model
#   SKIP_CLAUDE=1 ./run.sh                      # local generators only (e.g. adding to an existing run)
#
# Generators:
#   - claude (via `claude -p --output-format json`, tools disabled — see README)
#   - each model in GEN_MODELS, via the Ollama HTTP API
#
# Captures per-generation: wall-clock seconds, input tokens, output tokens, bytes,
# and (claude only) total_cost_usd. Writes to results/<timestamp>/.

set -euo pipefail
shopt -s nullglob

cd "$(dirname "$0")"

GEN_MODELS="${GEN_MODELS:-gemma4:31b,gemma4:e4b}"
OLLAMA_URL="${OLLAMA_URL:-http://localhost:11434/api/generate}"

CLAUDE_FLAGS=(--disallowedTools "Bash,Read,Write,Edit,Glob,Grep,WebFetch,WebSearch,Agent,NotebookEdit" --output-format json)
if [[ -n "${CLAUDE_MODEL:-}" ]]; then
  CLAUDE_FLAGS+=(--model "$CLAUDE_MODEL")
fi

RESULTS_DIR="results/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RESULTS_DIR"

prompts=()
if [[ $# -gt 0 ]]; then
  for arg in "$@"; do
    matches=(prompts/${arg}-*.md)
    if [[ ${#matches[@]} -gt 0 ]]; then
      prompts+=("${matches[0]}")
    else
      echo "✗ no prompt matching '$arg' (expected prompts/${arg}-*.md)" >&2
    fi
  done
else
  prompts=(prompts/*.md)
fi

if [[ ${#prompts[@]} -eq 0 ]]; then
  echo "no prompts to run" >&2
  exit 1
fi

IFS=',' read -ra MODELS_ARR <<< "$GEN_MODELS"

summary="$RESULTS_DIR/summary.tsv"
printf "prompt\tgenerator\tseconds\tinput_tokens\toutput_tokens\tbytes\tcost_usd\n" > "$summary"

slugify_model() {
  echo "$1" | tr ':/' '__'
}

run_claude() {
  local prompt="$1" out_file="$2"
  local start end secs raw
  start=$(date +%s.%N)
  raw=$(echo "$prompt" | claude -p "${CLAUDE_FLAGS[@]}" 2>/dev/null) || true
  end=$(date +%s.%N)
  secs=$(awk -v s="$start" -v e="$end" 'BEGIN { printf "%.2f", e-s }')

  local text input_tok output_tok cache_creation cache_read cost
  text=$(jq -r '.result // empty' <<<"$raw")
  input_tok=$(jq -r '.usage.input_tokens // 0' <<<"$raw")
  output_tok=$(jq -r '.usage.output_tokens // 0' <<<"$raw")
  cache_creation=$(jq -r '.usage.cache_creation_input_tokens // 0' <<<"$raw")
  cache_read=$(jq -r '.usage.cache_read_input_tokens // 0' <<<"$raw")
  cost=$(jq -r '.total_cost_usd // 0' <<<"$raw")

  printf "%s" "$text" > "$out_file"
  # Effective input tokens for accounting = user input + cache creation (cold tax)
  local eff_in=$((input_tok + cache_creation + cache_read))
  printf "%s\t%s\t%s\t%s\n" "$secs" "$eff_in" "$output_tok" "$cost"
}

run_ollama() {
  local prompt="$1" model="$2" out_file="$3"
  local body start end secs raw text input_tok output_tok
  body=$(jq -nc --arg model "$model" --arg prompt "$prompt" \
    '{model:$model, prompt:$prompt, stream:false}')
  start=$(date +%s.%N)
  raw=$(curl -sS "$OLLAMA_URL" -d "$body") || true
  end=$(date +%s.%N)
  secs=$(awk -v s="$start" -v e="$end" 'BEGIN { printf "%.2f", e-s }')

  text=$(jq -r '.response // empty' <<<"$raw")
  input_tok=$(jq -r '.prompt_eval_count // 0' <<<"$raw")
  output_tok=$(jq -r '.eval_count // 0' <<<"$raw")
  printf "%s" "$text" > "$out_file"
  printf "%s\t%s\t%s\n" "$secs" "$input_tok" "$output_tok"
}

for prompt_file in "${prompts[@]}"; do
  name=$(basename "$prompt_file" .md)
  prompt=$(cat "$prompt_file")
  echo
  echo "▶ $name"

  # --- Claude (skippable) ---
  if [[ -z "${SKIP_CLAUDE:-}" ]]; then
    out="$RESULTS_DIR/${name}.claude.md"
    echo "  → claude..."
    read secs in_tok out_tok cost < <(run_claude "$prompt" "$out")
    bytes=$(wc -c < "$out")
    printf "%s\tclaude\t%s\t%s\t%s\t%s\t%s\n" "$name" "$secs" "$in_tok" "$out_tok" "$bytes" "$cost" >> "$summary"
    echo "    ✓ ${secs}s | in=${in_tok} out=${out_tok} | ${bytes}B | \$${cost}"
  else
    echo "  → claude... SKIPPED (SKIP_CLAUDE set)"
  fi

  # --- Each Gemma ---
  for model in "${MODELS_ARR[@]}"; do
    slug=$(slugify_model "$model")
    out="$RESULTS_DIR/${name}.${slug}.md"
    echo "  → $model..."
    read secs in_tok out_tok < <(run_ollama "$prompt" "$model" "$out")
    bytes=$(wc -c < "$out")
    printf "%s\t%s\t%s\t%s\t%s\t%s\t0\n" "$name" "$slug" "$secs" "$in_tok" "$out_tok" "$bytes" >> "$summary"
    echo "    ✓ ${secs}s | in=${in_tok} out=${out_tok} | ${bytes}B"
  done
done

echo
echo "═══ Summary ═══"
column -t -s $'\t' "$summary"
echo
echo "Results: $RESULTS_DIR"
