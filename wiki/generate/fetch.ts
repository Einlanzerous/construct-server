#!/usr/bin/env node
// Populate the per-repo docs cache the generator reads.
//
// Split out from the generator on purpose: this step needs network and a token,
// the generator needs neither. Keeping them apart means the generator is pure and
// reproducible — point it at a cache and it emits the same corpus every time,
// offline, with no credentials in scope.
//
// Docs are fetched rather than read from sibling checkouts because the deploy
// runner has none, and because a checkout on the box is whatever someone last left
// there. `--local` reads them from `~/projects` instead, which is faster when
// iterating on the generator and picks up uncommitted edits.
//
// Uses the GitHub REST API over global fetch rather than shelling out to `gh`,
// so this runs unchanged inside the build container, where `gh` does not exist.
//
// NOTHING HERE IS FATAL. A repo that cannot be read becomes "no docs cached for X"
// on its page and the build carries on: a documentation fetch must never be able to
// block shipping the stack.

import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import {
  ARCHITECTURE_CACHE_FILE,
  ARCHITECTURE_EVIDENCE_DIR,
  ARCHITECTURE_IR_PATH,
  parseArchitectureMeta,
} from "./sources/architecture.ts";
import { parseCompose } from "./sources/compose.ts";
import { parseVersions } from "./sources/versions.ts";
import { EXTRA_REPOS, GITHUB_OWNER, REPO_DOC_FILES, repoFromImage, repoUrl } from "./sources/repos.ts";

const WIKI_DIR = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const REPO_ROOT = resolve(WIKI_DIR, "..");
const SELF = "construct-server";

async function main(): Promise<void> {
  const local = process.argv.includes("--local");
  const cacheDir = process.env.WIKI_REPO_DOCS
    ? resolve(process.env.WIKI_REPO_DOCS)
    : join(WIKI_DIR, ".repo-docs");
  const localRoot = resolve(process.env.WIKI_LOCAL_REPOS ?? join(process.env.HOME ?? "~", "projects"));

  const token = process.env.WIKI_DOCS_TOKEN || process.env.GH_TOKEN || process.env.GITHUB_TOKEN || "";
  if (!local && !token) {
    // Two distinct failures, and the rate limit is the one that actually bites.
    // Most of the estate's repos are public, so an unauthenticated run does not
    // 404 its way to an empty cache — it succeeds until the 60/hour per-IP quota
    // runs out partway through, then reports nothing for everything after that
    // point. Only amber and switchyard are private. Naming both causes is the
    // difference between a puzzling wiki and an actionable warning, and this
    // string is the copy someone actually hits when debugging an empty cache.
    warn(
      "no token in WIKI_DOCS_TOKEN / GH_TOKEN / GITHUB_TOKEN — unauthenticated requests get " +
        "60/hour per IP and this fetch makes one per repo per file " +
        `(${REPO_DOC_FILES.length + 1} each), so it will run out partway through; ` +
        "the private repos (amber, switchyard) will also 404",
    );
  }

  const repos = discoverRepos();
  process.stdout.write(`fetch: ${repos.length} repos -> ${cacheDir}${local ? " (local)" : ""}\n`);

  rmSync(cacheDir, { recursive: true, force: true });

  let cached = 0;
  let absent = 0;
  let maps = 0;
  for (const repo of repos) {
    const dest = join(cacheDir, repo);
    mkdirSync(dest, { recursive: true });

    for (const file of REPO_DOC_FILES) {
      // This repo is already on disk, and the working tree is the truthful answer
      // for it: the wiki is generated from the same checkout being deployed, so
      // fetching `main` would describe a different commit than the one shipping.
      //
      // The rate-limit guard is the LAST arm, below both local reads, and the
      // ordering is load-bearing. A spent quota says nothing about a file already
      // on disk, and `discoverRepos()` sorts, so construct-server lands fifth —
      // a quota that dies in the first four repos would drop this repo's own
      // CLAUDE.md, README.md, PRINCIPLES.md and REVIEW.md, the largest single
      // piece of writing in the wiki, at a cost of zero API calls. Guarding the
      // whole branch would make a rate-limited run strictly worse than it was
      // before the guard existed. Only the network arm skips: once the hourly
      // quota is gone it is gone, and the remaining requests cannot succeed, they
      // only turn one actionable problem into fifty lines of noise.
      const body =
        repo === SELF
          ? readLocal(join(REPO_ROOT, file))
          : local
            ? readLocal(join(localRoot, repo, file))
            : rateLimited
              ? null
              : await fetchFile(repo, file, token);

      if (body === null) {
        absent++;
        continue;
      }
      writeFileSync(join(dest, file), body, "utf8");
      cached++;
    }

    // The architecture IR (SERV-159), on the same three arms as the docs above and
    // for the same reasons. Cached under its own flat name so the Markdown
    // ingestion path — which escapes braces and rewrites links — cannot reach it.
    const ir =
      repo === SELF
        ? readLocal(join(REPO_ROOT, ARCHITECTURE_IR_PATH))
        : local
          ? readLocal(join(localRoot, repo, ARCHITECTURE_IR_PATH))
          : rateLimited
            ? null
            : await fetchFile(repo, ARCHITECTURE_IR_PATH, token);

    if (ir === null) continue;
    writeFileSync(join(dest, ARCHITECTURE_CACHE_FILE), ir, "utf8");
    maps++;

    // A pinned revision means the IR carries source evidence, and archify verifies
    // that with git before it will render: the commit must exist locally and every
    // `sources[]` path must be a blob at it. So the pinned commit has to be on disk
    // by the time the generator runs. A malformed IR reaches the generator without
    // an evidence store and archify reports it on the page — see loadArchitecture.
    const { repository } = parseArchitectureMeta(ir);
    if (repository) {
      // In `--local` mode the objects come from the sibling checkout, which keeps
      // that mode genuinely offline; otherwise from GitHub, including for this repo
      // — `actions/checkout` is depth 1, so the pinned commit is usually not in the
      // CI workspace even though this repo's own IR was read from it.
      const objectSource = local ? (repo === SELF ? REPO_ROOT : join(localRoot, repo)) : repoUrl(repo);
      cacheEvidence(repo, dest, repository.revision, objectSource, token);
    }
  }

  process.stdout.write(`fetch: ${cached} files cached, ${absent} absent, ${maps} architecture map(s)\n`);
}

/**
 * Put the pinned commit on disk so archify can verify the IR's `sources[]` against
 * it. An object store, not a checkout: archify reads every source with `git
 * cat-file`, so `--depth 1` of the one commit is the whole requirement — 848 KB and
 * half a second for this repo, against a full clone.
 *
 * `origin` is set to the CANONICAL url for the repo this page is about, not to the
 * one the IR names. archify compares the two, and pointing origin at the IR's own
 * value would make that check vacuous; as written it asserts that a repo's map
 * actually describes that repo.
 *
 * NOT FATAL, like everything else in this file. A failure leaves no evidence
 * directory, the generator renders without `--repo-root`, and archify puts the
 * reason on the repo's page. A map must not be able to block shipping the stack.
 */
function cacheEvidence(repo: string, dest: string, revision: string, objectSource: string, token: string): void {
  const root = join(dest, ARCHITECTURE_EVIDENCE_DIR);
  mkdirSync(root, { recursive: true });

  const steps: string[][] = [
    ["init", "--quiet"],
    ["remote", "add", "origin", repoUrl(repo)],
    ["fetch", "--depth", "1", "--quiet", objectSource, revision],
  ];

  for (const args of steps) {
    const result = spawnSync("git", ["-C", root, ...args], {
      encoding: "utf8",
      timeout: 120_000,
      env: { ...process.env, ...gitAuthEnv(token) },
    });
    if (result.error || result.status !== 0) {
      const reason = (result.error?.message ?? result.stderr ?? "").trim() || `git ${args[0]} exited ${result.status}`;
      warn(`${repo}: could not cache evidence for ${revision.slice(0, 7)} — ${reason}`);
      rmSync(root, { recursive: true, force: true });
      return;
    }
  }
}

/**
 * Credentials for a private repo's evidence fetch, as `GIT_CONFIG_*` rather than in
 * the remote URL. Both alternatives leak: a URL passed on the command line shows up
 * in `ps`, and one written with `remote add` is persisted in `.git/config` inside
 * the workspace. This form is what `actions/checkout` uses, and it survives neither
 * way. `GIT_TERMINAL_PROMPT` matters just as much — without it, a private repo and
 * no token is a hung build rather than a warning.
 */
function gitAuthEnv(token: string): Record<string, string> {
  const env: Record<string, string> = { GIT_TERMINAL_PROMPT: "0" };
  if (!token) return env;

  return {
    ...env,
    GIT_CONFIG_COUNT: "1",
    GIT_CONFIG_KEY_0: "http.https://github.com/.extraheader",
    GIT_CONFIG_VALUE_0: `Authorization: Basic ${Buffer.from(`x-access-token:${token}`).toString("base64")}`,
  };
}

/**
 * The repo list comes from the compose file, not from a constant: every first-party
 * image names its source repo, so adding a service to the stack adds it here with
 * no second edit. Only repos that ship no image need naming (EXTRA_REPOS).
 */
function discoverRepos(): string[] {
  const compose = parseCompose(join(REPO_ROOT, "docker-compose.yml"));
  const fromImages = compose.services
    .filter((s) => s.image?.firstParty)
    .map((s) => repoFromImage(s.image!.repo))
    .filter((n): n is string => n !== null);

  const fromPins = parseVersions(join(REPO_ROOT, "versions.env")).map((p) => p.repo);

  return [...new Set([...fromImages, ...fromPins, ...EXTRA_REPOS])].sort();
}

function readLocal(path: string): string | null {
  if (!existsSync(path)) return null;
  return readFileSync(path, "utf8");
}

/**
 * Set once the hourly quota is exhausted, to stop the loop rather than burn
 * through every remaining repo re-learning the same thing. Unauthenticated calls
 * get 60/hour per IP and this fetch needs ~48, so on a shared runner IP an
 * unauthenticated run reliably dies partway through. Only the network arm of the
 * fetch loop consults this — reads from disk are unaffected by it.
 */
let rateLimited = false;

/**
 * `Accept: application/vnd.github.raw` returns the file body directly — no base64
 * round-trip and no JSON to parse. A 404 is the ordinary case for a repo that
 * simply has no REVIEW.md and is not worth a warning; anything else is.
 */
async function fetchFile(repo: string, file: string, token: string): Promise<string | null> {
  const url = `https://api.github.com/repos/${GITHUB_OWNER}/${repo}/contents/${file}`;
  const headers: Record<string, string> = {
    Accept: "application/vnd.github.raw",
    "User-Agent": "construct-wiki-generator",
  };
  if (token) headers.Authorization = `Bearer ${token}`;

  try {
    const res = await fetch(url, { headers });
    if (res.status === 404) return null;

    // 403/429 with the remaining counter at zero is the rate limit, not a
    // permission problem — worth distinguishing, because the fixes are different
    // and "403" alone reads as "your token is wrong".
    if ((res.status === 403 || res.status === 429) && res.headers.get("x-ratelimit-remaining") === "0") {
      const reset = Number(res.headers.get("x-ratelimit-reset") ?? 0);
      const mins = reset ? Math.max(0, Math.ceil((reset * 1000 - Date.now()) / 60000)) : null;
      rateLimited = true;
      warn(
        `GitHub API rate limit exhausted${mins === null ? "" : `, resets in ~${mins} min`}. ` +
          `Skipping the rest of the fetch.\n` +
          `      ${token ? "This token's quota is spent." : "Unauthenticated requests get 60/hour; set WIKI_DOCS_TOKEN or GITHUB_TOKEN for 1,000."}`,
      );
      return null;
    }

    if (!res.ok) {
      warn(`${repo}/${file}: HTTP ${res.status} ${res.statusText}`);
      return null;
    }
    return await res.text();
  } catch (err) {
    warn(`${repo}/${file}: ${err instanceof Error ? err.message : String(err)}`);
    return null;
  }
}

function warn(message: string): void {
  process.stderr.write(`warn: ${message}\n`);
}

await main();
