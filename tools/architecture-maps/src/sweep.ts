#!/usr/bin/env node
// sweep.ts — the estate architecture-map sweep (SERV-356): run scripts/architecture-map-check.sh
// over a fresh clone of every first-party repo and write one document, private data and all, for
// the publisher to push to a private repository.
//
// The rule is the script's and is defined nowhere else (SERV-111: two definitions drift). This
// program clones, hands the script its slug and a result file, and reads the one JSON line back.
//
// WHAT IT REFUSES. Nothing here is filtered or redacted, so the sweep refuses (exit 2, before it
// reads a thing) unless the repository it is running in is confirmed private, asked with the
// workflow's own GITHUB_TOKEN through the publisher's destination lock. The lock is not
// `repoVisibility`: that function reads a 404 as "private".
//
// WHAT IT NEVER FORWARDS. The child's stdout and stderr are captured and dropped: a map is
// untrusted text, and an `::error::` line in one would become a workflow command in this run. The
// log holds one `repo state` line per repo and nothing from a clone. GITHUB_ACTIONS is not in the
// child's environment either, so the script prints plain lines whatever job this is.
//
// THE CREDENTIAL. The read token reaches git only as an http extraheader in the environment
// (GIT_CONFIG_*), never in argv or a URL. The check script gets that same environment on purpose:
// its `ensure_pinned` runs `git fetch origin <pin>` inside a depth-1 clone, which almost never
// holds the pin, so without the credential every private repo would read `skipped`. That is safe
// because the token is read-only and the child runs only git, jq and bash from this checkout:
// nothing from a cloned repo executes, and core.hooksPath is /dev/null.
//
// A missing ESTATE_READ_TOKEN is not an error: the sweep runs unauthenticated, says so, and every
// repo that needs the token reads `unreadable` or `skipped`, never `no_map`.
//
// EXIT: 0 a document was written and every repo was read; 1 a document was written and at least
// one repo is `unreadable` (a broken or stale map is data, not a red run); 2 no document.
// `published=true` goes to $GITHUB_OUTPUT whenever a document exists, so a red run still
// publishes it.
//
// ENV
//   RUNNER_TEMP, GITHUB_OUTPUT, GITHUB_REPOSITORY   required
//   GITHUB_TOKEN        the workflow's token, used only for the destination lock
//   ESTATE_READ_TOKEN   read-only token for the clones and the pin fetch
//   ARCH_MAPS_COMPOSE   compose file to derive the repo list from (default: this checkout's)
//   ARCH_MAPS_CLONE_TIMEOUT_MS, ARCH_MAPS_CHECK_TIMEOUT_MS   per-repo deadlines
import { spawnSync } from "node:child_process";
import { appendFileSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { isPrivateDestination } from "../../base-images/src/destination.ts";
import { die, Refusal } from "../../base-images/src/errors.ts";
import { estateRepos, GITHUB_OWNER } from "../../base-images/src/estate.ts";
import { stderr, stdout } from "../../base-images/src/io.ts";
import { parseResult, summarise, UNREAD, type Row } from "./result.ts";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(HERE, "../../..");
const CHECK_SCRIPT = join(REPO_ROOT, "scripts/architecture-map-check.sh");

function deadline(name: string, fallback: number): number {
  const v = process.env[name];
  if (v === undefined) return fallback;
  if (!/^[1-9]\d{0,8}$/.test(v)) die(`${name} must be a positive number of milliseconds`);
  return Number(v);
}

function main(): number {
  const runnerTemp = process.env["RUNNER_TEMP"] ?? "";
  const githubOutput = process.env["GITHUB_OUTPUT"] ?? "";
  if (runnerTemp === "") die("RUNNER_TEMP is not set (nothing is written to a fixed path)");
  if (githubOutput === "") die("GITHUB_OUTPUT is not set");

  // Before any clone: the document holds private repo names and must never exist in a public repo.
  if (!isPrivateDestination(process.env["GITHUB_TOKEN"] ?? "")) {
    die("this repository is not confirmed private (GET repos/$GITHUB_REPOSITORY must answer private:true); refusing to sweep");
  }
  const cloneMs = deadline("ARCH_MAPS_CLONE_TIMEOUT_MS", 120_000);
  const checkMs = deadline("ARCH_MAPS_CHECK_TIMEOUT_MS", 120_000);

  const composeEnv = process.env["ARCH_MAPS_COMPOSE"];
  if (composeEnv === "") die("ARCH_MAPS_COMPOSE is set but empty; unset it to use this checkout's docker-compose.yml");
  // An exit 2 on a compose file that names no image, from estateRepos itself.
  const repos = estateRepos(composeEnv ?? join(REPO_ROOT, "docker-compose.yml"));

  const outDir = join(runnerTemp, "out");
  const out = join(outDir, "architecture-maps.json");
  const work = join(runnerTemp, "architecture-maps-work");
  rmSync(work, { recursive: true, force: true });
  mkdirSync(outDir, { recursive: true });
  mkdirSync(join(work, "home"), { recursive: true });
  mkdirSync(join(work, "results"), { recursive: true });
  // A leftover from an earlier step must never read as this run's document.
  rmSync(out, { force: true });

  const token = process.env["ESTATE_READ_TOKEN"] ?? "";
  const gitEnv: NodeJS.ProcessEnv = {
    PATH: process.env["PATH"] ?? "",
    HOME: join(work, "home"),
    LC_ALL: "C",
    GIT_CONFIG_GLOBAL: "/dev/null",
    GIT_CONFIG_NOSYSTEM: "1",
    GIT_TERMINAL_PROMPT: "0",
    GIT_CONFIG_COUNT: "1",
    GIT_CONFIG_KEY_0: "core.hooksPath",
    GIT_CONFIG_VALUE_0: "/dev/null",
  };
  if (token === "") {
    stderr("notice: ESTATE_READ_TOKEN is not set; sweeping unauthenticated, so private repos will read unreadable or skipped\n");
  } else {
    // git's header value is base64 of "x-access-token:<token>", computed here so the token is in
    // no argv. GitHub masks the raw secret but not its base64.
    const b64 = Buffer.from(`x-access-token:${token}`).toString("base64");
    if (process.env["GITHUB_ACTIONS"] === "true") stdout(`::add-mask::${b64}\n`);
    gitEnv["GIT_CONFIG_COUNT"] = "2";
    gitEnv["GIT_CONFIG_KEY_1"] = "http.https://github.com/.extraheader";
    gitEnv["GIT_CONFIG_VALUE_1"] = `AUTHORIZATION: basic ${b64}`;
  }

  const rows: Row[] = repos.map((repo) => {
    const dir = join(work, "clones", repo);
    const result = join(work, "results", `${repo}.json`);
    const clone = spawnSync("git", ["clone", "--quiet", "--depth", "1", `https://github.com/${GITHUB_OWNER}/${repo}.git`, dir], {
      env: gitEnv,
      stdio: "ignore",
      timeout: cloneMs,
      killSignal: "SIGKILL",
    });
    let row = UNREAD(repo);
    if (clone.status === 0 && !clone.error) {
      // The script takes the slug in any case and lowercases it. Its stdout and stderr are
      // captured and dropped (see the header); only the result file is read.
      spawnSync("bash", [CHECK_SCRIPT], {
        cwd: dir,
        env: { ...gitEnv, ARCH_MAP_SLUG: `${GITHUB_OWNER}/${repo}`, ARCH_MAP_RESULT: result },
        stdio: "ignore",
        timeout: checkMs,
        killSignal: "SIGKILL",
      });
      try {
        row = parseResult(repo, readFileSync(result, "utf8")) ?? row;
      } catch {
        // No result file: the script was killed or never got to choose.
      }
    }
    stdout(`${repo} ${row.state}\n`);
    return row;
  });

  const summary = summarise(rows);
  const doc = { schema: 1, scope: "estate", generatedAt: new Date().toISOString().replace(/\.\d{3}Z$/, "Z"), summary, repos: rows };
  writeFileSync(`${out}.tmp`, `${JSON.stringify(doc)}\n`);
  renameSync(`${out}.tmp`, out);
  appendFileSync(githubOutput, "published=true\n");
  rmSync(work, { recursive: true, force: true });
  stdout(`swept ${summary["repos"]} repos, ${summary["unreadable"]} unreadable\n`);
  return summary["unreadable"] === 0 ? 0 : 1;
}

try {
  process.exit(main());
} catch (e) {
  // Exit 2 leaves no document: whatever was half-written is removed.
  const t = process.env["RUNNER_TEMP"];
  if (t) {
    rmSync(join(t, "out", "architecture-maps.json"), { force: true });
    rmSync(join(t, "out", "architecture-maps.json.tmp"), { force: true });
    rmSync(join(t, "architecture-maps-work"), { recursive: true, force: true });
  }
  stderr(`ERROR: ${e instanceof Refusal ? e.message : `internal error: ${e instanceof Error ? (e.stack ?? e.message) : String(e)}`}\n`);
  process.exit(2);
}
