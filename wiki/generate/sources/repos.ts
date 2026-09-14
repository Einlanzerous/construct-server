// The per-repo documentation layer.
//
// Each service repo's `CLAUDE.md` is the best writing about that service, and it
// stays true precisely because it sits in git next to the code it describes. The
// wiki's job is to assemble those, not to restate them — so this reads them
// verbatim and the emitters stamp each page with where it came from.
//
// Docs arrive through a cache directory rather than being read from sibling
// checkouts, because the deploy runner has neither. `npm run fetch` fills the
// cache from the GitHub API; a local run can point WIKI_REPO_DOCS at anything with
// the same shape, including `~/projects`.

import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { basename, join } from "node:path";

import type { Architecture } from "./architecture.ts";

/** Files worth ingesting from a service repo, in the order they should appear. */
export const REPO_DOC_FILES = ["CLAUDE.md", "README.md", "PRINCIPLES.md", "REVIEW.md"] as const;

export interface RepoDoc {
  file: string;
  body: string;
}

export interface Repo {
  name: string;
  /** GitHub slug, `owner/name`. */
  slug: string;
  /** Images built from this repo, as they appear in compose. */
  images: string[];
  /** Compose services running one of those images. */
  services: string[];
  /** The `<REPO>_TAG` variable pinning it, when it has one. */
  tagVariable: string | null;
  docs: RepoDoc[];
  /** Set when the repo is known but no docs were cached for it. */
  missing: boolean;
  /** The repo's own architecture map (SERV-159), when it commits one. */
  architecture: Architecture | null;
}

export const GITHUB_OWNER = "Einlanzerous";

/**
 * Repos with no first-party image in compose, which therefore cannot be discovered
 * from it. Everything else is derived, so adding a service does not mean editing
 * this list.
 */
export const EXTRA_REPOS = [
  "construct-server", // this repo: the stack definition itself
  "signet", // a host daemon, deployed by deploy-signet.yml rather than compose
] as const;

export function loadRepoDocs(cacheDir: string, name: string): RepoDoc[] {
  const dir = join(cacheDir, name);
  if (!existsSync(dir) || !statSync(dir).isDirectory()) return [];

  const present = new Set(readdirSync(dir).map((f) => basename(f)));
  return REPO_DOC_FILES.filter((f) => present.has(f)).map((file) => ({
    file,
    body: readFileSync(join(dir, file), "utf8").trim(),
  }));
}

export function repoUrl(name: string): string {
  return `https://github.com/${GITHUB_OWNER}/${name}`;
}

/**
 * Image names that do not name their source repo. Every other first-party image is
 * `ghcr.io/<owner>/<repo>[/<component>]`, so the repo is derived from the path —
 * but `estate-asr` is built from chronicle's `asr/` subtree and named for what it
 * is rather than where it lives (CHRN-82). Left to the derivation, the wiki invented
 * a repo called `estate-asr`, gave it a page with a permanent NO DOCS CACHED warning,
 * and fetched four files from a GitHub repo that does not exist on every build
 * (SERV-186). Add to this only when the image name and the repo name genuinely
 * differ; a typo in compose is fixed in compose.
 */
export const IMAGE_REPO_ALIASES: Record<string, string> = {
  "estate-asr": "chronicle",
};

/** `ghcr.io/einlanzerous/switchyard/backend` -> `switchyard`. */
export function repoFromImage(repoPath: string): string | null {
  const parts = repoPath.split("/");
  // ghcr.io / owner / repo [ / component ]
  const name = parts.length >= 3 ? (parts[2] ?? null) : null;
  return name === null ? null : (IMAGE_REPO_ALIASES[name] ?? name);
}
