#!/usr/bin/env python3
"""Measure every MCP's tools/list: tool count, JSON bytes, estimated tokens (SERV-263).

Spawns each service in scripts/mcp-tools-baseline.json as a stdio MCP server,
runs `initialize` + `tools/list` (following pagination), and records per service:

  tools   number of tools listed
  bytes   size of the compact JSON of the `tools` array (UTF-8)
  tokens  ESTIMATE = chars / 3.5, rounded up. A heuristic, not a tokenizer
          count; a real model's tokenizer will differ.

Modes:
  (default)  print the measurement table
  --update   rewrite docs/records/mcp-tools-baseline.json
  --check    measure and compare with the committed baseline; a difference is
             reported (and written to $GITHUB_STEP_SUMMARY) but only a service that
             cannot be measured fails the run. Counts move whenever a service
             adds a tool, so drift is a record to refresh, not a gate.

EXTENSION POINT (SERV-267, per-bundle budget): bundles do not exist yet. When
they do, add a `budget_tokens` per bundle to the config and fail in
`check_budgets()` below. Nothing enforces a budget today, on purpose.
"""
import argparse, json, math, os, select, subprocess, sys, tempfile, threading, time
from http.server import BaseHTTPRequestHandler, HTTPServer

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONFIG = os.path.join(ROOT, "scripts", "mcp-tools-baseline.json")
BASELINE = os.path.join(ROOT, "docs", "records", "mcp-tools-baseline.json")
CHARS_PER_TOKEN = 3.5
TIMEOUT = 60


class Client:
    def __init__(self, argv, env):
        self.err = tempfile.TemporaryFile()
        self.p = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=self.err, env=env)
        self.n = 0
        self.buf = b""

    def _read_line(self, deadline):
        while b"\n" not in self.buf:
            left = deadline - time.time()
            if left <= 0 or not select.select([self.p.stdout], [], [], left)[0]:
                raise TimeoutError("no reply from server")
            chunk = os.read(self.p.stdout.fileno(), 1 << 20)
            if not chunk:
                raise RuntimeError("server closed stdout (exit %s)" % self.p.poll())
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        return line

    def send(self, msg):
        self.p.stdin.write((json.dumps(msg) + "\n").encode())
        self.p.stdin.flush()

    def call(self, method, params=None):
        self.n += 1
        self.send({"jsonrpc": "2.0", "id": self.n, "method": method, "params": params or {}})
        deadline = time.time() + TIMEOUT
        while True:
            line = self._read_line(deadline).strip()
            if not line:
                continue
            msg = json.loads(line)
            if msg.get("id") == self.n:
                if "error" in msg:
                    raise RuntimeError("%s: %s" % (method, msg["error"]))
                return msg["result"]

    def stderr_tail(self, n=2000):
        self.err.seek(0)
        return self.err.read().decode(errors="replace")[-n:]

    def close(self):
        try:
            self.p.stdin.close()
            self.p.wait(timeout=5)
        except Exception:
            self.p.kill()


def serve_me(body):
    """Loopback stub for GET /auth/me, for servers that resolve their identity at boot."""
    data = json.dumps(body).encode()

    class H(BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *a):
            pass

    srv = HTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


def measure(name, svc, tmp):
    src = os.path.abspath(os.path.join(ROOT, os.environ.get(svc["src_env"]) or svc["src_default"]))
    if not os.path.isdir(src):
        raise RuntimeError("source checkout not found (set %s)" % svc["src_env"])
    sub = lambda a: [x.replace("{src}", src).replace("{tmp}", tmp) for x in a]
    if svc.get("prepare"):
        subprocess.run(sub(svc["prepare"]), check=True, stdout=sys.stderr)
    env = dict(os.environ)
    env.update(svc.get("env", {}))
    stub = None
    if svc.get("stub_me"):
        stub = serve_me(svc["stub_me"])
        env[svc["url_env"]] = "http://127.0.0.1:%d" % stub.server_port
    c = Client(sub(svc["command"]), env)
    try:
        try:
            return _list(c, src)
        except Exception as e:
            c.close()
            raise RuntimeError("%s\n--- server stderr (tail) ---\n%s" % (e, c.stderr_tail()))
    finally:
        if stub:
            stub.shutdown()


def _list(c, src):
    try:
        init = c.call("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                     "clientInfo": {"name": "measure-mcp-tools", "version": "1"}})
        c.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        tools, cursor = [], None
        while True:
            r = c.call("tools/list", {"cursor": cursor} if cursor else {})
            tools += r["tools"]
            cursor = r.get("nextCursor")
            if not cursor:
                break
    finally:
        c.close()
    blob = json.dumps(tools, separators=(",", ":"), ensure_ascii=False)
    return {
        "tools": len(tools),
        "bytes": len(blob.encode()),
        "est_tokens": math.ceil(len(blob) / CHARS_PER_TOKEN),
        "source_commit": git_head(src),
        "server": (init.get("serverInfo") or {}).get("name"),
    }


def git_head(src):
    r = subprocess.run(["git", "-C", src, "rev-parse", "HEAD"], capture_output=True, text=True)
    return r.stdout.strip() or "unknown"


def check_budgets(results):
    """Extension point (SERV-267): fail a bundle over its recorded budget. No-op today."""
    return []


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--update", action="store_true", help="rewrite the committed baseline")
    ap.add_argument("--check", action="store_true", help="compare with the committed baseline")
    a = ap.parse_args()
    cfg = json.load(open(CONFIG))["services"]
    results, failed = {}, []
    with tempfile.TemporaryDirectory() as tmp:
        for name, svc in cfg.items():
            try:
                results[name] = measure(name, svc, tmp)
            except Exception as e:
                failed.append(name)
                print("FAIL %s: %s" % (name, e), file=sys.stderr)
    rows = ["| service | tools | JSON bytes | est. tokens (chars/3.5) | source commit |", "|---|---|---|---|---|"]
    rows += ["| %s | %d | %d | %d | %s |" % (n, r["tools"], r["bytes"], r["est_tokens"], r["source_commit"][:12]) for n, r in results.items()]
    print("\n".join(rows))
    record = {"_comment": "Generated by scripts/measure-mcp-tools.py --update (SERV-263). "
              "est_tokens is chars/3.5, an estimate and not a tokenizer count.",
              "services": {n: {k: r[k] for k in ("tools", "bytes", "est_tokens", "source_commit")} for n, r in results.items()}}
    if a.update and not failed:
        json.dump(record, open(BASELINE, "w"), indent=2)
        open(BASELINE, "a").write("\n")
        print("wrote", os.path.relpath(BASELINE, ROOT))
    drift = []
    if a.check and os.path.exists(BASELINE):
        old = json.load(open(BASELINE))["services"]
        for n, r in record["services"].items():
            o = old.get(n) or {}
            if {k: v for k, v in o.items() if k != "source_commit"} != {k: v for k, v in r.items() if k != "source_commit"}:
                drift.append("%s: baseline %s, now %s" % (n, old.get(n), r))
    if drift:
        print("\nDRIFT from committed baseline (refresh with --update; not a failure):\n" + "\n".join(drift))
    summ = os.environ.get("GITHUB_STEP_SUMMARY")
    if summ:
        with open(summ, "a") as f:
            f.write("## MCP tools/list\n\n" + "\n".join(rows) + "\n")
            if drift:
                f.write("\nDrift from the committed baseline (refresh with `--update`):\n\n"
                        + "\n".join("- " + d for d in drift) + "\n")
    over = check_budgets(results)
    if over:
        print("\n".join(over), file=sys.stderr)
    sys.exit(1 if failed or over else 0)


if __name__ == "__main__":
    main()
