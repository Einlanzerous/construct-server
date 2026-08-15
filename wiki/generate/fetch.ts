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

import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { parseCompose } from "./sources/compose.ts";
import { parseVersions } from "./sources/versions.ts";
import { EXTRA_REPOS, GITHUB_OWNER, REPO_DOC_FILES, repoFromImage } from "./sources/repos.ts";

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
    // Worth saying out loud: these repos are private, so an unauthenticated run
    // gets 404 on every file and produces a cache that is empty but not obviously
    // broken. Naming the cause here is the difference between a puzzling wiki and
    // an actionable warning.
    warn("no token in WIKI_DOCS_TOKEN / GH_TOKEN / GITHUB_TOKEN — private repos will return 404");
  }

  const repos = discoverRepos();
  process.stdout.write(`fetch: ${repos.length} repos -> ${cacheDir}${local ? " (local)" : ""}\n`);

  rmSync(cacheDir, { recursive: true, force: true });

  let cached = 0;
  let absent = 0;
  for (const repo of repos) {
    const dest = join(cacheDir, repo);
    mkdirSync(dest, { recursive: true });

    for (const file of REPO_DOC_FILES) {
      // Once the hourly quota is gone it is gone; the remaining requests cannot
      // succeed and only turn one actionable problem into fifty lines of noise.
      if (rateLimited) {
        absent++;
        continue;
      }
      // This repo is already on disk, and the working tree is the truthful answer
      // for it: the wiki is generated from the same checkout being deployed, so
      // fetching `main` would describe a different commit than the one shipping.
      const body =
        repo === SELF
          ? readLocal(join(REPO_ROOT, file))
          : local
            ? readLocal(join(localRoot, repo, file))
            : await fetchFile(repo, file, token);

      if (body === null) {
        absent++;
        continue;
      }
      writeFileSync(join(dest, file), body, "utf8");
      cached++;
    }
  }

  process.stdout.write(`fetch: ${cached} files cached, ${absent} absent\n`);
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
 * `Accept: application/vnd.github.raw` returns the file body directly — no base64
 * round-trip and no JSON to parse. A 404 is the ordinary case for a repo that
 * simply has no REVIEW.md and is not worth a warning; anything else is.
 */
/**
 * Set once the hourly quota is exhausted, to stop the loop rather than burn
 * through every remaining repo re-learning the same thing. Unauthenticated calls
 * get 60/hour per IP and this fetch needs ~48, so on a shared runner IP an
 * unauthenticated run reliably dies partway through.
 */
let rateLimited = false;

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
