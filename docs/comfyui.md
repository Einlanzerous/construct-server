# ComfyUI on the R9700 — design of record

Local image generation on the AMD Radeon AI PRO R9700 (Navi 48, **gfx1201**),
stood up for **IDEA-52** (European trip photos → vintage travel poster magnets).

Not part of the stack. It is a separate compose project, `construct-comfyui`,
driven by `make comfy-*`. Nothing in `docker-compose.yml` references it, no CI
deploys it, and it is not enrolled in `assert-healthy.sh` or
`check-compose-drift.sh` — those iterate the services defined in the prod compose
file, so a separate *project* is invisible to them rather than silently skipped.

## The finding that shaped everything else

**The official AMD image, `rocm/comfyui`, does not work on this card, and fails in
the way that is hardest to notice.**

Its PyTorch is compiled for Instinct only — `torch.cuda.get_arch_list()` is
`['gfx942', 'gfx950']`. On the R9700 it reports:

```
torch.cuda.is_available()      -> True
torch.cuda.device_count()      -> 1
torch.cuda.get_device_name(0)  -> "AMD Radeon AI PRO R9700"
get_device_properties(0)       -> gfx1201
```

...and then **SIGSEGVs (exit 139) on the first kernel launch**. Allocation
succeeds; the matmul kills the process with no Python traceback. ComfyUI would
boot, serve its API, report the right card and the right VRAM, and the container
would be `healthy`.

Every check short of running a kernel passes. That is why
`services/comfyui/comfy-check.sh` runs a real matmul, conv2d and attention rather
than asking whether a GPU is present, and why the *presence* of the card in
`arch_list` is checked separately from its *name* — the name is right in the
broken case.

It also unpacks to **91.7 GB** and ships ComfyUI **0.18.2** (last rebuilt
2026-05-05, against a current ComfyUI of 0.36.0).

This is worth remembering beyond ComfyUI: "AMD's own image" is not evidence of
support for an AMD card. The image targets the Instinct line, and RDNA4 is a
different compilation target.

## What is used instead

A slim image built from `services/comfyui/Dockerfile`: **29.5 GB**, ComfyUI
v0.36.0, on the **official PyTorch ROCm wheels**, which do carry gfx1201.

Two things are load-bearing and non-obvious:

**No `rocm/*` base image is needed.** The PyTorch ROCm wheels bundle their own
ROCm runtime under `site-packages/_rocm_sdk_libraries`, so `python:3.12-slim-trixie`
plus a handful of apt libraries is enough. The host's ROCm (6.4.4) is irrelevant
to the container — only the kernel's amdgpu/KFD ABI is shared, and 6.17 is far
newer than anything here needs. This is what turns a 91.7 GB image into a 29.5 GB
one.

**The version set is forced, not chosen.** ComfyUI imports `torchaudio`
unconditionally (`comfy/sd.py` → `comfy/ldm/lightricks/vae/audio_vae.py`), and
PyTorch **stopped publishing torchaudio after 2.11.0** — it exists in no index
above `rocm7.2`, for any platform. So the newest set that can boot ComfyUI is:

| package | version | index |
|---|---|---|
| torch | 2.11.0+rocm7.2 | `download.pytorch.org/whl/rocm7.2` |
| torchvision | 0.26.0+rocm7.2 | same |
| torchaudio | 2.11.0+rocm7.2 | same |

Moving torch to 2.14/rocm7.14 builds fine, passes every GPU check, and then dies
at import with `OSError: libcudart.so.13: cannot open shared object file` —
because pip silently satisfies the `torchaudio` dependency from PyPI, which is the
**CUDA** build. If a future ComfyUI makes torchaudio optional, the newer line is
available and was measured working on this card at 127.5 TFLOP/s fp16.

## Verified on the box

| check | result |
|---|---|
| `arch_list` contains gfx1201 | yes |
| matmul / conv2d / scaled_dot_product_attention | all execute |
| fp16 matmul throughput | ~127 TFLOP/s |
| SD1.5, 512×512, 20 steps, euler | **5.1 s**, coherent image, no NaN |
| ComfyUI boot to API answering | ~15 s |

The generation was driven through the HTTP API (`POST /prompt` with a workflow in
API format, poll `/history/<id>`), which is how IDEA-52 wants this driven — no
hand-written Python in the loop.

## Deployment shape

- **Project**: `construct-comfyui`, from `docker-compose.comfyui.yml`, run from the
  **checkout**. Unlike prod (SERV-76) and dev there is no deploy root, because
  nothing deploys it — so "which ComfyUI is live" has one answer without a fixed
  path to enforce it.
- **Devices**: `/dev/kfd` plus `/dev/dri/renderD129` only — the R9700's render
  node, not the whole of `/dev/dri`. `renderD128` is the CometLake iGPU; the
  numbering reads the wrong way round on this box and was confirmed from
  `/sys/class/drm/*/device/uevent`. Same reasoning as the `asr` service.
- **Groups**: `993` (this host's `render` gid). Unlike `asr` this container does
  **not** run as root, so that entry is load-bearing today, not a precaution.
- **User**: `1000:1000`, so models and outputs in the bind mount are manageable by
  hand without sudo. The image carries a matching passwd entry — without one,
  torch's `_inductor` cache setup calls `getpass.getuser()` and dies with
  `KeyError: getpwuid(): uid not found: 1000` before ComfyUI prints anything.
- **Data**: one bind mount, `/srv/comfyui` → `/data`, with `--base-directory`
  pointing models/input/output/user/custom_nodes/temp at it. On `/` rather than
  `/data`, which is the estate's usual home for service data: `/` has the most
  headroom (~370 GB) and is the only one of the three disks argosy's media does
  not grow into, and a bake-off across FLUX.2, Qwen-Image-Edit and an
  SDXL/ControlNet stack is 100–200 GB of weights.

### Two things that would otherwise be lost on every recreate

`PYTHONUSERBASE=/data/.python` with `PIP_USER=1`. ComfyUI's manager installs a
custom node by cloning it and running its `requirements.txt`; left alone that
lands in the image's `site-packages`, inside the container layer, so every
recreate silently reverts it and the node then fails to import with a missing
module nobody changed. Pointing pip's `--user` target into the bind mount makes
those installs persist — Python picks the directory up as the user site
automatically, no `PYTHONPATH` needed.

`MIOPEN_USER_DB_PATH=/data/.cache/miopen`. MIOpen ships **no perf database for
gfx1201** (it says so at boot: `File is unreadable: .../gfx1201_32.HIP.fdb.txt`),
so it tunes kernels on first use. In the container layer that tuning is thrown
away on every recreate and paid again on the next generation.

## Exposure — read this before changing the port

**ComfyUI has no authentication of any kind**, and it is published on the host
(`8188`), matching the existing posture of `ollama:11434` and `open-webui:3000`.
It is reachable from the LAN and the tailnet. That is a deliberate choice for
IDEA-52, not an oversight.

It is a worse thing to expose than ollama: it reads and writes everything under
its base directory, and `--enable-manager` lets the UI install and run
third-party code. Anything that can reach that port has all of that.

Consequently it must **never** gain a Traefik router without an Access middleware
in front of it (SERV-106). A router on the `internal` entrypoint with no
`cf-access-jwt` middleware is exactly the hole that ticket closed, and
`check-edge-auth.sh` would fail on it — correctly.

## GPU contention

The R9700 is shared. `ollama` holds ~20 GiB while a 30B model is resident and
releases on its `keep_alive` timeout; `asr` uses it through Vulkan. A 32 GB card
does not fit a resident 30B LLM and a FLUX.2 fp8 checkpoint at the same time.

`make comfy-gpu` shows the current split. There is no arbitration mechanism and
deliberately so — the honest answer for a spike is to stop what you are not using.
ComfyUI's `--reserve-vram` is available if a soft floor turns out to be wanted.

## Commands

```
make comfy-bootstrap   # create /srv/comfyui and its subdirectories
make comfy-build       # build the image (slow: ~5 GB of wheels; layers cache)
make comfy-up          # start
make comfy-health      # API + a REAL kernel launch (see above)
make comfy-gpu         # who is holding the card
make comfy-logs
make comfy-down        # stop, freeing the GPU
make comfy-recreate    # after an image rebuild — never `docker restart`
```

`make comfy-health` is the one worth running after any change. It exits non-zero
when the container is absent (2), when the API does not answer (1), and when
torch has no kernels for the installed card (1) — all three verified by running
them, because a check that has never failed is indistinguishable from a check that
cannot.

## Open, for the phases after this one

- The **reference posters** (Nikko, Huashan) and the trip photos are not on this
  box. Phase 1 consumes them directly as style references, so they need to land in
  `/srv/comfyui/input` before the bake-off can start.
- The existing magnets need **measuring** (aspect ratio, border, title band)
  before anything is generated at final size — Phase 2.
- Track A's candidates (FLUX.1 Kontext dev, Qwen-Image-Edit, FLUX.2 dev) are
  20–35 GB each at fp8. Budget the disk before pulling all three.
