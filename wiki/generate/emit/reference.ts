// Local design documents, ingested verbatim.
//
// These are hand-authored and stay that way — the rule that nothing in this tier is
// hand-edited is about the *wiki*, not about its sources. Reproducing them here is
// what makes the estate view complete without forking the text: each page says
// where it came from and sends an editor back to the file.

import { absolutizeLinks, demoteHeadings, frontmatter, provenance, slug } from "../lib/md.ts";
import { GITHUB_OWNER } from "../sources/repos.ts";
import type { Estate } from "../model.ts";
import type { Page } from "./page.ts";

export function emitReference(estate: Estate): Page[] {
  return [referenceIndex(estate), ...estate.reference.map(referencePage)];
}

export function referencePath(path: string): string {
  return `reference/${slug(path.replace(/\.md$/, ""))}`;
}

function referenceIndex(estate: Estate): Page {
  return {
    path: "reference/index",
    body: [
      frontmatter({ title: "Reference" }),
      "The design documents this estate runs on, reproduced from `construct-server`. Each is authored by hand in its own file — these copies are read-only.\n\n",
      estate.reference
        .map((doc) => `- [${doc.title}](/${referencePath(doc.path)}) — \`${doc.path}\``)
        .join("\n"),
      "\n",
    ].join(""),
  };
}

function referencePage(doc: { title: string; path: string; body: string }): Page {
  return {
    path: referencePath(doc.path),
    body: [
      frontmatter({ title: doc.title }),
      provenance([doc.path]),
      // These come from construct-server, so their relative links resolve there —
      // `docs/delivery-pipeline.md` in CLAUDE.md means that file in that repo.
      demoteHeadings(absolutizeLinks(doc.body, GITHUB_OWNER, "construct-server"), 1),
      "\n",
    ].join(""),
  };
}
