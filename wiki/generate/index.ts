#!/usr/bin/env node
// Generate the tier-1 estate wiki (SERV-101).
//
// Reads the stack definition and the per-repo docs; writes Markdown into docs/,
// which VitePress then renders. The generator is the product here — the site is a
// view of the corpus, and tier 2 (IDEA-21) is expected to layer on the same corpus
// rather than on the rendered HTML.
//
// EVERY file under docs/ is generated, and the directory is wiped before each run
// so a service removed from compose does not leave a page behind. Do not put a
// hand-written page there; it will be deleted without warning. `.vitepress/` is the
// one exception, because config is code rather than content.

import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { buildEstate, type Estate } from "./model.ts";
import { renderArchitecture, type Diagram } from "./emit/architecture.ts";
import { emitDev } from "./emit/dev.ts";
import { emitHome } from "./emit/home.ts";
import { emitReference } from "./emit/reference.ts";
import { emitRepos } from "./emit/repos.ts";
import { emitServices } from "./emit/services.ts";
import { emitTopology } from "./emit/topology.ts";
import { emitVersions } from "./emit/versions.ts";
import { buildSidebar } from "./emit/sidebar.ts";
import type { Page } from "./emit/page.ts";

const WIKI_DIR = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const REPO_ROOT = resolve(WIKI_DIR, "..");
const DOCS_DIR = join(WIKI_DIR, "docs");

/**
 * Root-level documents reproduced into the reference section, in sidebar order.
 * Everything in `docs/` joins them automatically — a new design document should
 * appear in the wiki because it was written, not because someone also remembered
 * to edit this list.
 */
const REFERENCE_ROOT_FILES = ["CLAUDE.md", "PRINCIPLES.md", "README.md"];

function main(): void {
  const repoDocsCache = process.env.WIKI_REPO_DOCS
    ? resolve(process.env.WIKI_REPO_DOCS)
    : join(WIKI_DIR, ".repo-docs");

  const estate = buildEstate({
    composePath: join(REPO_ROOT, "docker-compose.yml"),
    devComposePath: optional(join(REPO_ROOT, "docker-compose.dev.yml")),
    versionsPath: join(REPO_ROOT, "versions.env"),
    devVersionsPath: optional(join(REPO_ROOT, "dev-versions.env")),
    repoDocsCache,
    reference: loadReference(),
    buildRef: buildRef(),
  });

  // Before the emitters, because it writes a page ASSET rather than a page: the
  // maps land in docs/public/, which cleanDocs() has just emptied, and the repo
  // pages need to know which of them rendered.
  cleanDocs();
  const diagrams = renderArchitecture(estate, DOCS_DIR);

  const pages: Page[] = [
    emitHome(estate),
    ...emitServices(estate),
    ...emitTopology(estate),
    emitVersions(estate),
    ...emitDev(estate),
    ...emitRepos(estate, diagrams),
    ...emitReference(estate),
  ];

  for (const page of pages) writePage(page);
  writeSidebar(estate);

  report(estate, pages, diagrams, repoDocsCache);
}

// --- io --------------------------------------------------------------------

function optional(path: string): string | null {
  return existsSync(path) ? path : null;
}

function loadReference(): Estate["reference"] {
  // Top level of docs/ only. `docs/bakeoffs/` holds model-evaluation output, which
  // is data rather than design documentation and does not belong in this section.
  const docsDir = join(REPO_ROOT, "docs");
  const fromDocs = existsSync(docsDir)
    ? readdirSync(docsDir, { withFileTypes: true })
        .filter((e) => e.isFile() && e.name.endsWith(".md"))
        .map((e) => `docs/${e.name}`)
        .sort()
    : [];

  return [...REFERENCE_ROOT_FILES, ...fromDocs].flatMap((rel) => {
    const abs = join(REPO_ROOT, rel);
    if (!existsSync(abs)) {
      warn(`reference file ${rel} not found — skipping`);
      return [];
    }
    const body = readFileSync(abs, "utf8").trim();
    return [{ title: titleOf(body, rel), path: rel, body }];
  });
}

/** Prefer the document's own h1; fall back to a readable form of the filename. */
function titleOf(body: string, path: string): string {
  const m = /^#\s+(.+)$/m.exec(body);
  if (m?.[1]) return m[1].replace(/\s*—.*$/, "").trim();
  return (path.split("/").pop() ?? path).replace(/\.md$/, "");
}

/**
 * What the wiki was built from. Passed in by CI so a deployed page can be traced
 * to a commit; falls back to asking git, then to an honest placeholder rather than
 * an invented value.
 */
function buildRef(): string {
  if (process.env.WIKI_BUILD_REF) return process.env.WIKI_BUILD_REF;
  try {
    return execFileSync("git", ["rev-parse", "--short", "HEAD"], {
      cwd: REPO_ROOT,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
  } catch {
    return "working tree";
  }
}

function cleanDocs(): void {
  if (!existsSync(DOCS_DIR)) {
    mkdirSync(DOCS_DIR, { recursive: true });
    return;
  }
  for (const entry of readdirSync(DOCS_DIR)) {
    if (entry === ".vitepress") continue;
    rmSync(join(DOCS_DIR, entry), { recursive: true, force: true });
  }
}

function writePage(page: Page): void {
  const abs = join(DOCS_DIR, `${page.path}.md`);
  mkdirSync(dirname(abs), { recursive: true });
  writeFileSync(abs, page.body.trimEnd() + "\n", "utf8");
}

function writeSidebar(estate: Estate): void {
  const abs = join(DOCS_DIR, ".vitepress", "sidebar.json");
  mkdirSync(dirname(abs), { recursive: true });
  writeFileSync(abs, JSON.stringify(buildSidebar(estate), null, 2) + "\n", "utf8");
}

// --- reporting -------------------------------------------------------------

function warn(message: string): void {
  process.stderr.write(`warn: ${message}\n`);
}

function indent(text: string): string {
  return text
    .split("\n")
    .map((line) => `      ${line}`)
    .join("\n");
}

function report(estate: Estate, pages: Page[], diagrams: Map<string, Diagram>, cacheDir: string): void {
  const missing = estate.repos.filter((r) => r.missing);
  const drawn = [...diagrams.values()].filter((d) => d.ok).length;

  process.stdout.write(
    [
      `wiki: ${pages.length} pages from ${estate.prod.services.length} prod services, ` +
        `${estate.repos.length} repos, ${estate.pins.length} pins, ` +
        `${drawn}/${diagrams.size} architecture maps (build ${estate.buildRef})`,
      "",
    ].join("\n"),
  );

  // Named, not just counted. A map that stops rendering is a page that quietly
  // loses its diagram, and the warning block on that page is only seen by someone
  // who visits it — the build log is where it gets noticed.
  for (const [repo, diagram] of diagrams) {
    if (diagram.ok) continue;
    warn(`${repo}: architecture map not rendered — see the warning block on its page\n${indent(diagram.message)}`);
  }

  if (missing.length > 0) {
    // A warning, not an error. A GitHub outage during the fetch step should degrade
    // the wiki, not block a deploy of the stack itself.
    warn(
      `no cached docs for ${missing.length} repo(s): ${missing.map((r) => r.name).join(", ")}\n` +
        `      looked in ${cacheDir} — run \`npm run fetch\` to populate it`,
    );
  }
}

main();
