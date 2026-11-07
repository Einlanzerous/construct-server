#!/usr/bin/env python3
"""check-plimsoll-sandbox.py — keep Plimsoll's model sandbox isolated on every change (PLIM-14).

plimsoll-llm sees health facts in its prompts. What keeps them in is configuration,
and configuration drifts one reasonable-looking edit at a time: a port published to
debug, a second network to pull a model, an OLLAMA_DEBUG to chase a bug. Each one is
a leak, and none of them fails anything else. So this reads docker-compose.yml and
fails on any of them, as an ALLOWLIST: what is not named here is refused.

It fails when:

  * the plimsoll_ai network loses `internal: true`, the `isolated` IPv4 gateway mode,
    or `enable_ipv6: false`;
  * any service other than plimsoll and plimsoll-llm joins plimsoll_ai (or either of
    those two leaves it);
  * plimsoll-llm publishes or exposes a port, joins a second network, or uses
    network_mode;
  * plimsoll-llm loses its mem_limit, OLLAMA_MAX_LOADED_MODELS=1,
    OLLAMA_NUM_PARALLEL=1, its discrete-GPU-only device list, json-file logging
    capped at 10m x 3, or OLLAMA_NOHISTORY=1 / OLLAMA_NOPRUNE=1;
  * plimsoll-llm's env holds any key outside the exact allowlist, or it gains an
    env_file (which would bring keys this file cannot see);
  * plimsoll-llm's models volume is not mounted read-only;
  * plimsoll-llm's image is not the shared ollama service's exact pin (a seeded blob
    must be read by the version that wrote it);
  * plimsoll-llm sets any service key outside a fixed set (so `privileged`,
    `cap_add`, `pid`, `ipc`, `env_file`, a second bind mount and the like are refused
    by default, not by name), or mounts anything but its models volume;
  * any service shares plimsoll-llm's or plimsoll's network namespace through
    `network_mode: service:…` / `container:…` — that reaches the sandbox while
    `docker network inspect` still lists two members;
  * the shared ollama service loses its mem_limit (PLIM-14 ruling 6).

It proves configuration only. That the running network behaves is
`make plimsoll-llm-isolation`'s job; that the logs hold no prompt is
`make plimsoll-llm-canary`'s. scripts/test/test_check_plimsoll_sandbox.py proves
every failure above fires.

Usage:
  scripts/check-plimsoll-sandbox.py [docker-compose.yml]

Exit codes:
  0  the sandbox configuration holds
  1  a property is violated (each one is printed)
  2  usage / missing dependency / unreadable file
"""

import sys

try:
    import yaml
except ImportError:  # pragma: no cover
    print("ERROR: python3 PyYAML not installed", file=sys.stderr)
    sys.exit(2)

NETWORK = "plimsoll_ai"
SANDBOX = "plimsoll-llm"
CLIENT = "plimsoll"
SHARED = "ollama"
MEMBERS = {CLIENT, SANDBOX}
MODELS_TARGET = "/models"

# Exactly these keys, with these values where a value is load-bearing (None: any
# value). Anything else fails, which is what makes a debug, log-level or GIN_MODE
# key impossible to add quietly.
ENV_ALLOWLIST = {
    "OLLAMA_HOST": None,
    "OLLAMA_MODELS": MODELS_TARGET,
    "OLLAMA_NOPRUNE": "1",
    "OLLAMA_NOHISTORY": "1",
    "OLLAMA_MAX_LOADED_MODELS": "1",
    "OLLAMA_NUM_PARALLEL": "1",
    "OLLAMA_KEEP_ALIVE": None,
    "OLLAMA_CONTEXT_LENGTH": None,
}
# Values that must be present, not merely allowed.
ENV_REQUIRED = {k: v for k, v in ENV_ALLOWLIST.items() if v is not None}

# Every service-level key plimsoll-llm may set. Anything else fails: what widens a
# container is usually one key (privileged, cap_add, pid: host, a socket mount), and a
# denylist would have to have thought of it first.
SANDBOX_KEYS = {
    "image", "container_name", "restart", "environment", "volumes", "tmpfs",
    "read_only", "cap_drop", "security_opt", "devices", "group_add", "mem_limit",
    "logging", "networks", "healthcheck",
}
MODELS_VOLUME = "plimsoll_llm_models"

# The discrete GPU (the R9700) by PCI path, plus the KFD node ROCm needs. A bare
# /dev/dri would hand over the iGPU's nodes too, and a cardN/renderDN source would
# follow whichever card the kernel numbered first after a reboot.
GPU_PCI = "0000:03:00.0"
DEVICE_ALLOWLIST = {
    ("/dev/kfd", "/dev/kfd"),
    (f"/dev/dri/by-path/pci-{GPU_PCI}-card", "/dev/dri/card1"),
    (f"/dev/dri/by-path/pci-{GPU_PCI}-render", "/dev/dri/renderD129"),
}


def as_list_of_names(networks):
    if networks is None:
        return []
    if isinstance(networks, dict):
        return list(networks.keys())
    return list(networks)


def env_map(env):
    if env is None:
        return {}
    if isinstance(env, dict):
        return {k: (None if v is None else str(v)) for k, v in env.items()}
    out = {}
    for item in env:
        key, sep, val = str(item).partition("=")
        out[key] = val if sep else None
    return out


def device_pairs(devices):
    pairs = set()
    for d in devices or []:
        if isinstance(d, dict):
            src, dst = d.get("source", ""), d.get("target", d.get("source", ""))
        else:
            parts = str(d).split(":")
            src = parts[0]
            dst = parts[1] if len(parts) > 1 else src
        pairs.add((src, dst))
    return pairs


def truthy(v):
    return v is True or str(v).lower() == "true"


def check(compose):
    problems = []
    services = compose.get("services") or {}
    networks = compose.get("networks") or {}

    # --- the network -------------------------------------------------------
    net = networks.get(NETWORK)
    if not isinstance(net, dict):
        problems.append(f"network {NETWORK} is not defined")
        net = {}
    if not truthy(net.get("internal")):
        problems.append(f"network {NETWORK}: internal is not true")
    opts = net.get("driver_opts") or {}
    if opts.get("com.docker.network.bridge.gateway_mode_ipv4") != "isolated":
        problems.append(f"network {NETWORK}: gateway_mode_ipv4 is not isolated")
    if net.get("enable_ipv6") is not False:
        problems.append(f"network {NETWORK}: enable_ipv6 is not false")
    if net.get("external"):
        problems.append(f"network {NETWORK}: external, so this file no longer defines its options")
    if net.get("driver") not in (None, "bridge"):
        problems.append(f"network {NETWORK}: driver is {net.get('driver')!r}, not bridge")

    # --- membership --------------------------------------------------------
    joined = {name for name, svc in services.items()
              if NETWORK in as_list_of_names((svc or {}).get("networks"))}
    for name in sorted(joined - MEMBERS):
        problems.append(f"service {name} joins {NETWORK}; only {sorted(MEMBERS)} may")
    for name in sorted(MEMBERS - joined):
        problems.append(f"service {name} is not on {NETWORK}")
    # A shared namespace is membership the network's member list cannot show.
    for name, other in sorted(services.items()):
        mode = str((other or {}).get("network_mode") or "")
        kind, _, target = mode.partition(":")
        if kind in ("service", "container") and target in MEMBERS and name not in MEMBERS:
            problems.append(f"service {name} shares {target}'s network namespace (network_mode: {mode})")

    # --- the sandbox -------------------------------------------------------
    svc = services.get(SANDBOX)
    if not isinstance(svc, dict):
        problems.append(f"service {SANDBOX} is not defined")
        return problems
    for key in sorted(set(svc) - SANDBOX_KEYS):
        problems.append(f"{SANDBOX} sets {key}, which is outside its allowed keys")
    if svc.get("ports"):
        problems.append(f"{SANDBOX} publishes a port")
    if svc.get("expose"):
        problems.append(f"{SANDBOX} declares expose")
    if svc.get("network_mode"):
        problems.append(f"{SANDBOX} sets network_mode")
    nets = as_list_of_names(svc.get("networks"))
    if nets != [NETWORK]:
        problems.append(f"{SANDBOX} networks are {nets}; must be exactly [{NETWORK}]")
    if not svc.get("mem_limit"):
        problems.append(f"{SANDBOX} has no mem_limit")
    if svc.get("env_file"):
        problems.append(f"{SANDBOX} has an env_file, whose keys this check cannot see")

    env = env_map(svc.get("environment"))
    for key in sorted(set(env) - set(ENV_ALLOWLIST)):
        problems.append(f"{SANDBOX} env key {key} is outside the allowlist")
    for key, want in sorted(ENV_REQUIRED.items()):
        if env.get(key) != want:
            problems.append(f"{SANDBOX} env {key} must be {want}")

    have = device_pairs(svc.get("devices"))
    if have != DEVICE_ALLOWLIST:
        extra = sorted(have - DEVICE_ALLOWLIST)
        missing = sorted(DEVICE_ALLOWLIST - have)
        problems.append(f"{SANDBOX} devices are not the discrete-GPU-only list "
                        f"(extra {extra}, missing {missing})")

    logging = svc.get("logging") or {}
    lopts = logging.get("options") or {}
    if logging.get("driver") != "json-file":
        problems.append(f"{SANDBOX} logging driver is not json-file")
    if str(lopts.get("max-size")) != "10m" or str(lopts.get("max-file")) != "3":
        problems.append(f"{SANDBOX} logs are not capped at 10m x 3")

    models_ro = False
    for v in svc.get("volumes") or []:
        if isinstance(v, dict):
            src, dst, ro = v.get("source"), v.get("target"), truthy(v.get("read_only"))
        else:
            parts = str(v).split(":")
            src = parts[0]
            dst = parts[1] if len(parts) > 1 else parts[0]
            ro = len(parts) >= 3 and "ro" in parts[2].split(",")
        if src == MODELS_VOLUME and dst == MODELS_TARGET and ro:
            models_ro = True
        else:
            problems.append(f"{SANDBOX} mounts {src}:{dst}; only {MODELS_VOLUME} at {MODELS_TARGET} (read-only) is allowed")
    if not models_ro:
        problems.append(f"{SANDBOX} does not mount its models volume read-only at {MODELS_TARGET}")

    tmpfs = svc.get("tmpfs") or []
    tmpfs = [tmpfs] if isinstance(tmpfs, str) else tmpfs
    if not any(str(t).split(":")[0] == "/root/.ollama" for t in tmpfs):
        problems.append(f"{SANDBOX} has no tmpfs at /root/.ollama")

    # --- the shared instance -----------------------------------------------
    shared = services.get(SHARED)
    if not isinstance(shared, dict):
        problems.append(f"service {SHARED} is not defined")
    else:
        if not shared.get("mem_limit"):
            problems.append(f"{SHARED} (the shared instance) has no mem_limit")
        if shared.get("image") != svc.get("image") or "@sha256:" not in str(svc.get("image")):
            problems.append(f"{SANDBOX} image is not the shared {SHARED} service's digest pin")

    return problems


def main(argv):
    path = argv[1] if len(argv) > 1 else "docker-compose.yml"
    if len(argv) > 2:
        print(__doc__.split("Usage:")[1].split("Exit codes:")[0].strip(), file=sys.stderr)
        return 2
    try:
        with open(path, encoding="utf-8") as fh:
            compose = yaml.safe_load(fh)
    except (OSError, yaml.YAMLError) as err:
        print(f"ERROR: cannot read {path}: {err}", file=sys.stderr)
        return 2
    problems = check(compose or {})
    if problems:
        for p in problems:
            print(f"FAIL: {p}")
        print(f"\n{len(problems)} problem(s) with the Plimsoll model sandbox (PLIM-14).")
        return 1
    print(f"OK: {NETWORK}, {SANDBOX} and the shared instance's ceiling hold.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
