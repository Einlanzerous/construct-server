import { appendFileSync } from "node:fs";
import type { Console } from "./io.ts";

export type Status = "OK" | "SOON" | "EOL" | "FLOATING" | "UNKNOWN" | "UNMAPPED" | "UNRESOLVED";

export const FINDINGS: ReadonlySet<Status> = new Set<Status>(["EOL", "FLOATING", "UNMAPPED", "UNKNOWN", "UNRESOLVED"]);

// The structured fields of the FROM line being judged. They are set where the human row is
// built, from the same values, so there is one definition of the rule and the document
// cannot drift from the table. null is "could not be determined" and is never "" or 0.
export interface Fields {
  line: number;
  ref: string;
  image: string | null;
  tag: string | null;
  digest: string | null;
  product: string | null;
  cycle: string | null;
  eolDate: string | null;
  eolDateEstimated: boolean;
  newestSupported: string | null;
}

export interface ImageRow extends Fields {
  repo: string | null;
  path: string;
  status: Status;
  detail: string;
}

export interface RepoRecord {
  repo: string;
  state: "read" | "partial" | "unreadable" | "no_dockerfile";
  unreadablePaths: string[] | null;
}

export const blankFields = (line: number): Fields => ({
  line,
  ref: "",
  image: null,
  tag: null,
  digest: null,
  product: null,
  cycle: null,
  eolDate: null,
  eolDateEstimated: false,
  newestSupported: null,
});

// Everything a sweep accumulates. One instance per process; nothing is global.
export class Run {
  errors = 0;
  warnings = 0;
  oks = 0;
  /** The human view, for the step summary. */
  readonly table: { status: Status; where: string; image: string; detail: string }[] = [];
  /** Rows of the repo being swept; only a published repo's buffer reaches the document. */
  private buf: ImageRow[] = [];
  readonly docRows: ImageRow[] = [];
  readonly docRepos: RepoRecord[] = [];
  curRepo = "";
  curPath = "";
  /** True while sweeping a repo whose detail must not be printed. */
  curRedact = false;
  redRepos = 0;
  redFind = 0;
  redWarn = 0;
  withheld = 0;
  visUnread = 0;

  private readonly con: Console;
  private readonly githubActions: boolean;

  constructor(con: Console, githubActions: boolean) {
    this.con = con;
    this.githubActions = githubActions;
  }

  // Human row and counters, no document row. A repo or file that could not be read is a
  // finding here and in the process exit, but it is not a FROM line: it never becomes an
  // images[] row (and never a fake `line 0`); repos[] carries it.
  emit(status: Status, where: string, image: string, detail: string): void {
    if (FINDINGS.has(status)) this.errors++;
    else if (status === "SOON") this.warnings++;
    else this.oks++;
    // A withheld repo is counted above (the exit and the footer still see it) and goes no
    // further: not the table, the summary, the annotations nor the log. Everything that can
    // name it is below this line.
    if (this.curRedact) return;
    this.table.push({ status, where, image, detail });
    if (this.githubActions) {
      const file = where.slice(0, where.indexOf(":") === -1 ? where.length : where.indexOf(":"));
      const line = where.slice(where.lastIndexOf(":") + 1);
      const level = status === "SOON" ? "warning" : status === "OK" ? "" : "error";
      // Workflow commands end at a newline and escape `%`, so a FROM token cannot inject one.
      const msg = `${status} ${image} — ${detail}`.replace(/%/g, "%25").replace(/\r/g, "%0D").replace(/\n/g, "%0A");
      if (level) this.con.human(`::${level} file=${file},line=${line}::${msg}\n`);
    }
    this.con.human(`${status.padEnd(10)} ${where.padEnd(50)} ${image.padEnd(45)} ${detail}\n`);
  }

  // A judged FROM line: the human row and the document row.
  report(status: Status, where: string, fields: Fields, shown: string, detail: string): void {
    this.emit(status, where, shown, detail);
    this.buf.push({
      repo: this.curRepo === "" ? null : this.curRepo,
      path: this.curPath,
      ...fields,
      status,
      detail: detail.replace(/[\n\r\x1f\x1e]/g, " "),
    });
  }

  // Append the finished repo's buffer to the document's rows only when it is published.
  flushRepo(published: boolean): void {
    if (published) this.docRows.push(...this.buf);
    this.buf = [];
  }

  appendStepSummary(file: string, lines: string): void {
    appendFileSync(file, lines);
  }
}
