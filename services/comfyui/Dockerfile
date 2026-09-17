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
# needed at all: a slim Python base is enough, and the result is 29.5 GB.
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
# pull in (Phase 1 Track B). git is needed at runtime too: ComfyUI's built-in
# manager installs custom nodes by cloning them.
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

# --listen only; everything else (base directory, VRAM reserve) is compose's to
# say, so this image stays a plain ComfyUI and the deployment holds the policy.
ENTRYPOINT ["python3", "main.py", "--listen", "0.0.0.0", "--port", "8188"]
