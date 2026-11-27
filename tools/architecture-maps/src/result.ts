// result.ts — what the check script wrote, read back as a row of the document (SERV-356).
// Pure, so it is unit-tested; sweep.ts runs on import and cannot be.

export const STATES = ["no_map", "in_sync", "stale", "broken", "skipped", "unreadable"] as const;
export type State = (typeof STATES)[number];

export interface Row {
  repo: string;
  state: State;
  references: number | null;
  errors: number | null;
  driftedFiles: number | null;
}

export const UNREAD = (repo: string): Row => ({ repo, state: "unreadable", references: null, errors: null, driftedFiles: null });

const count = (v: unknown): v is number | null => v === null || (typeof v === "number" && Number.isInteger(v) && v >= 0);

// The script's one line, or null. Anything that is not exactly the shape it writes is not an
// answer: a repo whose result cannot be read is unreadable, never clean.
export function parseResult(repo: string, text: string): Row | null {
  let o: unknown;
  try {
    o = JSON.parse(text);
  } catch {
    return null;
  }
  if (typeof o !== "object" || o === null || Array.isArray(o)) return null;
  const r = o as Record<string, unknown>;
  const state = r["state"];
  if (typeof state !== "string" || !(STATES as readonly string[]).includes(state) || state === "unreadable") return null;
  if (!count(r["references"]) || !count(r["errors"]) || !count(r["driftedFiles"])) return null;
  return { repo, state: state as State, references: r["references"], errors: r["errors"], driftedFiles: r["driftedFiles"] };
}

export function summarise(rows: Row[]): Record<string, number> {
  const n = (s: State): number => rows.filter((r) => r.state === s).length;
  return { repos: rows.length, noMap: n("no_map"), inSync: n("in_sync"), stale: n("stale"), broken: n("broken"), skipped: n("skipped"), unreadable: n("unreadable") };
}
