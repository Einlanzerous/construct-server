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

A slim image built from `services/comfyui/Dockerfile`: **25.1 GB**, ComfyUI
v0.36.0, on the **official PyTorch ROCm wheels**, which do carry gfx1201.

Two things are load-bearing and non-obvious:

**No `rocm/*` base image is needed.** The PyTorch ROCm wheels bundle their own
ROCm runtime under `site-packages/_rocm_sdk_libraries`, so `python:3.12-slim-trixie`
plus a handful of apt libraries is enough. The host's ROCm (6.4.4) is irrelevant
to the container — only the kernel's amdgpu/KFD ABI is shared, and 6.17 is far
newer than anything here needs. This is what turns a 91.7 GB image into a 25.1 GB
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
  nothing deploys it. That is not the same as there being one copy of the compose
  file: after merge at least two checkouts carry it (`~/construct-server` and the
  runner's `_work/…`, which `pr-review.yml` points at unmerged PR merge refs).
  What holds is that the **project name** is pinned in the Makefile, so a second
  checkout adopts the one container rather than standing up a second — and the
  `comfy-file` guard covers the case that actually bites, invoking the targets
  from the deploy root where the file is absent.
- **No `security_opt`, no `ipc: host`.** AMD's ROCm container guidance asks for
  both and neither is needed here — measured: default seccomp, private IPC and
  `shm_size: 8gb` run matmul, conv2d and attention on the R9700 from this image.
  ollama, asr and aperture-backend all do ROCm with `SecurityOpt=[]` and
  `IpcMode=private` already. On *this* container the cost would be real, because
  it is unauthenticated and can be made to run third-party code: `seccomp:unconfined`
  hands that code every syscall the kernel exposes, and `ipc: host` gives it the
  host's System V segments and `/dev/shm`. `shm_size` supplies the only thing
  actually wanted — a segment bigger than docker's 64 MB default.
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
- **Data**: one bind mount, `/srv/comfyui` → `/data`, with the five *mutable*
  directories pointed at it individually — models, input, output, temp, user.
  `custom_nodes` is **not** among them; nodes are declared in the image. On `/` rather than
  `/data`, which is the estate's usual home for service data: `/` has the most
  headroom (~370 GB) and is the only one of the three disks argosy's media does
  not grow into, and a bake-off across FLUX.2, Qwen-Image-Edit and an
  SDXL/ControlNet stack is 100–200 GB of weights.

### Custom nodes are declared in the image, and the manager is off

**ComfyUI-Manager cannot install a custom node on this deployment**, and the
reason is structural rather than a setting someone forgot. Every install is
gated behind `is_allowed_security_level('middle+')`, which returns False unless
the listener is loopback or `network_mode` is `personal_cloud`. This container
publishes `8188`, so `--listen` must be `0.0.0.0`, so that test is False for
ever. Measured: a queued install returns HTTP 200, then fails with

```
ERROR: To use this action, security_level must be `normal or below`,
and network_mode must be set to `personal_cloud`.
```

and `custom_nodes/` stays empty. So `--enable-manager` bought nothing and still
exposed the `middle`-level endpoints — `/v2/manager/reboot`, `policy/update`,
`db_mode`, `queue/start` — on an unauthenticated listener. It is off.

Custom nodes are therefore declared in `services/comfyui/Dockerfile`: clone at a
pinned ref, install its `requirements.txt`. `ComfyUI-GGUF` is there as the
worked example and because Track A needs it for quantised checkpoints. Pin the
ref — a floating clone makes the image non-reproducible in exactly the way
`versions.env` exists to prevent for everything else on this box.

This is also why the mutable directories are named individually in `command:`
rather than with `--base-directory`. That flag redirects `custom_nodes/` too, so
an image-declared node would simply not be loaded. Naming the five makes "state
in the mount, code in the image" structural instead of a convention.

**Do not make installs work by setting `security_level = weak`** in
`/data/user/__manager/config.ini`. That file is inside the bind mount: the
widening would be invisible to git, survive every recreate, and be an access
change with no reviewable diff. To re-enable the manager for *browsing* — the
registry UI works, installs still refuse — add `- --enable-manager` back to
`command:` and `make comfy-recreate`. The package stays in the image so that is
a recreate, not a rebuild.

The package is also a trap worth recording: `--enable-manager` without
`manager_requirements.txt` installed is a **silent no-op**. The server logs one
line at boot and carries on serving, and the UI then offers to install the
manager — which reads as ComfyUI needing an update when it is exactly on its
pinned tag.

### Why there is no `PIP_USER`

Git still has to be readable as the uid the container runs as.
The clone happens as root during the build, so without
`git config --system --add safe.directory /opt/ComfyUI` every git call from
inside the app fails with `detected dubious ownership in repository`. That is
not cosmetic either: the manager and the frontend shell out to git to determine
the installed version, and a failed check also presents as "an update is
needed".

**`PIP_USER` / `PYTHONUSERBASE` are deliberately absent, and must not be added
back.** They were here first, to persist custom-node dependencies across a
recreate, and the cost was much higher than the benefit: `PIP_USER=1` makes
`pip list` **report nothing at all** — measured, 0 lines against 101, exit code
0 either way. ComfyUI-Manager enumerates the environment with exactly that
command (`common/manager_util.py`, `get_installed_packages`), so it concluded
nothing was installed and logged `[ComfyUI-Manager] PyTorch is not installed`.

That log line is the visible edge of a disabled safety net. Manager's `PIPFixer`
snapshots `torch`/`torchvision`/`torchaudio` before a custom-node install and
**rolls them back** if the install changed them — the one thing standing between
a node whose `requirements.txt` names `torch` and a CUDA build from PyPI
silently replacing this container's ROCm torch. The rollback sits in an `elif`
after the "is it installed" test, so an empty `pip list` switches it off
entirely while looking like a harmless warning.

So dependencies live in the image. A custom node that earns its place gets added
to `services/comfyui/Dockerfile` and rebuilt; the manager can still install one
There is no try-it-out path: the manager is not loaded, `custom_nodes` is not
redirected into the mount, and `/opt/ComfyUI/custom_nodes` is root-owned while
the process runs as 1000. A node is a pinned Dockerfile entry and a rebuild,
deliberately, or it is nothing — the same reasoning as ComfyUI not being able to
update itself.

### What the cache variables are for

`MIOPEN_USER_DB_PATH=/data/.cache/miopen`. MIOpen ships **no perf database for
gfx1201** (it says so at boot: `File is unreadable: .../gfx1201_32.HIP.fdb.txt`),
so it tunes kernels on first use. In the container layer that tuning is thrown
away on every recreate and paid again on the next generation. `HF_HOME` and
`TORCHINDUCTOR_CACHE_DIR` are in the mount for the ordinary version of the same
reason — neither affects pip, which is why they survived the removal above.

## Exposure — read this before changing the port

**ComfyUI has no authentication of any kind**, and it is published on the host
(`8188`), matching the existing posture of `ollama:11434` and `open-webui:3000`.
It is reachable from the LAN and the tailnet. That is a deliberate choice for
IDEA-52, not an oversight.

It is a worse thing to expose than ollama: it reads and writes everything under
its data tree, and executes whatever workflow is submitted to it. It does not
run ComfyUI-Manager, so it cannot install code — see the custom-nodes section
above before changing that. Anything that can reach that port has all of that.

Consequently it must **never** gain a Traefik router without an Access middleware
in front of it (SERV-106). A router on the `internal` entrypoint with no
`cf-access-jwt` middleware is exactly the hole that ticket closed, and
`check-edge-auth.sh` would fail on it — correctly.

## System RAM is the binding constraint, not VRAM

The card has 32 GiB. **The host has 31 GiB, and that is what runs out first.**
ComfyUI stages weights through system RAM before they reach the GPU, so a model
that fits the card comfortably can still kill the box.

Measured on FLUX.1 Kontext fp8 (12 GB) plus `t5xxl_fp8` (5 GB), with ollama
holding ~9.5 GB resident and the 8 GB swap already ~90% used: 31.5 GB used, 414
MB available, and the kernel killed ComfyUI — `global_oom`, `Killed process
(python3)`, 12.3 GB anon-rss. Reproduced twice.

**The failure mode is quiet, which is the part worth remembering.** The container
is SIGKILLed and `restart: unless-stopped` brings it straight back, so seconds
later `docker ps` shows a healthy container and `comfy-check.sh` passes. The only
evidence is a `RemoteDisconnected` in whatever was driving the API, and a restart
count nobody is watching. `docker inspect` even reports `OOMKilled=false`, because
that flag means the *cgroup* limit was hit — this was the global kernel OOM
killer, which is a different thing wearing the same word.

The fix is two flags in `command:`. `--mmap-torch-files` makes weights file-backed
rather than anonymous, so the kernel can evict them under pressure instead of
OOMing; `--cache-none` stops ComfyUI retaining models between prompts. Peak drops
to 30.2 GB and the same run completes. Both cost reload time per prompt, which is
the right trade against being killed.

Two consequences:

- **FLUX.2 dev is ruled out on this box** — ~32 GB of weights at fp8 cannot be
  staged in 31 GB of RAM, whatever the card can hold. Host memory disqualifies it
  before VRAM is consulted. A GGUF quant (Q4, ~19 GB) is the only way it could run.
- Headroom is still thin at 30.2 GB. Stopping ollama frees ~9.5 GB and is the
  largest single lever if a run needs it.

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
