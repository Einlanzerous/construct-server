# ComfyUI on the R9700

Design of record: `docs/comfyui.md`. Driven by `make comfy-*` from the checkout; it has
no deploy root because nothing deploys it. It is a third compose project
(`construct-comfyui`) that `assert-healthy.sh` and `check-compose-drift.sh` do not see.

- **ComfyUI has no authentication and is published on the host (8188).** Anything that
  reaches the port can submit arbitrary workflows and read and write the whole data tree.
  Never give it a Traefik router without the `cf-access-jwt` middleware (SERV-106).
- **The official `rocm/comfyui` image does not work on this card and fails silently**: its
  PyTorch targets gfx942/gfx950, `is_available()` is True, and the first kernel launch
  SIGSEGVs. `comfy-check.sh` launches a real kernel for that reason; do not replace it with
  a "is a GPU present" check.
- No ComfyUI-Manager, on purpose. Custom nodes are declared in `Dockerfile`: the manager
  refuses installs behind a non-loopback listener, and the knob that would change that
  lives in the bind mount where git cannot see it.
