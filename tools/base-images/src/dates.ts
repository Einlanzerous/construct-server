import { die } from "./errors.ts";

const DAY_MS = 86_400_000;

// endoflife.date publishes plain YYYY-MM-DD dates. Anything else is refused rather than
// guessed at: a date that does not parse must not become a comparison that quietly passes.
export function parseDay(s: string, what: string): number {
  if (!/^\d{4}-\d{2}-\d{2}/.test(s)) die(`${what}: '${s}' is not a YYYY-MM-DD date`);
  const t = Date.parse(s);
  if (Number.isNaN(t)) die(`${what}: '${s}' is not a date`);
  return t;
}

// Whole days from `from` to `to`, truncated towards zero like shell arithmetic.
export function daysBetween(to: number, from: number): number {
  return Math.trunc((to - from) / DAY_MS);
}

export function addDays(t: number, days: number): string {
  return new Date(t + days * DAY_MS).toISOString().slice(0, 10);
}
