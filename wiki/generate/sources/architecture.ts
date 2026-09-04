// The per-repo architecture map (SERV-159).
//
// A repo describes its own shape in `docs/architecture.archify.json`: a typed JSON
// IR that archify — vendored at `wiki/vendor/archify` — compiles into one
// self-contained HTML page with pan/zoom, search, guided views and `SRC` chips that
// deep-link every component to the code it is a claim about.
//
// The split that keeps SERV-101's rule intact is: **the IR is the source and it
// lives in the repo it describes**, exactly like that repo's `CLAUDE.md` — written
// next to the code, reviewed in that repo's PRs — and **the render is the
// generator's job**. Nothing hand-made lands in `wiki/docs/`, which is still wiped
// on every run. A repo with no IR simply has no map, the same degrade-don't-fail
// posture as a repo with no `CLAUDE.md`.
//
// It is JSON and is deliberately NOT in REPO_DOC_FILES. That list is the Markdown
// ingestion path, which escapes braces, demotes headings and rewrites relative
// links — every one of which would corrupt a JSON document. Keeping the IR out of
// it is why the cache stores it under its own name and `loadRepoDocs` cannot see it.

import { existsSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";

/** Where a repo commits its IR. The convention; nothing discovers it. */
export const ARCHITECTURE_IR_PATH = "docs/architecture.archify.json";

/**
 * Where the cache keeps it — flat, beside the Markdown docs rather than under a
 * `docs/` subdirectory, so the file name alone distinguishes it and `loadRepoDocs`
 * (which filters on REPO_DOC_FILES) cannot pick it up as a document to reproduce.
 */
export const ARCHITECTURE_CACHE_FILE = "architecture.archify.json";

/**
 * Where the cache keeps the Git object store archify verifies `sources[]` against.
 * A `git init` plus a `--depth 1` fetch of the pinned commit — an object store, not
 * a checkout: archify reads every source with `git cat-file`, so there is no reason
 * to write a working tree.
 */
export const ARCHITECTURE_EVIDENCE_DIR = ".evidence";

/** archify's own rule for `/meta/repository/revision`: one full commit SHA. */
const FULL_SHA_RE = /^[a-f0-9]{40}$/i;

export interface ArchitectureRepository {
  /** `https://github.com/owner/name`, as the IR pins it. */
  url: string;
  /** A full 40-character commit SHA. Every `SRC` link resolves at this commit. */
  revision: string;
}

/** The parts of an IR this generator reads. archify reads the rest. */
export interface ArchitectureMeta {
  title: string | null;
  repository: ArchitectureRepository | null;
}

export interface Architecture extends ArchitectureMeta {
  /** Absolute path to the cached IR — archify takes a path, so nothing reads it here. */
  irPath: string;
  /**
   * Absolute path to the evidence object store, when one was cached. Null means the
   * map renders without verified `SRC` links, or — if the IR does pin a revision —
   * that the fetch failed and archify is about to say so on the page.
   */
  evidenceRoot: string | null;
}

/**
 * Read an IR's metadata without validating it. A document that will not parse still
 * returns a value: the point is to hand it to archify anyway so the page carries
 * archify's diagnostic, rather than to swallow a broken IR here and render nothing
 * with no explanation.
 */
export function parseArchitectureMeta(body: string): ArchitectureMeta {
  let ir: unknown;
  try {
    ir = JSON.parse(body);
  } catch {
    return { title: null, repository: null };
  }
  const meta = (ir as { meta?: Record<string, unknown> } | null)?.meta;
  if (!meta || typeof meta !== "object") return { title: null, repository: null };

  const title = typeof meta.title === "string" ? meta.title : null;
  const repo = meta.repository as Partial<ArchitectureRepository> | undefined;
  const repository =
    repo && typeof repo.url === "string" && typeof repo.revision === "string" && FULL_SHA_RE.test(repo.revision)
      ? { url: repo.url, revision: repo.revision.toLowerCase() }
      : null;

  return { title, repository };
}

export function loadArchitecture(cacheDir: string, name: string): Architecture | null {
  const dir = join(cacheDir, name);
  const irPath = join(dir, ARCHITECTURE_CACHE_FILE);
  if (!existsSync(irPath)) return null;

  const evidenceRoot = join(dir, ARCHITECTURE_EVIDENCE_DIR);

  return {
    ...parseArchitectureMeta(readFileSync(irPath, "utf8")),
    irPath,
    evidenceRoot: existsSync(evidenceRoot) && statSync(evidenceRoot).isDirectory() ? evidenceRoot : null,
  };
}
