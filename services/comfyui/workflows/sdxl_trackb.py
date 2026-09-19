#!/usr/bin/env python3
"""Track B — SDXL + ControlNet + IP-Adapter, driven over ComfyUI's HTTP API (IDEA-52).

WHY THIS TRACK EXISTS. Track A (FLUX.1 Kontext) could not separate structure from
style. Its `ReferenceLatent` carries a reference image's COMPOSITION as well as its
style and exposes no weight, so every source came back as the reference itself —
the Matterhorn, Zermatt and Glacier Express photographs all returned the Nikko
waterfall. Prompt-only avoided that but could not hold one style across images,
and set consistency is the whole objective.

Here the two concerns are separate channels with independent dials:

    geometry -> depth map -> ControlNet     --cn-strength
    style    -> reference -> IP-Adapter     --ip-weight

That pair of numbers is the experiment. Sweep them; do not guess them.

Validate on a subject the style reference does NOT contain. Track A's bug survived
a whole iteration because it was checked against the photograph the reference
poster was made from, where "restyle the source" and "copy the reference" produce
the same picture.
"""
import argparse, json, sys, time, urllib.request

API = "http://127.0.0.1:8188"

# Treatment, not content — the Track A lesson applies unchanged. Naming scene
# elements makes the model draw them and discard the photograph.
# DESCRIBES TREATMENT AND VALUE, NEVER HUE — AND NEVER SATURATION EITHER.
# The previous version of this string ended "strong graphic value contrast,
# limited muted palette", and `muted` was the whole problem: it desaturated the
# subject, so the Glacier Express's scarlet train rendered blue-white and the
# Matterhorn's grey rock and white snow rendered as a green hill. Two words, and
# no hue was ever named.
#
# The IP-Adapter is already supplying the reference's palette, so any instruction
# here about colour — its hue OR its intensity — only subtracts from what the
# photograph brought. Ask for value contrast, which is about light and dark, and
# leave chroma to the image and to --accent.
#
# Naming a subject's REAL colours is not the content-prompting mistake Track A
# made — that was naming scene elements which were not in the photograph. Use
# --accent for those, per image.
POSITIVE = ("vintage screen-printed travel poster, flat blocks of solid colour, "
            "crisp hard edges, no gradients, bold simplified shapes, strong graphic "
            "value contrast between deep shadows and pale highlights, keeping the "
            "subject's own real colours, vivid and saturated")
NEGATIVE = ("photograph, photorealistic, 3d render, gradient, soft focus, blurry, "
            "noise, grain, text, letters, words, watermark, signature, frame, border")

# An SDXL native bucket close to the house portrait format (0.746). Off-bucket
# sizes cost quality on SDXL far more than on FLUX.
W, H = 896, 1152

# A preprocessor and its ControlNet are ONE choice, so they are looked up together
# rather than being two flags that happen to agree. They were two flags, and
# `--preprocessor lineart` alone then fed a lineart map into the depth-trained
# ControlNet: ComfyUI accepts it, the run completes, and the output degrades in a
# way that reads as "the ControlNet is too weak" — which on a spike whose method
# is sweeping --cn-strength sends you tuning the wrong number. --controlnet still
# overrides, for trying a third ControlNet against either map.
CONTROLNETS = {
    "depth":   "controlnet-depth-sdxl.safetensors",
    "lineart": "controlnet-scribble-sdxl.safetensors",
}


def build(a):
    g = {
        "1": {"class_type": "CheckpointLoaderSimple",
              "inputs": {"ckpt_name": "sd_xl_base_1.0.safetensors"}},

        # ── geometry channel ──────────────────────────────────────────────────
        "2": {"class_type": "LoadImage", "inputs": {"image": a.image}},
        "3": {"class_type": "ImageScale", "inputs": {
            "image": ["2", 0], "upscale_method": "lanczos",
            "width": W, "height": H, "crop": "center"}},
        # Depth, not Canny. Canny on a full-res frame picks up snow texture,
        # foliage and cobblestones and hands all of it to the ControlNet as
        # structure; depth gives the foreground/midground/background banding a
        # poster is built from. The preprocessor downloads its own checkpoint on
        # first use.
        "4": ({"class_type": "DepthAnythingPreprocessor", "inputs": {
                  "image": ["3", 0], "ckpt_name": "depth_anything_vitl14.pth",
                  "resolution": 1024}}
              if a.preprocessor == "depth" else
              {"class_type": "AnyLineArtPreprocessor_aux",
               "inputs": {"image": ["3", 0]}}),
        "5": {"class_type": "ControlNetLoader",
              "inputs": {"control_net_name": a.controlnet}},

        "6": {"class_type": "CLIPTextEncode", "inputs": {"text": a.positive, "clip": ["1", 1]}},
        "7": {"class_type": "CLIPTextEncode", "inputs": {"text": a.negative, "clip": ["1", 1]}},
        "8": {"class_type": "ControlNetApplyAdvanced", "inputs": {
            "positive": ["6", 0], "negative": ["7", 0], "control_net": ["5", 0],
            "image": ["4", 0], "strength": a.cn_strength,
            "start_percent": 0.0, "end_percent": a.cn_end}},

        # ── style channel ─────────────────────────────────────────────────────
        "9":  {"class_type": "LoadImage", "inputs": {"image": a.style_ref}},
        "10": {"class_type": "IPAdapterModelLoader",
               "inputs": {"ipadapter_file": "ip-adapter-plus_sdxl_vit-h.safetensors"}},
        "11": {"class_type": "CLIPVisionLoader",
               "inputs": {"clip_name": "CLIP-ViT-H-14-laion2B.safetensors"}},
        "12": {"class_type": "IPAdapterAdvanced", "inputs": {
            "model": ["1", 0], "ipadapter": ["10", 0], "image": ["9", 0],
            "weight": a.ip_weight, "weight_type": "linear", "combine_embeds": "concat",
            "start_at": 0.0, "end_at": 1.0, "embeds_scaling": "V only",
            "clip_vision": ["11", 0]}},

        "13": {"class_type": "EmptyLatentImage",
               "inputs": {"width": W, "height": H, "batch_size": 1}},
        "14": {"class_type": "KSampler", "inputs": {
            "seed": a.seed, "steps": a.steps, "cfg": a.cfg,
            "sampler_name": "dpmpp_2m", "scheduler": "karras", "denoise": 1.0,
            "model": ["12", 0], "positive": ["8", 0], "negative": ["8", 1],
            "latent_image": ["13", 0]}},
        "15": {"class_type": "VAEDecode", "inputs": {"samples": ["14", 0], "vae": ["1", 2]}},
        "16": {"class_type": "SaveImage", "inputs": {
            "filename_prefix": a.prefix, "images": ["15", 0]}},
    }
    if a.save_control:
        # Named for the PREPROCESSOR, not "_depth". This image is exactly the
        # artefact you compare between the two modes, so a lineart map filed as
        # `_depth` is the one that ends up mislabelled in the comparison.
        g["17"] = {"class_type": "SaveImage", "inputs": {
            "filename_prefix": f"{a.prefix}_{a.preprocessor}", "images": ["4", 0]}}
    return g


def run(wf, timeout=1200):
    req = urllib.request.Request(API + "/prompt", data=json.dumps({"prompt": wf}).encode(),
                                 headers={"Content-Type": "application/json"})
    try:
        pid = json.load(urllib.request.urlopen(req))["prompt_id"]
    except urllib.error.HTTPError as e:
        sys.exit("REJECTED: " + e.read().decode()[:2000])
    t0 = time.time()
    while time.time() - t0 < timeout:
        h = json.load(urllib.request.urlopen(f"{API}/history/{pid}"))
        if pid in h:
            st = h[pid]["status"]
            if st.get("status_str") != "success":
                sys.exit("FAILED: " + json.dumps(st)[:2000])
            out = [i["filename"] for n in h[pid]["outputs"].values() for i in n.get("images", [])]
            print(f"  ok  {', '.join(out)}  ({time.time()-t0:.1f}s)")
            return out
        time.sleep(2)
    sys.exit("TIMEOUT")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--image", required=True)
    ap.add_argument("--style-ref", required=True,
                    help="unlike Track A this is load-bearing and actually works")
    ap.add_argument("--prefix", required=True)
    ap.add_argument("--controlnet", default=None,
                    help="override the ControlNet paired with --preprocessor; "
                         f"defaults are {CONTROLNETS}")
    # DEPTH VS LINEART IS SUBJECT-DEPENDENT, which the objective asks to test and
    # the first run demonstrated: the Matterhorn is defined by its OUTLINE, and
    # DepthAnything renders it as a near-black undifferentiated mass, so the
    # ControlNet had almost no geometry to hold and the silhouette was lost.
    # Lineart captures exactly the edge that depth throws away. Depth is still
    # right for layered scenes, where it gives the fore/mid/background banding a
    # poster is built from. Pair each with its matching --controlnet.
    # DEFAULTS ARE THE RECORDED RECIPE. They were depth / 0.7 / 0.8, which was
    # reasonable when Track B landed and is now the two known failures in one
    # invocation: depth hallucinates garbled display lettering on any subject
    # containing a town, and ip 0.8 is ABOVE the 0.7 measured to bleed the
    # reference's own content into the output — waterfalls under the Glacier
    # Express viaduct. That last one is Track A's failure arriving gently, in the
    # track that exists to avoid it, so a bare invocation must not reproduce it.
    ap.add_argument("--preprocessor", choices=["depth", "lineart"], default="lineart")
    ap.add_argument("--cn-strength", type=float, default=0.9,
                    help="how hard the depth map holds the geometry")
    ap.add_argument("--cn-end", type=float, default=0.8,
                    help="release the ControlNet before the end so late steps can "
                         "simplify shapes rather than tracing the depth map")
    ap.add_argument("--ip-weight", type=float, default=0.55,
                    help="how hard the style reference pulls")
    ap.add_argument("--positive", default=POSITIVE)
    # Per-image colour notes, appended to the positive prompt. This is what keeps a
    # subject's signature colour alive against the style reference's palette —
    # measured: "The train is bright scarlet red" is the difference between a red
    # Glacier Express and a blue-white one. Name only colours the photograph
    # actually has.
    #   glacier  "The train is bright scarlet red. The viaduct is pale grey-white stone."
    #   matterhorn "The mountain is grey stone with bright white snow. The lake is deep blue."
    ap.add_argument("--accent", default="",
                    help="per-image colour note appended to the positive prompt, "
                         "e.g. 'The train is bright scarlet red.'")
    ap.add_argument("--negative", default=NEGATIVE)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--steps", type=int, default=30)
    ap.add_argument("--cfg", type=float, default=6.0)
    ap.add_argument("--save-control", action="store_true",
                    help="also save the control map, suffixed with the preprocessor name")
    a = ap.parse_args()
    if a.controlnet is None:
        a.controlnet = CONTROLNETS[a.preprocessor]
    if a.accent:
        a.positive = f"{a.positive}. {a.accent}"
    print(f"{a.image} -> {a.prefix}  {a.preprocessor}/{a.controlnet} "
          f"cn={a.cn_strength} ip={a.ip_weight} cfg={a.cfg}")
    run(build(a))
