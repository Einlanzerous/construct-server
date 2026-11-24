import { renameSync, rmSync, writeFileSync } from "node:fs";
import { die } from "./errors.ts";
import { FINDINGS, type ImageRow, type RepoRecord, type Run } from "./run.ts";

export type Mode = "files" | "estate" | "dir";

// Schema 1. Key order is part of the shape: a consumer may diff the bytes. null is "could
// not be determined", never "" or 0; the stability promise is in docs/base-images.md.
export interface Document {
  schema: 1;
  scope: "public-only" | "unfiltered";
  generatedAt: string;
  today: string;
  policy: { source: string; warnDays: number };
  mode: Mode;
  exit: 0 | 1;
  summary: {
    findings: number;
    warnings: number;
    ok: number;
    unreadableRepos: number;
    withheldRepos: number | null;
    visibilityUnreadable: number | null;
  };
  repos: RepoRecord[] | null;
  images: ImageRow[];
}

export interface DocumentInput {
  mode: Mode;
  publicOnly: boolean;
  today: string;
  warnDays: number;
  policySource: string;
  now: Date;
}

// Assemble the schema-1 document from the published rows, once, at the end. summary and
// exit are computed here from those rows and nowhere else, so they describe exactly what
// is published: a private repo's finding moves neither.
export function buildDocument(run: Run, input: DocumentInput): Document {
  const withheld = input.publicOnly ? run.withheld : null;
  const visUnread = input.publicOnly ? run.visUnread : null;
  const images = run.docRows.map((r) => ({
    repo: r.repo,
    path: r.path,
    line: r.line,
    ref: r.ref,
    image: r.image,
    tag: r.tag,
    digest: r.digest,
    product: r.product,
    cycle: r.cycle,
    eolDate: r.eolDate,
    eolDateEstimated: r.eolDateEstimated,
    newestSupported: r.newestSupported,
    status: r.status,
    detail: r.detail,
  }));
  const repos = run.docRepos.map((r) => ({ repo: r.repo, state: r.state, unreadablePaths: r.unreadablePaths }));
  const unreadable = repos.filter((r) => r.state === "unreadable" || r.state === "partial").length;
  const findings = images.filter((i) => FINDINGS.has(i.status)).length + unreadable;
  return {
    schema: 1,
    scope: input.publicOnly ? "public-only" : "unfiltered",
    generatedAt: input.now.toISOString().replace(/\.\d{3}Z$/, "Z"),
    today: input.today,
    policy: { source: input.policySource, warnDays: input.warnDays },
    mode: input.mode,
    exit: findings > 0 || (visUnread ?? 0) > 0 ? 1 : 0,
    summary: {
      findings,
      warnings: images.filter((i) => i.status === "SOON").length,
      ok: images.filter((i) => i.status === "OK").length,
      unreadableRepos: unreadable,
      withheldRepos: withheld,
      visibilityUnreadable: visUnread,
    },
    repos: input.mode === "estate" ? repos : null,
    images,
  };
}

export const serialize = (doc: Document): string => JSON.stringify(doc, null, 2) + "\n";

// Write the file whole or not at all: a temp file in the same directory, then a rename.
// Any failure leaves no file and is exit 2, never 1, so a broken write cannot read as
// "findings".
export function writeDocumentFile(path: string, text: string): void {
  const tmp = `${path}.tmp.${process.pid}`;
  try {
    writeFileSync(tmp, text);
    renameSync(tmp, path);
  } catch {
    rmSync(tmp, { force: true });
    rmSync(path, { force: true });
    die(`could not write ${path}`);
  }
}
