import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export const HERE = dirname(fileURLToPath(import.meta.url));
export const TOOL = resolve(HERE, "..");
export const ROOT = resolve(TOOL, "../..");
export const SCRIPT = join(ROOT, "scripts/architecture-map-check.sh");

// Every repo name in this package's fixtures is synthetic: construct-server is public, so a
// private repo's name must never be written into a test. The one real name is the script's own
// default slug, which the goldens need because the pre-change script has no other.
export const DEFAULT_SLUG = "einlanzerous/construct-server";
export const OTHER_SLUG = "example-org/widget-service";

export type Env = Record<string, string>;

// The environment the script runs in is built here and never inherited: the construct-server
// `test` job runs with GITHUB_ACTIONS set, a developer machine without it, and the script prints
// annotations or plain lines on that one variable. Fixed dates and identities make the commit
// SHAs, which the script prints, the same on every machine.
export function baseEnv(home: string, extra: Env = {}): Env {
  return {
    PATH: "/usr/local/bin:/usr/bin:/bin",
    HOME: home,
    LC_ALL: "C",
    GIT_CONFIG_GLOBAL: "/dev/null",
    GIT_CONFIG_NOSYSTEM: "1",
    GIT_TERMINAL_PROMPT: "0",
    GIT_AUTHOR_NAME: "Fixture",
    GIT_AUTHOR_EMAIL: "fixture@example.invalid",
    GIT_COMMITTER_NAME: "Fixture",
    GIT_COMMITTER_EMAIL: "fixture@example.invalid",
    ...extra,
  };
}

export interface Run {
  rc: number | null;
  out: string;
  err: string;
  signal: NodeJS.Signals | null;
}

export function git(cwd: string, args: string[], env: Env): string {
  const r = spawnSync("git", args, { cwd, env, encoding: "utf8" });
  if (r.status !== 0) throw new Error(`git ${args.join(" ")}: ${r.stderr}`);
  return r.stdout.trim();
}

export interface SourceRef {
  path: string;
  line?: number;
  end_line?: number;
}

export interface MapSpec {
  url: string;
  // A 40-hex revision. "pin" means the first commit; anything else is used verbatim.
  revision: "pin" | string;
  components: { id: string; sources: SourceRef[] }[];
}

export interface FixtureSpec {
  // Written to docs/architecture.archify.json when present, committed after the pin.
  map?: MapSpec | string;
  // Appended to a.txt after the map commit, so the cited file has moved on since the pin.
  driftAfter?: boolean;
}

const FILES: Record<string, string> = {
  "a.txt": "one\ntwo\nthree\n",
  "b.txt": "alpha\nbeta\n",
};

// A real git repository, built from nothing: no network, no clone of anything else.
export function makeRepo(root: string, name: string, spec: FixtureSpec, home: string): string {
  const dir = join(root, name);
  mkdirSync(dir, { recursive: true });
  let tick = 0;
  const env = (): Env => {
    const d = `2026-01-01T00:00:0${tick++}Z`;
    return baseEnv(home, { GIT_AUTHOR_DATE: d, GIT_COMMITTER_DATE: d });
  };
  git(dir, ["init", "-q", "-b", "main"], env());
  for (const [f, body] of Object.entries(FILES)) writeFileSync(join(dir, f), body);
  git(dir, ["add", "."], env());
  git(dir, ["commit", "-q", "-m", "sources"], env());
  const pin = git(dir, ["rev-parse", "HEAD"], env());
  if (spec.map !== undefined) {
    mkdirSync(join(dir, "docs"), { recursive: true });
    const body =
      typeof spec.map === "string"
        ? spec.map
        : JSON.stringify({
            meta: {
              repository: {
                url: spec.map.url,
                revision: spec.map.revision === "pin" ? pin : spec.map.revision,
              },
            },
            components: spec.map.components,
          });
    writeFileSync(join(dir, "docs/architecture.archify.json"), body);
    git(dir, ["add", "."], env());
    git(dir, ["commit", "-q", "-m", "map"], env());
  }
  if (spec.driftAfter) {
    writeFileSync(join(dir, "a.txt"), `${FILES["a.txt"]}four\n`);
    git(dir, ["commit", "-q", "-am", "drift"], env());
  }
  return dir;
}

export function tempRoot(): string {
  return mkdtempSync(join(tmpdir(), "arch-maps-"));
}

export function runScript(cwd: string, env: Env, script = SCRIPT, timeoutMs = 20000): Run {
  const r = spawnSync("bash", [script], { cwd, env, encoding: "utf8", timeout: timeoutMs, killSignal: "SIGKILL" });
  return { rc: r.status, out: r.stdout, err: r.stderr, signal: r.signal };
}

// The scenarios the goldens and the state tests share. `slug` is the owner/name the map claims.
export function scenarios(slug: string): Record<string, FixtureSpec> {
  const url = `https://github.com/${slug}`;
  const one = [{ id: "svc", sources: [{ path: "a.txt", line: 1, end_line: 2 }] }];
  return {
    no_map: {},
    in_sync: { map: { url, revision: "pin", components: one } },
    stale: { map: { url, revision: "pin", components: one }, driftAfter: true },
    broken_path_absent: {
      map: { url, revision: "pin", components: [{ id: "svc", sources: [{ path: "gone.txt" }] }] },
    },
    broken_line_past_eof: {
      map: { url, revision: "pin", components: [{ id: "svc", sources: [{ path: "b.txt", line: 9 }] }] },
    },
    broken_four_sources: {
      map: {
        url,
        revision: "pin",
        components: [
          {
            id: "svc",
            sources: [{ path: "a.txt" }, { path: "b.txt" }, { path: "a.txt", line: 1 }, { path: "b.txt", line: 1 }],
          },
        ],
      },
    },
    broken_wrong_url: {
      map: { url: "https://github.com/example-org/someone-else", revision: "pin", components: one },
    },
    broken_not_json: { map: "{ not json" },
    skipped_pin_absent: {
      map: { url, revision: "0123456789abcdef0123456789abcdef01234567", components: one },
    },
  };
}
