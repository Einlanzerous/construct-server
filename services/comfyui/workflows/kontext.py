#!/usr/bin/env python3
"""Build + run the FLUX.1 Kontext poster workflow against ComfyUI's HTTP API (IDEA-52).

The style brief is derived from the Nikko poster, which is the house style. Text is
excluded from generation on purpose: the title goes on post-generation as vector type
(Phase 2), because in-model lettering cannot hold one font and kerning across a set —
demonstrated on the very first smoke-test image, which produced "SILCR MANINE".
"""
import json, sys, time, urllib.request, argparse

API = "http://127.0.0.1:8188"

# Written against the cropped Nikko artwork rather than from memory of it: sage and
# olive greens, slate blue-grey rock, a PALE BLUE SKY with white cloud puffs, and
# layered blue mountain ranges behind. The first run omitted the sky and produced a
# cold teal monochrome with a cream void where the photo's blown-out mist was, which
# is faithful to the photograph and wrong for the house style.
STYLE = (
    "restyle this photograph as a vintage travel poster in the exact style of the "
    "second reference image: flat vector shapes, bold simplified forms, crisp clean "
    "edges, smooth flat colour fills with no gradients. Palette of sage green and "
    "olive foliage, slate blue-grey rock faces, pale blue sky with soft white cloud "
    "shapes, and layered pale blue mountain ranges in the distance. Structured "
    "silhouetted conifer trees. Keep the real geography and composition of the "
    "photograph. No text, no lettering, no words, no border"
)
NEGATIVE = "text, letters, words, watermark, signature, photograph, photorealistic, noise, grain"


def build(image, prompt, seed, steps, guidance, denoise, prefix, style_ref=None, crop=None):
    """Kontext graph. With style_ref, a SECOND ReferenceLatent is chained onto the
    conditioning — which is how Kontext takes more than one reference image, and is
    the whole point of Track A ("photo plus style references") rather than hoping a
    prompt describes the look well enough."""
    g = {
        "10": {"class_type": "UNETLoader", "inputs": {
            "unet_name": "flux1-dev-kontext_fp8_scaled.safetensors",
            "weight_dtype": "fp8_e4m3fn"}},
        "11": {"class_type": "DualCLIPLoader", "inputs": {
            "clip_name1": "clip_l.safetensors",
            "clip_name2": "t5xxl_fp8_e4m3fn_scaled.safetensors",
            "type": "flux"}},
        "12": {"class_type": "VAELoader", "inputs": {"vae_name": "ae.safetensors"}},

        "20": {"class_type": "LoadImage", "inputs": {"image": image}},
        # Kontext only accepts certain resolutions; this snaps to the nearest.
        "21": {"class_type": "FluxKontextImageScale", "inputs": {"image": ["20", 0]}},
        "22": {"class_type": "VAEEncode", "inputs": {"pixels": ["21", 0], "vae": ["12", 0]}},

        "30": {"class_type": "CLIPTextEncode", "inputs": {"text": prompt, "clip": ["11", 0]}},
        # The reference latent is what makes this an EDIT of the photo rather than a
        # fresh generation that merely matches the words.
        "31": {"class_type": "ReferenceLatent", "inputs": {
            "conditioning": ["30", 0], "latent": ["22", 0]}},
        "32": {"class_type": "FluxGuidance", "inputs": {
            "conditioning": ["31", 0], "guidance": guidance}},
        "33": {"class_type": "CLIPTextEncode", "inputs": {"text": NEGATIVE, "clip": ["11", 0]}},

        "40": {"class_type": "KSampler", "inputs": {
            "seed": seed, "steps": steps, "cfg": 1.0,
            "sampler_name": "euler", "scheduler": "simple", "denoise": denoise,
            "model": ["10", 0], "positive": ["32", 0],
            "negative": ["33", 0], "latent_image": ["22", 0]}},
        "50": {"class_type": "VAEDecode", "inputs": {"samples": ["40", 0], "vae": ["12", 0]}},
        "60": {"class_type": "SaveImage", "inputs": {
            "filename_prefix": prefix, "images": ["50", 0]}},
    }
    if crop:
        w, h, x, y = crop
        g["19"] = {"class_type": "ImageCrop", "inputs": {
            "image": ["20", 0], "width": w, "height": h, "x": x, "y": y}}
        g["21"]["inputs"]["image"] = ["19", 0]
    if style_ref:
        # ⚠ THIS DOES NOT WORK, and is kept only so the next person does not spend
        # an afternoon rediscovering it. Kontext REPRODUCES a style reference
        # rather than applying it: every source fed through this path came back as
        # the reference image itself. The Matterhorn, Zermatt and Glacier Express
        # photographs all returned the Nikko waterfall — mean |pixel diff| 16.3,
        # 34.6 and 18.3 against the generated Nikko on a 128x170 grayscale, i.e.
        # near-identical. One run even copied the reference's cream border.
        #
        # Three mechanisms were tried and all three did it: this chain, the same
        # chain with the order reversed, and ImageStitch with an instruction naming
        # which half to redraw. ReferenceLatent carries composition as well as
        # style and exposes no weight to turn that down.
        #
        # Matching a SPECIFIC existing style therefore needs a mechanism with a
        # separate, weighted style channel — IP-Adapter (Track B) or a LoRA.
        g["23"] = {"class_type": "LoadImage", "inputs": {"image": style_ref}}
        g["24"] = {"class_type": "FluxKontextImageScale", "inputs": {"image": ["23", 0]}}
        g["25"] = {"class_type": "VAEEncode", "inputs": {"pixels": ["24", 0], "vae": ["12", 0]}}
        g["34"] = {"class_type": "ReferenceLatent", "inputs": {
            "conditioning": ["31", 0], "latent": ["25", 0]}}
        g["32"]["inputs"]["conditioning"] = ["34", 0]
    return g


def run(wf, timeout=900):
    req = urllib.request.Request(API + "/prompt", data=json.dumps({"prompt": wf}).encode(),
                                 headers={"Content-Type": "application/json"})
    try:
        pid = json.load(urllib.request.urlopen(req))["prompt_id"]
    except urllib.error.HTTPError as e:
        print("REJECTED:", e.read().decode()[:1500]); sys.exit(1)
    t0 = time.time()
    while time.time() - t0 < timeout:
        h = json.load(urllib.request.urlopen(f"{API}/history/{pid}"))
        if pid in h:
            st = h[pid]["status"]
            if st.get("status_str") != "success":
                print("FAILED:", json.dumps(st)[:1500]); sys.exit(1)
            out = [i["filename"] for n in h[pid]["outputs"].values()
                   for i in n.get("images", [])]
            print(f"  ok  {', '.join(out)}  ({time.time()-t0:.1f}s)")
            return out
        time.sleep(2)
    print("TIMEOUT"); sys.exit(1)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--image", required=True)
    ap.add_argument("--prefix", required=True)
    ap.add_argument("--prompt", default=STYLE)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--steps", type=int, default=20)
    ap.add_argument("--guidance", type=float, default=2.5)
    ap.add_argument("--denoise", type=float, default=1.0)
    ap.add_argument("--style-ref", default=None,
                    help="DOES NOT WORK — Kontext reproduces the reference rather "
                         "than applying its style. See build(). Kept for the record.")
    ap.add_argument("--portrait", type=float, default=None,
                    help="centre-crop the source to this aspect (w/h) BEFORE the "
                         "Kontext scale, which otherwise follows the source aspect "
                         "and yields a landscape poster from a landscape photo")
    a = ap.parse_args()
    crop = None
    if a.portrait:
        import subprocess
        dims = subprocess.run(["docker", "exec", "comfyui", "python3", "-c",
            f"from PIL import Image;im=Image.open('/data/input/{a.image}');print(*im.size)"],
            capture_output=True, text=True).stdout.split()
        sw, sh = int(dims[0]), int(dims[1])
        cw = min(sw, int(sh * a.portrait)); ch = min(sh, int(cw / a.portrait))
        crop = (cw, ch, (sw - cw) // 2, (sh - ch) // 2)
        print(f"  crop {sw}x{sh} -> {cw}x{ch} at ({crop[2]},{crop[3]})")
    print(f"{a.image} -> {a.prefix} (g={a.guidance} steps={a.steps} ref={a.style_ref})")
    run(build(a.image, a.prompt, a.seed, a.steps, a.guidance, a.denoise, a.prefix,
              a.style_ref, crop))
