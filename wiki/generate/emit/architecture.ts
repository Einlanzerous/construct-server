// Render each repo's committed architecture IR into a page asset (SERV-159).
//
// The one emitter that produces something other than Markdown, and the one place
// the generator shells out to a tool. Output goes to `docs/public/architecture/`,
// which VitePress copies verbatim to the site root — so the map is a plain file at
// `/architecture/<repo>.html`, servable on its own and embeddable in the repo page.
//
// A MAP MUST NOT BE ABLE TO FAIL THE BUILD. archify is strict on purpose — at the
// `showcase` profile a crossed edge or a label overlapping a node is an error — and
// that strictness is the reason the maps are worth reading. It is also exactly the
// kind of thing that would otherwise turn "someone edited a diagram in switchyard"
// into "the estate wiki stopped publishing". Every failure here becomes a warning
// block on the repo's page with archify's own diagnostic in it, and the rest of the
// corpus is emitted unchanged.

import { spawnSync, type SpawnSyncReturns } from "node:child_process";
import { mkdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { ARCHITECTURE_IR_PATH, type Architecture } from "../sources/architecture.ts";
import type { Estate } from "../model.ts";
import { slug } from "../lib/md.ts";

const WIKI_DIR = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");

/**
 * Vendored rather than installed: archify is `private: true`, is not on npm, and its
 * repository root has no `package.json`, so neither a dependency nor a git dep can
 * reach it. Pinned to one release per SERV-91 — `vendor/archify/skill-release.json`
 * records which. It has no runtime dependencies of its own, which is what makes
 * vendoring cheap; `npm ci` never sees it.
 */
const ARCHIFY = join(WIKI_DIR, "vendor", "archify", "bin", "archify.mjs");

/** How long one diagram gets before it is treated as a failure. */
const RENDER_TIMEOUT_MS = 120_000;

export type Diagram = { ok: true; href: string } | { ok: false; message: string };

/**
 * Render every cached IR. Returns one entry per repo that committed one, so a repo
 * absent from the map has no architecture file at all — which is the ordinary case
 * and not a failure.
 *
 * Must run AFTER `docs/` is wiped, since it writes into it.
 */
export function renderArchitecture(estate: Estate, docsDir: string): Map<string, Diagram> {
  const results = new Map<string, Diagram>();
  const outDir = join(docsDir, "public", "architecture");

  for (const repo of estate.repos) {
    const ir = repo.architecture;
    if (!ir) continue;

    const file = `${slug(repo.name)}.html`;
    mkdirSync(outDir, { recursive: true });

    // No `--quality`: the IR's own `meta.quality_profile` decides, and the CLI flag
    // OVERRIDES it. Which profile a map is authored to is the author's call — a
    // shape that genuinely cannot be drawn planar is entitled to `standard` — and
    // forcing `showcase` from here would fail those maps for a choice made in a
    // different repo.
    //
    // `deliver` rather than `validate` then `deliver`: deliver runs the full
    // validation, checks the rendered artifact, and only commits the output file if
    // both pass. Validating first would double the render for no extra signal.
    const args = [ARCHIFY, "deliver", "architecture", ir.irPath, join(outDir, file), "--json"];
    if (ir.evidenceRoot) args.push("--repo-root", ir.evidenceRoot);

    const result = spawnSync(process.execPath, args, {
      encoding: "utf8",
      timeout: RENDER_TIMEOUT_MS,
      maxBuffer: 32 * 1024 * 1024,
    });

    if (!result.error && result.status === 0) {
      results.set(repo.name, { ok: true, href: `/architecture/${file}` });
      continue;
    }

    results.set(repo.name, { ok: false, message: diagnose(repo.name, ir, result) });
  }

  return results;
}

/**
 * Turn a failed run into something a person can act on in the repo that owns the
 * IR. archify's `--json` receipt carries classified diagnostics with the JSON
 * pointer into the IR and a suggested fix; that is the whole value, so it is
 * reproduced rather than summarised. The fallbacks below matter because the two
 * likeliest failures — a missing pinned commit and a timeout — produce no receipt
 * at all.
 */
function diagnose(repo: string, ir: Architecture, result: SpawnSyncReturns<string>): string {
  const lines: string[] = [];

  try {
    const receipt = JSON.parse(result.stdout ?? "") as {
      error?: string;
      stage?: string;
      diagnostics?: { code?: string; message?: string; supportedFixes?: string[] }[];
    };
    if (receipt.error) lines.push(`${receipt.error}${receipt.stage ? ` (stage: ${receipt.stage})` : ""}`);
    for (const d of receipt.diagnostics ?? []) {
      lines.push(`[${d.code ?? "error"}] ${d.message ?? ""}`.trim());
      for (const fix of d.supportedFixes ?? []) lines.push(`  fix: ${fix}`);
    }
  } catch {
    // No receipt: archify never got far enough to write one.
    if (result.error?.message) lines.push(result.error.message);
    const stderr = (result.stderr ?? "").trim();
    if (stderr) lines.push(stderr);
    const stdout = (result.stdout ?? "").trim();
    if (!stderr && stdout) lines.push(stdout);
  }

  if (lines.length === 0) lines.push(`archify exited ${result.status ?? "without a status"} and said nothing.`);

  // archify names the file it was handed, which is a path inside this build's cache.
  // The reader is in the other repo and needs the path they can actually edit.
  const readable = lines.map((line) => line.split(ir.irPath).join(ARCHITECTURE_IR_PATH));

  if (ir.repository && !ir.evidenceRoot) {
    // The likeliest cause, and one the diagnostic alone cannot name: the IR declares
    // source evidence, archify then demands `--repo-root`, and the generator had
    // none to pass because the fetch step could not put the pinned commit on disk.
    readable.push("");
    readable.push(
      `The IR pins ${ir.repository.revision.slice(0, 7)}, but no evidence store was cached for ` +
        `${repo} — the fetch step could not reach that commit. A force-push or a rewritten ` +
        "history removes a commit that was pinned honestly; see the fetch log for the reason.",
    );
  }

  return readable.join("\n");
}
