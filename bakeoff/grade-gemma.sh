#!/usr/bin/env bash
# Have a local model grade every response in a results directory, BATCHED PER PROMPT.
# One call per prompt: the judge sees the task + all answers and emits grades for each.
#
# Generators are auto-discovered from files in the results dir (any *.<slug>.md
# where <slug> is not the judge output). Output file is named per the judge model
# slug, so multiple judges can coexist without clobbering each other.
#
# Usage:
#   ./grade-gemma.sh results/<timestamp>                   # default judge gemma4:26b
#   JUDGE_MODEL=gpt-oss:20b ./grade-gemma.sh results/...   # swap judge model
#
# Writes grades-<judge-slug>.tsv into the same directory:
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

# Slug for the judge: gemma4:26b -> gemma4_26b, gpt-oss:20b -> gpt-oss_20b
judge_slug=$(echo "$JUDGE_MODEL" | tr ':/' '__')
# Friendly shortname for the output filename: drop everything after first underscore for gemma.
# gemma4_26b -> gemma; gpt-oss_20b -> gpt-oss
out_short="${judge_slug%%_*}"
# Preserve the legacy filename for gemma-family judges (backwards compat with the original report)
if [[ "$out_short" == "gemma4" ]]; then
  out_short="gemma"
fi

OUT="$RESULTS_DIR/grades-${out_short}.tsv"
RAW_DIR="$RESULTS_DIR/judge-raw-${out_short}"
mkdir -p "$RAW_DIR"
printf "prompt\tgenerator\tgrade\trationale\n" > "$OUT"

# Discover generators by globbing all .md files for the first prompt's claude pair, then taking
# every *.SLUG.md that shares the prompt prefix.
first_prompt=""
for f in "$RESULTS_DIR"/*.claude.md; do
  [[ -f "$f" ]] || continue
  first_prompt=$(basename "$f" .claude.md)
  break
done
if [[ -z "$first_prompt" ]]; then
  echo "no *.claude.md found in $RESULTS_DIR" >&2
  exit 1
fi

GENS=()
for f in "$RESULTS_DIR/${first_prompt}".*.md; do
  [[ -f "$f" ]] || continue
  slug=$(basename "$f" .md)
  slug="${slug#${first_prompt}.}"
  GENS+=("$slug")
done

if [[ ${#GENS[@]} -eq 0 ]]; then
  echo "no generator outputs discovered" >&2
  exit 1
fi
echo "→ generators: ${GENS[*]}"
echo "→ judge: $JUDGE_MODEL"
echo "→ output: $OUT"

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

  # Build the full message: rubric + task + each answer labeled A1..An
  n_answers=${#GENS[@]}
  format_block=""
  for ((i=1; i<=n_answers; i++)); do
    format_block+="A${i}_GRADE: <letter>"$'\n'
    format_block+="A${i}_RATIONALE: <2-3 sentences, concrete>"$'\n'
  done
  judge_prompt=$(
    cat <<EOF
You are grading ${n_answers} independent answers to the same coding task. Be a tough, fair
senior engineer. Focus on:
- Correctness: does the answer solve the actual problem, with no real bugs?
- Completeness: does it cover every explicit requirement in the task?
- Code quality: idiomatic, typed, no dead code, no obvious smells.
- Clarity: well-organized, no rambling, no unnecessary boilerplate.

Grade each answer absolutely (A, B, C, D, or F) — not relative to the others.
A great answer is an A regardless of whether the others are also great. A buggy
answer is a D or F regardless of whether the others are also buggy.

Reply EXACTLY in this format, no preamble, no markdown:
${format_block}
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

  # Different reasoning-mode models need different knobs to suppress hidden CoT.
  # gemma4 family: `think: false` works.
  # gpt-oss family: `think: false` is ignored; pass `reasoning_effort: "low"` in options
  #                 AND a `Reasoning: low` system message. Even then it does *some*
  #                 reasoning; size num_predict accordingly.
  case "$JUDGE_MODEL" in
    gpt-oss*)
      body=$(jq -nc --arg model "$JUDGE_MODEL" --arg content "$judge_prompt" \
        '{model:$model,
          messages:[{role:"system", content:"Reasoning: low"},
                    {role:"user",   content:$content}],
          stream:false,
          options:{temperature:0.2, num_ctx:32768, num_predict:4000, reasoning_effort:"low"}}')
      ;;
    *)
      body=$(jq -nc --arg model "$JUDGE_MODEL" --arg content "$judge_prompt" \
        '{model:$model, messages:[{role:"user", content:$content}], stream:false, think:false, options:{temperature:0.2, num_ctx:32768, num_predict:2000}}')
      ;;
  esac

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
