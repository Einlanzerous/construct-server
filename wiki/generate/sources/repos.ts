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

/** `ghcr.io/einlanzerous/switchyard/backend` -> `switchyard`. */
export function repoFromImage(repoPath: string): string | null {
  const parts = repoPath.split("/");
  // ghcr.io / owner / repo [ / component ]
  return parts.length >= 3 ? (parts[2] ?? null) : null;
}
