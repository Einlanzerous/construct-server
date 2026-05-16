#!/usr/bin/env bash
# Have gemma4:26b grade every response in a results directory, BATCHED PER PROMPT.
# One call per prompt: 26b sees the task + all 4 answers and emits grades for each.
# 4x speedup over per-answer calls; matches how a human reviewer naturally compares.
#
# Usage:
#   ./grade-gemma.sh results/<timestamp>
#
# Writes grades-gemma.tsv into the same directory:
#   prompt    generator    grade    rationale

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <results-dir>" >&2
  exit 1
fi

cd "$(dirname "$0")"

RESULTS_DIR="$1"
JUDGE_MODEL="${JUDGE_MODEL:-gemma4:26b}"
OLLAMA_URL="${OLLAMA_URL:-http://localhost:11434/api/chat}"

if [[ ! -d "$RESULTS_DIR" ]]; then
  echo "no such dir: $RESULTS_DIR" >&2
  exit 1
fi

OUT="$RESULTS_DIR/grades-gemma.tsv"
RAW_DIR="$RESULTS_DIR/judge-raw"
mkdir -p "$RAW_DIR"
printf "prompt\tgenerator\tgrade\trationale\n" > "$OUT"

# The four generator slugs we expect, in fixed order
GENS=(claude gemma4_31b gemma4_26b gemma4_e4b)

# Discover prompt names from claude responses
prompt_names=()
for f in "$RESULTS_DIR"/*.claude.md; do
  [[ -f "$f" ]] || continue
  base=$(basename "$f" .claude.md)
  prompt_names+=("$base")
done

if [[ ${#prompt_names[@]} -eq 0 ]]; then
  echo "no responses found in $RESULTS_DIR" >&2
  exit 1
fi

for name in "${prompt_names[@]}"; do
  prompt_file="prompts/${name}.md"
  if [[ ! -f "$prompt_file" ]]; then
    echo "✗ missing prompt file $prompt_file" >&2
    continue
  fi
  task=$(cat "$prompt_file")

  echo
  echo "▶ judging $name (batched)"

  # Build the full message: rubric + task + each answer labeled A1..A4
  judge_prompt=$(
    cat <<'EOF'
You are grading four independent answers to the same coding task. Be a tough, fair
senior engineer. Focus on:
- Correctness: does the answer solve the actual problem, with no real bugs?
- Completeness: does it cover every explicit requirement in the task?
- Code quality: idiomatic, typed, no dead code, no obvious smells.
- Clarity: well-organized, no rambling, no unnecessary boilerplate.

Grade each answer absolutely (A, B, C, D, or F) — not relative to the others.
A great answer is an A regardless of whether the others are also great. A buggy
answer is a D or F regardless of whether the others are also buggy.

Reply EXACTLY in this format, no preamble, no markdown:
A1_GRADE: <letter>
A1_RATIONALE: <2-3 sentences, concrete>
A2_GRADE: <letter>
A2_RATIONALE: <2-3 sentences, concrete>
A3_GRADE: <letter>
A3_RATIONALE: <2-3 sentences, concrete>
A4_GRADE: <letter>
A4_RATIONALE: <2-3 sentences, concrete>
EOF
  )
  judge_prompt+=$'\n\n---\nTASK:\n'"$task"$'\n\n'

  for i in "${!GENS[@]}"; do
    g="${GENS[$i]}"
    n=$((i + 1))
    resp_file="$RESULTS_DIR/${name}.${g}.md"
    if [[ ! -f "$resp_file" ]]; then
      echo "    ! missing $resp_file" >&2
      continue
    fi
    judge_prompt+=$'\n---\nANSWER A'"${n}"':\n'"$(cat "$resp_file")"$'\n'
  done

  body=$(jq -nc --arg model "$JUDGE_MODEL" --arg content "$judge_prompt" \
    '{model:$model, messages:[{role:"user", content:$content}], stream:false, think:false, options:{temperature:0.2, num_ctx:32768, num_predict:2000}}')

  start=$(date +%s.%N)
  raw=$(curl -sS "$OLLAMA_URL" -d "$body") || true
  end=$(date +%s.%N)
  secs=$(awk -v s="$start" -v e="$end" 'BEGIN { printf "%.1f", e-s }')

  judgement=$(jq -r '.message.content // empty' <<<"$raw")
  printf "%s" "$judgement" > "$RAW_DIR/${name}.judge.txt"
  echo "    ⌛ ${secs}s"

  # Parse out each A<i>_GRADE / A<i>_RATIONALE
  for i in "${!GENS[@]}"; do
    g="${GENS[$i]}"
    n=$((i + 1))
    grade=$(printf "%s" "$judgement" | grep -m1 -oE "A${n}_GRADE:[[:space:]]*[A-F]" | grep -oE '[A-F]$' || echo "?")
    rationale=$(printf "%s" "$judgement" | awk -v key="A${n}_RATIONALE:" -v next1="A$((n+1))_GRADE:" '
      $0 ~ key { flag=1; sub(".*" key "[[:space:]]*",""); print; next }
      flag && $0 ~ next1 { flag=0; exit }
      flag { print }
    ' | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g; s/\t/ /g; s/[[:space:]]*$//')
    if [[ -z "$rationale" ]]; then rationale="(no rationale parsed)"; fi
    printf "%s\t%s\t%s\t%s\n" "$name" "$g" "$grade" "$rationale" >> "$OUT"
    echo "    ✓ $g: $grade"
  done
done

echo
echo "═══ Gemma grades (batched) ═══"
column -t -s $'\t' "$OUT"
echo
echo "Wrote: $OUT"
echo "Raw judge outputs: $RAW_DIR/"
