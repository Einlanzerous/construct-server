# ComfyUI on ROCm for the AMD Radeon AI PRO R9700 (Navi 48, gfx1201) — IDEA-52.
#
# NOT built FROM rocm/comfyui, the official AMD image, and the reason is worth
# keeping: that image's PyTorch is compiled for gfx942/gfx950 (Instinct) ONLY.
# On this card it looks entirely healthy —
#
#     torch.cuda.is_available()      -> True
#     torch.cuda.get_device_name(0)  -> "AMD Radeon AI PRO R9700"
#     get_device_properties(0)       -> gfx1201
#
# — and then SIGSEGVs (exit 139) on the first kernel launch, because
# torch.cuda.get_arch_list() is ['gfx942', 'gfx950'] and there is no gfx1201
# code object to dispatch to. Every naive "can we see the GPU" check passes.
# Measured on this box, not inferred. It also unpacks to 91.7 GB and ships
# ComfyUI 0.18.2 (last rebuilt 2026-05-05).
#
# The official PyTorch ROCm wheels DO carry gfx1201, and bundle their own ROCm
# runtime under site-packages/_rocm_sdk_libraries, so no rocm/* base image is
# needed at all: a slim Python base is enough, and the result is 25.1 GB.
# The HOST's ROCm (6.4.4) is irrelevant to this container — only the kernel's
# amdgpu/KFD ABI is shared, and 6.17 is far newer than anything here needs.
#
# THE VERSION SET IS FORCED, NOT CHOSEN. Read this before "upgrading" it:
# ComfyUI imports torchaudio unconditionally (comfy/sd.py ->
# comfy/ldm/lightricks/vae/audio_vae.py), and PyTorch STOPPED PUBLISHING
# torchaudio after 2.11.0 — it exists in no index above rocm7.2, for any
# platform. So the newest set that can actually boot ComfyUI is the 2.11 triple
# below, on the rocm7.2 index. Moving torch to 2.14/rocm7.14 builds fine, passes
# every GPU check, and then dies at import with
#     OSError: libcudart.so.13: cannot open shared object file
# because pip silently satisfies the torchaudio dependency from PyPI, which is
# the CUDA build. If a future ComfyUI makes torchaudio optional, the newer line
# is available and was verified working on this card (127.5 TFLOP/s fp16).
FROM python:3.12-slim-trixie

ARG COMFYUI_REF=v0.36.0
ARG ROCM_INDEX=https://download.pytorch.org/whl/rocm7.2

# libgl1/libglib2.0-0 are for opencv, which the ControlNet preprocessor nodes
# pull in (Phase 1 Track B). git is needed at BUILD time, to clone ComfyUI and
# the custom nodes below, and at runtime only so the frontend can read the
# checkout's version.
RUN apt-get update && apt-get install -y --no-install-recommends \
      git ca-certificates \
      libgomp1 libnuma1 libdrm2 libelf1 libatomic1 libzstd1 \
      libgl1 libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir --index-url ${ROCM_INDEX} \
      torch==2.11.0+rocm7.2 \
      torchvision==0.26.0+rocm7.2 \
      torchaudio==2.11.0+rocm7.2

RUN git clone --depth 1 --branch ${COMFYUI_REF} \
      https://github.com/comfyanonymous/ComfyUI.git /opt/ComfyUI \
    && pip install --no-cache-dir -r /opt/ComfyUI/requirements.txt

# ComfyUI-Manager. Installed but NOT enabled — see the `command:` in
# docker-compose.comfyui.yml for why, and note that leaving the package here is
# what makes turning it on a recreate rather than a 20-minute rebuild.
#
# It is a SEPARATE requirements file, which is its own trap: --enable-manager
# without this is a silent no-op, where the server prints one line at boot
# ("the `comfyui-manager` package must be installed first") and carries on
# serving, so the UI offers to install the manager and the whole thing reads as
# ComfyUI needing an update.
RUN pip install --no-cache-dir -r /opt/ComfyUI/manager_requirements.txt

# ── CUSTOM NODES ─────────────────────────────────────────────────────────────
# Declared HERE, in the image, and nowhere else. This is the whole mechanism:
# clone at a pinned ref, install its requirements, done.
#
# It is here rather than in the data mount because the manager cannot install a
# node on this deployment at all — measured, not assumed. ComfyUI-Manager gates
# `do_install` behind `is_allowed_security_level('middle+')`, which returns
# False unless the listener is loopback or network_mode is `personal_cloud`.
# This container publishes 8188, so --listen is 0.0.0.0, so that is permanently
# False: a queued install returns HTTP 200 and then fails with "security_level
# must be `normal or below`, and network_mode must be set to `personal_cloud`".
#
# Pin the ref. A floating clone makes the image non-reproducible in exactly the
# way versions.env exists to prevent for everything else on this box.
ARG GGUF_REF=6ea2651e7df66d7585f6ffee804b20e92fb38b8a
RUN git clone https://github.com/city96/ComfyUI-GGUF /opt/ComfyUI/custom_nodes/ComfyUI-GGUF \
    && git -C /opt/ComfyUI/custom_nodes/ComfyUI-GGUF checkout -q ${GGUF_REF} \
    && pip install --no-cache-dir -r /opt/ComfyUI/custom_nodes/ComfyUI-GGUF/requirements.txt

# Track B (IDEA-52): SDXL + ControlNet + IP-Adapter. These two exist because Track A
# could not separate structure from style — Kontext's ReferenceLatent carries a
# reference image's composition along with its style and offers no weight to turn
# that down, so every source came back as the reference. ControlNet holds the
# geometry and IP-Adapter holds the style, each with its OWN strength, which is the
# knob that was missing.
#
# IPAdapter_plus supplies the adapter nodes; controlnet_aux supplies the depth and
# lineart preprocessors (the objective asks for both, not just Canny — Canny on a
# full-res mirrorless frame picks up snow texture and cobblestones).
ARG IPADAPTER_REF=a0f451a5113cf9becb0847b92884cb10cbdec0ef
RUN git clone https://github.com/cubiq/ComfyUI_IPAdapter_plus \
      /opt/ComfyUI/custom_nodes/ComfyUI_IPAdapter_plus \
    && git -C /opt/ComfyUI/custom_nodes/ComfyUI_IPAdapter_plus checkout -q ${IPADAPTER_REF}

# controlnet_aux pulls a large preprocessor stack, and its requirements.txt DOES
# name torch — line 1 is a bare `torch` and line 10 a bare `torchvision` at the
# pinned ref. That is safe, and the distinction is the whole point of the guard
# below: pip treats an unpinned requirement as already satisfied by this image's
# torch 2.11.0+rocm7.2, so nothing is fetched. A VERSIONED one is a different
# thing entirely — `torch~=2.12`, `torch!=2.11.0` or a `torch @ https://…` direct
# reference all make pip go and get it, and what it gets from PyPI is the CUDA
# build, which replaces the ROCm torch and dies at import with
# `libcudart.so.13: cannot open shared object file` (see the top of this file).
# ComfyUI-Manager's PIPFixer would normally roll that back; it is not loaded here
# at all, so this guard is the only thing between a ref bump and that failure.
#
# The character class is therefore every character a pip specifier can START with
# — = ! < > ~ @ — and NOT just [=<>], which was the first attempt and matched
# neither `torch~=2.12` nor a direct reference. It fails with a sentence rather
# than a bare exit 1, because a guard that stops a build without saying why is
# the thing this repo keeps having to fix.
ARG CONTROLNET_AUX_REF=59b1fc411ede8623b2997855b8018f0b3b6cf49f
RUN git clone https://github.com/Fannovel16/comfyui_controlnet_aux \
      /opt/ComfyUI/custom_nodes/comfyui_controlnet_aux \
    && git -C /opt/ComfyUI/custom_nodes/comfyui_controlnet_aux checkout -q ${CONTROLNET_AUX_REF} \
    && if grep -qiE '^[[:space:]]*torch(vision|audio)?[[:space:]]*[=!<>~@]' \
            /opt/ComfyUI/custom_nodes/comfyui_controlnet_aux/requirements.txt; then \
         echo "ERROR: comfyui_controlnet_aux at ${CONTROLNET_AUX_REF} pins a torch version:"; \
         grep -inE '^[[:space:]]*torch(vision|audio)?[[:space:]]*[=!<>~@]' \
            /opt/ComfyUI/custom_nodes/comfyui_controlnet_aux/requirements.txt; \
         echo "Installing it would pull PyPI's CUDA torch over this image's ROCm build."; \
         echo "Install that requirements file with the torch lines stripped, or hold the ref."; \
         exit 1; \
       fi \
    && pip install --no-cache-dir \
         -r /opt/ComfyUI/custom_nodes/comfyui_controlnet_aux/requirements.txt

# Let git READ /opt/ComfyUI as the uid this container runs as. The clone happens
# here as root, so without this every git call from inside the app fails with
# `detected dubious ownership in repository` — which is not cosmetic: the
# manager and the frontend shell out to git to work out what version is
# installed, and a failed check presents as "an update is needed" for a checkout
# that is exactly on its pinned tag.
#
# --system, not --global: --global writes to $HOME, and the runtime HOME is set
# below, so a --global entry would land in the wrong file for the wrong user.
#
# Deliberately NOT a chown. /opt/ComfyUI stays root-owned and therefore
# read-only to the app, so ComfyUI cannot update ITSELF. That is the intended
# shape: the version is pinned by COMFYUI_REF and changing it is a rebuild, so
# an in-place self-update would be reverted by the next recreate — silently, and
# with nothing to show which ComfyUI was actually serving. Failing that write is
# better than losing it later. Nothing needs to write here: custom nodes are
# declared below, in this image, never installed at runtime.
RUN git config --system --add safe.directory /opt/ComfyUI

# A real passwd entry for the uid compose runs as. Without one, torch's
# _inductor cache_dir() calls getpass.getuser(), which falls through to
# pwd.getpwuid() and dies with `KeyError: getpwuid(): uid not found: 1000`
# before ComfyUI prints anything about itself. Last, so it costs no rebuild of
# the layers above. `|| true`: only a base image that already had uid 1000
# would fail here, and then the entry it has is the one we wanted anyway.
RUN useradd -u 1000 -m -s /usr/sbin/nologin comfy || true
ENV HOME=/home/comfy

WORKDIR /opt/ComfyUI
EXPOSE 8188

# --listen only; every directory and every policy flag is compose's to say, so
# this image stays a plain ComfyUI and the deployment holds the policy.
ENTRYPOINT ["python3", "main.py", "--listen", "0.0.0.0", "--port", "8188"]
