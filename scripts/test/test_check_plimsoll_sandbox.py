#!/usr/bin/env python3
"""Prove scripts/check-plimsoll-sandbox.py still goes RED (PLIM-14, criterion 1).

A check that has quietly stopped firing looks exactly like a sandbox that is still
isolated, so every failure it claims is produced here. Each case starts from the REAL
docker-compose.yml, which must pass, applies one drift and asserts the check names
it. A small hand-written fixture also passes, so the check does not depend on
anything incidental in the real file.

Run: python3 scripts/test/test_check_plimsoll_sandbox.py   (or `make plimsoll-sandbox-test`)
"""

import copy
import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
SCRIPT = os.path.join(ROOT, "scripts", "check-plimsoll-sandbox.py")
FIXTURE = os.path.join(HERE, "plimsoll-sandbox", "minimal.yml")

spec = importlib.util.spec_from_file_location("check_sandbox", SCRIPT)
check_sandbox = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check_sandbox)


def load(path):
    with open(path, encoding="utf-8") as fh:
        return yaml.safe_load(fh)


def env_set(svc, key, value):
    env = svc["environment"]
    if isinstance(env, dict):
        env.pop(key, None)
        if value is not None:
            env[key] = value
        return
    env = [e for e in env if not str(e).startswith(key + "=")]
    if value is not None:
        env.append(f"{key}={value}")
    svc["environment"] = env


def drop_env(key):
    return lambda c: env_set(c["services"]["plimsoll-llm"], key, None)


def add_env(key, value):
    return lambda c: env_set(c["services"]["plimsoll-llm"], key, value)


def set_path(path, value):
    def apply(c):
        node = c
        for k in path[:-1]:
            node = node[k]
        if value is DELETE:
            node.pop(path[-1], None)
        else:
            node[path[-1]] = value
    return apply


DELETE = object()
LLM = ("services", "plimsoll-llm")
NET = ("networks", "plimsoll_ai")


def join_network(service):
    def apply(c):
        nets = c["services"][service].get("networks") or []
        if isinstance(nets, dict):
            nets["plimsoll_ai"] = None
        else:
            c["services"][service]["networks"] = list(nets) + ["plimsoll_ai"]
    return apply


def leave_network(service):
    def apply(c):
        nets = c["services"][service]["networks"]
        c["services"][service]["networks"] = [n for n in nets if n != "plimsoll_ai"]
    return apply


# (name, drift, a fragment the failure message must contain)
CASES = [
    ("network not internal", set_path(NET + ("internal",), False), "internal is not true"),
    ("network internal removed", set_path(NET + ("internal",), DELETE), "internal is not true"),
    ("gateway mode removed", set_path(NET + ("driver_opts",), DELETE), "gateway_mode_ipv4 is not isolated"),
    ("gateway mode nat", set_path(NET + ("driver_opts",), {"com.docker.network.bridge.gateway_mode_ipv4": "nat"}),
     "gateway_mode_ipv4 is not isolated"),
    ("ipv6 enabled", set_path(NET + ("enable_ipv6",), True), "enable_ipv6 is not false"),
    ("ipv6 key removed", set_path(NET + ("enable_ipv6",), DELETE), "enable_ipv6 is not false"),
    ("network made external", set_path(NET + ("external",), True), "external"),
    ("network removed", set_path(NET, DELETE), "is not defined"),
    ("another service joins", join_network("ollama"), "service ollama joins plimsoll_ai"),
    ("open-webui joins", join_network("open-webui"), "service open-webui joins plimsoll_ai"),
    ("plimsoll leaves", leave_network("plimsoll"), "service plimsoll is not on plimsoll_ai"),
    ("sandbox publishes a port", set_path(LLM + ("ports",), ["11435:11434"]), "publishes a port"),
    ("sandbox exposes a port", set_path(LLM + ("expose",), ["11434"]), "declares expose"),
    ("sandbox joins a second network", set_path(LLM + ("networks",), ["plimsoll_ai", "construct_net"]),
     "must be exactly [plimsoll_ai]"),
    ("sandbox uses host networking", set_path(LLM + ("network_mode",), "host"), "network_mode"),
    ("sandbox loses mem_limit", set_path(LLM + ("mem_limit",), DELETE), "plimsoll-llm has no mem_limit"),
    ("sandbox loses MAX_LOADED_MODELS", drop_env("OLLAMA_MAX_LOADED_MODELS"), "OLLAMA_MAX_LOADED_MODELS must be 1"),
    ("sandbox MAX_LOADED_MODELS=2", add_env("OLLAMA_MAX_LOADED_MODELS", "2"), "OLLAMA_MAX_LOADED_MODELS must be 1"),
    ("sandbox loses NUM_PARALLEL", drop_env("OLLAMA_NUM_PARALLEL"), "OLLAMA_NUM_PARALLEL must be 1"),
    ("sandbox loses NOHISTORY", drop_env("OLLAMA_NOHISTORY"), "OLLAMA_NOHISTORY must be 1"),
    ("sandbox loses NOPRUNE", drop_env("OLLAMA_NOPRUNE"), "OLLAMA_NOPRUNE must be 1"),
    ("OLLAMA_DEBUG added", add_env("OLLAMA_DEBUG", "1"), "OLLAMA_DEBUG is outside the allowlist"),
    ("GIN_MODE added", add_env("GIN_MODE", "debug"), "GIN_MODE is outside the allowlist"),
    ("log level added", add_env("OLLAMA_LOG_LEVEL", "debug"), "OLLAMA_LOG_LEVEL is outside the allowlist"),
    ("env_file added", set_path(LLM + ("env_file",), [".env"]), "env_file"),
    ("whole /dev/dri", set_path(LLM + ("devices",), ["/dev/kfd", "/dev/dri"]), "discrete-GPU-only"),
    ("iGPU node added", lambda c: c["services"]["plimsoll-llm"]["devices"].append("/dev/dri/renderD128"),
     "discrete-GPU-only"),
    ("render node by number", set_path(LLM + ("devices",), [
        "/dev/kfd",
        {"source": "/dev/dri/by-path/pci-0000:03:00.0-card", "target": "/dev/dri/card1"},
        "/dev/dri/renderD129"]), "discrete-GPU-only"),
    ("logging driver local", set_path(LLM + ("logging", "driver"), "local"), "logging driver is not json-file"),
    ("logging removed", set_path(LLM + ("logging",), DELETE), "logging driver is not json-file"),
    ("log cap raised", set_path(LLM + ("logging", "options", "max-size"), "100m"), "not capped at 10m x 3"),
    ("models volume writable", set_path(LLM + ("volumes",), ["plimsoll_llm_models:/models"]), "read-only"),
    ("tmpfs removed", set_path(LLM + ("tmpfs",), DELETE), "tmpfs at /root/.ollama"),
    ("image drifts from shared pin", set_path(LLM + ("image",), "ollama/ollama:rocm"), "digest pin"),
    ("shared ollama loses mem_limit", set_path(("services", "ollama", "mem_limit"), DELETE),
     "ollama (the shared instance) has no mem_limit"),
    ("sandbox removed", set_path(LLM, DELETE), "plimsoll-llm"),
]


class RealFilePasses(unittest.TestCase):
    def test_real_compose_passes(self):
        self.assertEqual(check_sandbox.check(load(os.path.join(ROOT, "docker-compose.yml"))), [])

    def test_minimal_fixture_passes(self):
        self.assertEqual(check_sandbox.check(load(FIXTURE)), [])


class EachDriftFails(unittest.TestCase):
    pass


def make_case(base_path, name, drift, fragment):
    def test(self):
        compose = copy.deepcopy(load(base_path))
        drift(compose)
        problems = check_sandbox.check(compose)
        self.assertTrue(any(fragment in p for p in problems),
                        f"{name}: expected a failure containing {fragment!r}, got {problems}")
    return test


for base_name, base_path in (("real", os.path.join(ROOT, "docker-compose.yml")), ("fixture", FIXTURE)):
    for case_name, drift, fragment in CASES:
        attr = "test_" + base_name + "_" + case_name.replace(" ", "_").replace("/", "_").replace("-", "_")
        setattr(EachDriftFails, attr, make_case(base_path, case_name, drift, fragment))


class ExitCodes(unittest.TestCase):
    """The CLI, not just the function: CI reads the exit code."""

    def run_script(self, compose):
        with tempfile.NamedTemporaryFile("w", suffix=".yml", delete=False) as fh:
            yaml.safe_dump(compose, fh)
            path = fh.name
        try:
            return subprocess.run([sys.executable, SCRIPT, path], capture_output=True, text=True)
        finally:
            os.unlink(path)

    def test_pass_is_zero(self):
        self.assertEqual(self.run_script(load(FIXTURE)).returncode, 0)

    def test_failure_is_one(self):
        compose = load(FIXTURE)
        compose["services"]["plimsoll-llm"]["ports"] = ["11434:11434"]
        res = self.run_script(compose)
        self.assertEqual(res.returncode, 1)
        self.assertIn("publishes a port", res.stdout)

    def test_unreadable_is_two(self):
        res = subprocess.run([sys.executable, SCRIPT, "/nonexistent/compose.yml"], capture_output=True, text=True)
        self.assertEqual(res.returncode, 2)


if __name__ == "__main__":
    unittest.main(verbosity=1)
