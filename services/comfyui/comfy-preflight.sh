#!/usr/bin/env bash
# comfy-preflight.sh — can this box take a generation run right now? (IDEA-52)
#
# WHY THIS EXISTS. Driving a FLUX.1 Kontext run put the host at 414 MB available
# and the global kernel OOM killer fired three times: twice on ComfyUI and ONCE ON
# OLLAMA's llama-server, a prod service with nothing to do with it. The global
# killer picks by oom_score across the whole machine, so the process that dies is
# not the process at fault — every container on the box is a candidate.
#
# `mem_limit` in the compose file is the structural half and bounds the damage to
# this container. This is the operational half: it says NO BEFORE you start, and
# `--free` reclaims the GPU rather than making you go and find what is holding it.
#
# The constraint that actually binds here is SYSTEM RAM, not VRAM. The card has
# 32 GiB and the host has 31 GiB, and ComfyUI stages weights through the latter —
# so a model that fits the card can still kill the box. Both are checked, RAM
# first, because that is the one that surprised us.
#
# Exit codes:
#   0  enough headroom to run
#   1  not enough — the reason, and what is holding it, are printed
#   2  usage / missing dependency
set -uo pipefail

# Measured, not chosen. A successful Kontext fp8 run (12 GB model + 5 GB t5xxl)
# peaks ~15 GB above a quiet baseline; the two OOM kills recorded 12.3 GB and
# 16.2 GB anon-rss. A smaller model needs less — override for those.
NEED_RAM_GB="${NEED_RAM_GB:-16}"
NEED_VRAM_GB="${NEED_VRAM_GB:-14}"
FREE=0
[ "${1:-}" = "--free" ] && FREE=1

say() { printf '%s\n' "$*"; }
ok()  { printf '  ok    %s\n' "$*"; }
bad() { printf '  FAIL  %s\n' "$*"; }
note(){ printf '  note  %s\n' "$*"; }

command -v docker >/dev/null 2>&1 || { say "ERROR: docker not on PATH"; exit 2; }

gb() { awk -v k="$1" 'BEGIN{printf "%.1f", k/1048576}'; }

# ── Reclaim first, so the numbers below reflect the post-free state ───────────
if [ "$FREE" -eq 1 ]; then
  say "Freeing the GPU"
  resident="$(curl -sf --max-time 5 http://127.0.0.1:11434/api/ps 2>/dev/null \
    | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit()
for m in d.get("models",[]): print(m["name"])' 2>/dev/null)"
  if [ -n "$resident" ]; then
    while IFS= read -r m; do
      [ -z "$m" ] && continue
      # keep_alive 0 asks ollama to unload immediately. It is ollama's own
      # mechanism — nothing here kills a process, which is the whole point:
      # SIGKILLing llama-server is what we are trying to stop happening.
      curl -sf --max-time 20 http://127.0.0.1:11434/api/generate \
        -d "{\"model\":\"$m\",\"keep_alive\":0}" >/dev/null 2>&1 \
        && say "  unloaded $m" || say "  could not unload $m"
    done <<< "$resident"
    sleep 4
    # Did it STAY unloaded? `keep_alive: 0` asks ollama to drop the model after the
    # current request; it does not stop the NEXT one loading it straight back. If
    # something is actively using ollama the model returns within seconds, and
    # reporting "unloaded" then would be a lie that sends you into a run the box
    # cannot take. Seen immediately: gemma4:31b was back, 19.4 GiB, before this
    # check had finished.
    back="$(curl -sf --max-time 5 http://127.0.0.1:11434/api/ps 2>/dev/null \
      | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit()
for m in d.get("models",[]):
    print(f"{m[\"name\"]} ({m.get(\"size_vram\",0)/1073741824:.1f} GiB, held until {m.get(\"expires_at\",\"?\")[11:19]})")' 2>/dev/null)"
    if [ -n "$back" ]; then
      say "  RELOADED already — something is actively using ollama:"
      printf '    %s\n' "$back"
      say "  Unloading again will not help. Either wait, or stop what is calling it."
    fi
  else
    say "  ollama holds no resident model"
  fi
  say
fi

FAIL=0

# ── System RAM ───────────────────────────────────────────────────────────────
say "System RAM"
avail_kb="$(awk '/MemAvailable/{print $2}' /proc/meminfo)"
total_kb="$(awk '/MemTotal/{print $2}' /proc/meminfo)"
swap_t="$(awk '/SwapTotal/{print $2}' /proc/meminfo)"
swap_f="$(awk '/SwapFree/{print $2}' /proc/meminfo)"
avail_gb="$(gb "$avail_kb")"
say "        $(gb "$avail_kb") GiB available of $(gb "$total_kb") GiB"
if awk -v a="$avail_gb" -v n="$NEED_RAM_GB" 'BEGIN{exit !(a>=n)}'; then
  ok "at or above the ${NEED_RAM_GB} GiB a Kontext fp8 run needs"
else
  bad "only ${avail_gb} GiB available; a Kontext fp8 run needs ~${NEED_RAM_GB} GiB"
  FAIL=1
fi
if [ "${swap_t:-0}" -gt 0 ]; then
  used_pct=$(( (swap_t - swap_f) * 100 / swap_t ))
  [ "$used_pct" -ge 75 ] \
    && note "swap is ${used_pct}% used — the box is already under pressure, and it was at ~90% when the OOM killer fired" \
    || ok "swap ${used_pct}% used"
fi
say

# ── VRAM ─────────────────────────────────────────────────────────────────────
say "GPU"
if command -v rocm-smi >/dev/null 2>&1; then
  read -r vt vu < <(rocm-smi --showmeminfo vram 2>/dev/null \
    | awk '/VRAM Total Memory/{t=$NF} /VRAM Total Used Memory/{u=$NF} END{print t, u}')
  if [ -n "${vt:-}" ] && [ -n "${vu:-}" ]; then
    vfree_gb=$(awk -v t="$vt" -v u="$vu" 'BEGIN{printf "%.1f",(t-u)/1073741824}')
    say "        ${vfree_gb} GiB VRAM free"
    if awk -v f="$vfree_gb" -v n="$NEED_VRAM_GB" 'BEGIN{exit !(f>=n)}'; then
      ok "at or above the ${NEED_VRAM_GB} GiB needed"
    else
      bad "only ${vfree_gb} GiB VRAM free; need ~${NEED_VRAM_GB} GiB"
      FAIL=1
    fi
  else
    note "rocm-smi gave no usable VRAM figure"
  fi
else
  note "rocm-smi not on PATH — VRAM unchecked"
fi

# What is holding it. Printed whether or not the check passed: when it fails this
# is the answer, and when it passes it is what to stop if a bigger model is next.
held="$(curl -sf --max-time 5 http://127.0.0.1:11434/api/ps 2>/dev/null \
  | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit()
for m in d.get("models",[]): print(f"  note  ollama holds {m[\"name\"]} ({m.get(\"size_vram\",0)/1073741824:.1f} GiB VRAM)")' 2>/dev/null)"
[ -n "$held" ] && printf '%s\n' "$held"
docker ps --format '{{.Names}}' | grep -qx asr && note "asr is running and shares the R9700 (Vulkan)"

# OLLAMA'S OWN ACCOUNTING IS NOT THE TRUTH ABOUT VRAM, and this is the trap that
# makes --free look like it worked when it did not. After an unload, /api/ps
# reports NO resident models while llama-server still holds its allocation at the
# KFD level — measured: /api/ps "none", rocm-smi "llama-server 18.9 GiB". The
# process keeps its context and buffers; only restarting ollama gives that back.
# So rocm-smi above is authoritative and /api/ps is a hint, and this says so out
# loud rather than leaving the two numbers to be reconciled by whoever is puzzled.
kfd_ollama="$(rocm-smi --showpids 2>/dev/null | awk '/llama-server/{printf "%.1f", $4/1073741824}')"
api_none="$(curl -sf --max-time 5 http://127.0.0.1:11434/api/ps 2>/dev/null \
  | python3 -c 'import json,sys
try: print("yes" if not json.load(sys.stdin).get("models") else "no")
except Exception: print("?")' 2>/dev/null)"
if [ -n "$kfd_ollama" ] && [ "$api_none" = "yes" ]; then
  note "ollama reports no resident model, but llama-server still holds ${kfd_ollama} GiB of VRAM."
  note "That allocation survives an unload. Only restarting ollama returns it:"
  note "    docker compose -f /opt/construct-server/docker-compose.yml \\"
  note "      --project-directory /opt/construct-server up -d --force-recreate --no-deps ollama"
  note "Not done automatically — ollama is a prod service and that is your call."
fi
say

if [ "$FAIL" -eq 0 ]; then
  say "Clear to run."
else
  say "NOT clear to run. Re-run with --free to unload ollama's models, or stop what is named above."
  say "Running anyway risks the global OOM killer, which picks by score across the"
  say "whole machine — it has already taken llama-server once."
fi
exit "$FAIL"
