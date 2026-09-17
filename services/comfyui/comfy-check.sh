#!/usr/bin/env bash
# comfy-check.sh — is ComfyUI actually able to compute on this GPU?
#
# Deliberately NOT under scripts/. That directory is rsynced to the prod deploy
# root and is a deploy.yml path trigger, so a ComfyUI-only edit there would fire
# a full-stack prod deploy (a whole-stack pull, since it is not a pure
# versions.env change) for a service prod does not run.
#
# WHY THIS DOES MORE THAN CURL A HEALTH ENDPOINT
#
# The failure this exists to catch is silent. A PyTorch built without gfx1201
# code objects — which is what the official rocm/comfyui image ships — reports:
#
#     torch.cuda.is_available()      -> True
#     torch.cuda.device_count()      -> 1
#     torch.cuda.get_device_name(0)  -> "AMD Radeon AI PRO R9700"
#     get_device_properties(0)       -> gfx1201
#
# ...and then SIGSEGVs on the first kernel launch. ComfyUI boots, serves its API,
# reports the right card and the right VRAM, and the container is HEALTHY. Every
# check short of running a kernel passes. So this runs a kernel.
#
# Exit codes:
#   0  ComfyUI is serving and the GPU executes real work
#   1  a check failed
#   2  usage / missing dependency / container not running
set -uo pipefail

CONTAINER="${COMFYUI_CONTAINER:-comfyui}"
FAIL=0

say()  { printf '%s\n' "$*"; }
ok()   { printf '  ok    %s\n' "$*"; }
bad()  { printf '  FAIL  %s\n' "$*"; FAIL=1; }

command -v docker >/dev/null 2>&1 || { say "ERROR: docker not on PATH"; exit 2; }

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  say "ERROR: container '$CONTAINER' is not running."
  say "Start it with: make comfy-up"
  exit 2
fi

say "ComfyUI container: $CONTAINER"
say

# ── 1. The API answers ────────────────────────────────────────────────────────
say "API"
stats="$(docker exec "$CONTAINER" python3 -c "
import urllib.request, json, sys
try:
    r = urllib.request.urlopen('http://127.0.0.1:8188/system_stats', timeout=10)
except Exception as e:
    print('ERR', e); sys.exit(1)
print(r.read().decode())
" 2>/dev/null)"

if [ -z "$stats" ] || [ "${stats:0:3}" = "ERR" ]; then
  bad "/system_stats did not answer (${stats:-no response})"
  say
  say "ComfyUI is not serving. 'make comfy-logs' — the usual causes are a torch"
  say "import failure or a missing directory under the base directory."
  exit 1
fi

eval "$(printf '%s' "$stats" | python3 -c "
import json, sys
d = json.load(sys.stdin)
s = d.get('system', {})
dev = (d.get('devices') or [{}])[0]
def q(v): return str(v).replace(\"'\", '')
print(f\"COMFY_VER='{q(s.get('comfyui_version'))}'\")
print(f\"TORCH_VER='{q(s.get('pytorch_version'))}'\")
print(f\"DEV_NAME='{q(dev.get('name'))}'\")
print(f\"VRAM_TOTAL='{round(dev.get('vram_total',0)/1024**3,1)}'\")
print(f\"VRAM_FREE='{round(dev.get('vram_free',0)/1024**3,1)}'\")
")"

ok "/system_stats 200 — ComfyUI ${COMFY_VER}, torch ${TORCH_VER}"
ok "device: ${DEV_NAME}"
ok "VRAM: ${VRAM_FREE} GiB free of ${VRAM_TOTAL} GiB"
say

# ── 2. torch was COMPILED for this card ───────────────────────────────────────
# The cheap half of the real question, and the one the Instinct image fails.
say "GPU kernel support"
arch_out="$(docker exec "$CONTAINER" python3 -c "
import torch
arch = torch.cuda.get_device_properties(0).gcnArchName.split(':')[0]
lst  = torch.cuda.get_arch_list()
print(arch, 'YES' if arch in lst else 'NO', ','.join(lst))
" 2>/dev/null)"

if [ -z "$arch_out" ]; then
  bad "could not read torch's arch list"
else
  read -r gpu_arch has_arch arch_list <<<"$arch_out"
  if [ "$has_arch" = "YES" ]; then
    ok "torch carries $gpu_arch kernels (arch_list: $arch_list)"
  else
    bad "torch has NO $gpu_arch kernels — arch_list is: $arch_list"
    say
    say "  This is the rocm/comfyui trap: the card is detected and named"
    say "  correctly, and the first real kernel launch will SIGSEGV."
    say "  Rebuild from services/comfyui/Dockerfile, which uses the official"
    say "  PyTorch ROCm wheels."
  fi
fi

# ── 3. ...and a kernel actually RUNS ──────────────────────────────────────────
# The only check that cannot be faked by metadata. matmul, conv2d and attention
# are the three that every diffusion step goes through.
kernel_out="$(docker exec "$CONTAINER" python3 -c "
import torch, torch.nn.functional as F
a = torch.randn(1024,1024, device='cuda', dtype=torch.float16)
(a@a).float().mean().item()
x = torch.randn(1,64,128,128, device='cuda', dtype=torch.float16)
w = torch.randn(64,64,3,3, device='cuda', dtype=torch.float16)
F.conv2d(x, w, padding=1)
q = torch.randn(1,8,1024,64, device='cuda', dtype=torch.float16)
F.scaled_dot_product_attention(q,q,q)
torch.cuda.synchronize()
print('KERNELS_OK')
" 2>/dev/null)"
rc=$?

if [ "$kernel_out" = "KERNELS_OK" ]; then
  ok "matmul, conv2d and attention all executed on the GPU"
elif [ $rc -ge 128 ]; then
  bad "the GPU kernel test died on signal $((rc-128)) (139 = SIGSEGV, the no-kernels case)"
else
  bad "the GPU kernel test did not complete (exit $rc)"
fi
say

# ── 4. Who else is holding the card ───────────────────────────────────────────
# Not a pass/fail condition — a shared GPU is the design. But an OOM mid-run is
# almost always this, so it is worth printing before you go looking elsewhere.
say "GPU contention"
others="$(docker ps --format '{{.Names}}' | grep -Ex 'ollama|asr' | tr '\n' ' ')"
if [ -n "$others" ]; then
  say "  note  also running and sharing the R9700: ${others%% }"
  say "        ollama holds ~20 GiB while a 30B model is resident; it releases on"
  say "        its keep_alive timeout. 'make comfy-gpu' shows the current split."
else
  ok "no other known GPU consumer is running"
fi
say

if [ "$FAIL" -eq 0 ]; then
  say "ComfyUI is serving and the GPU executes real work."
else
  say "ComfyUI is NOT usable for generation — see the failures above."
fi
exit "$FAIL"
