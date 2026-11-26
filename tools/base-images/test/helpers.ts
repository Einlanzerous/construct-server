import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

// The tests drive the programs as black boxes: a child process, a mock `gh` and `git` on
// PATH, and the files and exit codes that come back. Nothing here imports the program.
export const HERE = dirname(fileURLToPath(import.meta.url));
export const TOOL = resolve(HERE, "..");
export const ROOT = resolve(TOOL, "../..");
export const CHECK = join(TOOL, "src/check.ts");
export const SWEEP = join(TOOL, "src/sweep.ts");
export const PUBLISH = join(TOOL, "src/publish.ts");
export const MOCK = join(HERE, "mock-bin");

export interface Result {
  rc: number;
  out: string;
  err: string;
}

export type Env = Record<string, string | undefined>;

// The caller's environment minus everything that steers the programs: a test run inside a
// hosted CI job must not inherit that job's redaction or tokens.
const STEERING = [
  "GITHUB_ACTIONS",
  "CI",
  "GITHUB_STEP_SUMMARY",
  "GITHUB_OUTPUT",
  "GH_TOKEN",
  "GITHUB_TOKEN",
  "PRIVACY_GH_TOKEN",
  "PUBLISH_GH_TOKEN",
  "PUBLISH_REMOTE",
  "RUNNER_TEMP",
  "BASE_IMAGE_POLICY_DIR",
  "BASE_IMAGE_TODAY",
  "BASE_IMAGE_WARN_DAYS",
  "BASE_IMAGE_API",
  "BASE_IMAGES_CHECK",
  "MOCK_GH_DIR",
  "SHIM_LOG",
  "SHIM_RACE_FROM",
  "SHIM_RACE_TO",
];

export function cleanEnv(extra: Env = {}): NodeJS.ProcessEnv {
  const env: NodeJS.ProcessEnv = { ...process.env };
  for (const k of STEERING) delete env[k];
  for (const [k, v] of Object.entries(extra)) {
    if (v === undefined) delete env[k];
    else env[k] = v;
  }
  return env;
}

export function run(script: string, args: string[], env: Env = {}): Result {
  const r = spawnSync(process.execPath, [script, ...args], { env: cleanEnv(env), encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
  return { rc: r.status ?? -1, out: r.stdout, err: r.stderr };
}

export const withMocks = (env: Env = {}): Env => ({ ...env, PATH: `${MOCK}:${process.env["PATH"]}` });

export function tempDir(prefix: string): string {
  return mkdtempSync(join(tmpdir(), `${prefix}-`));
}

export function cleanup(dir: string): void {
  rmSync(dir, { recursive: true, force: true });
}

export function write(path: string, text: string): string {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, text);
  return path;
}

// The fixture policy: what endoflife.date would have said on 2026-09-11.
export function writePolicy(dir: string): string {
  const policy = join(dir, "policy");
  const put = (name: string, releases: unknown): void => {
    write(join(policy, `${name}.json`), JSON.stringify({ result: { name, releases } }));
  };
  put("alpine-linux", [
    { name: "3.23", codename: null, isEol: false, eolFrom: "2027-11-01" },
    { name: "3.22", codename: null, isEol: false, eolFrom: "2026-11-01" },
    { name: "3.20", codename: null, isEol: true, eolFrom: "2026-04-01" },
  ]);
  put("nginx", [
    { name: "1.31", codename: null, isEol: false, eolFrom: null, releaseDate: "2026-05-01" },
    { name: "1.30", codename: null, isEol: false, eolFrom: null, releaseDate: "2026-04-01" },
    { name: "1.29", codename: null, isEol: true, eolFrom: "2026-05-13", releaseDate: "2025-11-01" },
  ]);
  put("go", [
    { name: "1.27", codename: null, isEol: false, eolFrom: null, releaseDate: "2026-08-19" },
    { name: "1.26", codename: null, isEol: false, eolFrom: null, releaseDate: "2026-02-10" },
    { name: "1.25", codename: null, isEol: true, eolFrom: "2026-08-19", releaseDate: "2025-08-12" },
  ]);
  put("debian", [
    { name: "13", codename: "Trixie", isEol: false, eolFrom: "2030-06-30" },
    { name: "12", codename: "Bookworm", isEol: false, eolFrom: "2028-06-30" },
  ]);
  put("ubuntu", [{ name: "24.04", codename: "Noble Numbat", isEol: false, eolFrom: "2029-05-31" }]);
  return policy;
}

export const TODAY = "2026-09-11";

// A run of check.ts with the fixture policy and clock.
export function check(policy: string, args: string[], env: Env = {}): Result {
  return run(CHECK, args, { BASE_IMAGE_POLICY_DIR: policy, BASE_IMAGE_TODAY: TODAY, ...env });
}

// The mock gh's fixture tree (see mock-bin/gh): one directory per repo.
export class Estate {
  readonly dir: string;
  constructor(dir: string) {
    this.dir = join(dir, "gh");
    mkdirSync(this.dir, { recursive: true });
  }
  /** visibility: false | true | 404 | 500 | none (no file: 404 to the privacy token). */
  repo(name: string, visibility: string, files: Record<string, string> = {}, opts: { treeFail?: boolean; failPaths?: string[] } = {}): void {
    const d = join(this.dir, name);
    mkdirSync(join(d, "files"), { recursive: true });
    mkdirSync(join(d, "fail"), { recursive: true });
    write(join(d, "tree"), "");
    if (visibility !== "none") write(join(d, "vis.public-token"), visibility);
    if (opts.treeFail) write(join(d, "tree.fail"), "");
    let tree = "";
    for (const [path, body] of Object.entries(files)) {
      write(join(d, "files", path), `${body}\n`);
      tree += `${path}\n`;
    }
    write(join(d, "tree"), tree);
    for (const p of opts.failPaths ?? []) write(join(d, "fail", p), "");
  }
  /** A compose file whose ghcr.io images name these repos. */
  compose(name: string, repos: string[]): string {
    const lines = ["services:"];
    for (const r of repos) lines.push(`  ${r}:`, `    image: ghcr.io/einlanzerous/${r}:1`);
    return write(join(this.dir, "..", `compose-${name}.yml`), `${lines.join("\n")}\n`);
  }
  /** The three repos EXTRA_REPOS always adds. */
  extras(): void {
    this.repo("construct-server", "false", { Dockerfile: "FROM alpine:3.23" });
    this.repo("signet", "false");
    this.repo("cta-watch", "false");
  }
}

export function estateRun(policy: string, estate: Estate, compose: string, flags: string[] = [], env: Env = {}): Result {
  return check(policy, [...flags, "--estate", compose], withMocks({ MOCK_GH_DIR: estate.dir, GH_TOKEN: "sweep-token", PRIVACY_GH_TOKEN: "public-token", ...env }));
}
