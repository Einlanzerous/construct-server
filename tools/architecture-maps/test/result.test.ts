import assert from "node:assert/strict";
import { describe, test } from "node:test";
import { parseResult, summarise, UNREAD } from "../src/result.ts";

describe("parseResult: only exactly what the script writes is an answer", () => {
  const line = (o: object): string => `${JSON.stringify(o)}\n`;
  const ok = { state: "stale", references: 4, errors: 0, driftedFiles: 2 };

  test("a well-formed line is a row, figures kept (null stays null, 0 stays 0)", () => {
    assert.deepEqual(parseResult("r", line(ok)), { repo: "r", ...ok });
    assert.deepEqual(parseResult("r", line({ state: "no_map", references: null, errors: null, driftedFiles: null })), {
      repo: "r",
      state: "no_map",
      references: null,
      errors: null,
      driftedFiles: null,
    });
  });

  for (const [name, text] of [
    ["empty", ""],
    ["not JSON", "{ nope"],
    ["an array", "[]"],
    ["null", "null"],
    ["an unknown state", line({ ...ok, state: "fine" })],
    ["the sweep's own state, which the script never writes", line({ ...ok, state: "unreadable" })],
    ["a missing figure", line({ state: "in_sync", references: 1, errors: 0 })],
    ["a negative figure", line({ ...ok, errors: -1 })],
    ["a fractional figure", line({ ...ok, references: 1.5 })],
    ["a string figure", line({ ...ok, references: "4" })],
  ] as const) {
    test(`${name} is not an answer`, () => assert.equal(parseResult("r", text), null));
  }
});

describe("summarise", () => {
  test("counts every state and is computed from the rows", () => {
    const rows = [
      { repo: "a", state: "in_sync", references: 1, errors: 0, driftedFiles: 0 },
      { repo: "b", state: "no_map", references: null, errors: null, driftedFiles: null },
      UNREAD("c"),
      UNREAD("d"),
    ] as const;
    assert.deepEqual(summarise([...rows]), { repos: 4, noMap: 1, inSync: 1, stale: 0, broken: 0, skipped: 0, unreadable: 2 });
  });

  test("an unreadable row carries no figures, never zero", () => {
    assert.deepEqual(UNREAD("x"), { repo: "x", state: "unreadable", references: null, errors: null, driftedFiles: null });
  });
});
