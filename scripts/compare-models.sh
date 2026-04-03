#!/usr/bin/env bash
# compare-models.sh — Send identical prompts to multiple Ollama models and compare responses
# Usage: ./scripts/compare-models.sh [model1 model2 ...]
# Default: compares current gemma3 models against new gemma4 models

set -euo pipefail

OLLAMA_URL="${OLLAMA_URL:-http://localhost:11434}"

# Default models to compare
if [ $# -gt 0 ]; then
  MODELS=("$@")
else
  MODELS=("gemma3:4b" "gemma4:e4b" "gemma3:12b" "gemma4:26b")
fi

# Test prompts covering different capabilities
declare -A PROMPTS
PROMPTS[coding]="Write a Python function that finds the longest palindromic substring in a given string. Include type hints and a brief docstring."
PROMPTS[reasoning]="A farmer has 17 sheep. All but 9 run away. How many sheep does the farmer have left? Explain your reasoning step by step."
PROMPTS[summarization]="Explain the difference between a mutex and a semaphore in concurrent programming. Be concise but thorough."

SEPARATOR="$(printf '=%.0s' {1..80})"
SUBSEP="$(printf -- '-%.0s' {1..60})"

echo "$SEPARATOR"
echo "  MODEL COMPARISON — $(date '+%Y-%m-%d %H:%M:%S')"
echo "  Ollama: $OLLAMA_URL"
echo "  Models: ${MODELS[*]}"
echo "$SEPARATOR"
echo

# Check which models are available
echo "Checking model availability..."
AVAILABLE_MODELS=()
for model in "${MODELS[@]}"; do
  if curl -sf "$OLLAMA_URL/api/show" -d "{\"name\":\"$model\"}" > /dev/null 2>&1; then
    echo "  [OK] $model"
    AVAILABLE_MODELS+=("$model")
  else
    echo "  [SKIP] $model — not found"
  fi
done
echo

if [ ${#AVAILABLE_MODELS[@]} -lt 2 ]; then
  echo "ERROR: Need at least 2 available models to compare. Found ${#AVAILABLE_MODELS[@]}."
  exit 1
fi

# Run comparisons
for category in "${!PROMPTS[@]}"; do
  prompt="${PROMPTS[$category]}"

  echo "$SEPARATOR"
  echo "  CATEGORY: $category"
  echo "  PROMPT: $prompt"
  echo "$SEPARATOR"
  echo

  for model in "${AVAILABLE_MODELS[@]}"; do
    echo "$SUBSEP"
    echo "  MODEL: $model"
    echo "$SUBSEP"

    start_time=$(date +%s%N)

    response=$(curl -sf "$OLLAMA_URL/api/generate" \
      -d "$(jq -n \
        --arg model "$model" \
        --arg prompt "$prompt" \
        '{model: $model, prompt: $prompt, stream: false, options: {num_predict: 512, temperature: 0.7}}'
      )" 2>&1) || {
        echo "  ERROR: Failed to query $model"
        echo
        continue
      }

    end_time=$(date +%s%N)
    elapsed_ms=$(( (end_time - start_time) / 1000000 ))

    # Extract metrics
    answer=$(echo "$response" | jq -r '.response // "no response"')
    total_duration=$(echo "$response" | jq -r '.total_duration // 0')
    eval_count=$(echo "$response" | jq -r '.eval_count // 0')
    eval_duration=$(echo "$response" | jq -r '.eval_duration // 0')

    # Calculate tokens/sec
    if [ "$eval_duration" -gt 0 ] 2>/dev/null; then
      tps=$(echo "scale=1; $eval_count / ($eval_duration / 1000000000)" | bc 2>/dev/null || echo "n/a")
    else
      tps="n/a"
    fi

    total_sec=$(echo "scale=2; ${total_duration:-0} / 1000000000" | bc 2>/dev/null || echo "n/a")

    echo
    echo "$answer"
    echo
    echo "  --- Stats: ${total_sec}s total | ${eval_count} tokens | ${tps} tok/s ---"
    echo
  done
  echo
done

echo "$SEPARATOR"
echo "  COMPARISON COMPLETE"
echo "$SEPARATOR"
