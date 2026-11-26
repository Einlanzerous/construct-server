import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, test } from "node:test";
import { ROOT } from "./helpers.ts";

// Ruling 7 of the SERV-356 plan: which package holds the shared publisher. (a) generalises
// tools/base-images/src/publish.ts, which `tools/base-images/**` already covers; (b) is a new
// tools/estate-publish/ package, which adds a sixth path. Set once, by the row that added the
// workflow; a later row does not edit it or the list it selects.
export type PublisherOption = "a" | "b";
export const PUBLISHER_OPTION: PublisherOption = "a";

const COMMON = [
  "tools/architecture-maps/**",
  "tools/base-images/**",
  "scripts/architecture-map-check.sh",
  "Makefile",
  ".github/workflows/architecture-maps.yml",
];
export const EXPECTED_PATHS: Record<PublisherOption, string[]> = {
  a: COMMON,
  b: ["tools/estate-publish/**", ...COMMON],
};

// The workflow without its comment lines: prose that names a secret or a permission must not
// satisfy or break an assertion about the code.
const code = readFileSync(`${ROOT}/.github/workflows/architecture-maps.yml`, "utf8")
  .split("\n")
  .filter((l) => !/^\s*#/.test(l));
const text = code.join("\n");

// The entries of `on.<event>.paths`, in order.
function pathsOf(event: string): string[] {
  const out: string[] = [];
  let inOn = false;
  let inEvent = false;
  let inPaths = false;
  for (const l of code) {
    if (/^\S/.test(l)) inOn = l.startsWith("on:");
    else if (inOn && /^ {2}\S/.test(l)) inEvent = l.startsWith(`  ${event}:`);
    else if (inOn && inEvent && /^ {4}\S/.test(l)) inPaths = l.startsWith("    paths:");
    else if (inOn && inEvent && inPaths) {
      const m = /^ {6}- '(.+)'$/.exec(l);
      if (m) out.push(m[1]!);
    }
  }
  return out;
}

describe("architecture-maps.yml structure (C7)", () => {
  test("the pick is one of the two options", () => assert.ok(PUBLISHER_OPTION === "a" || PUBLISHER_OPTION === "b"));

  for (const event of ["pull_request", "push"]) {
    test(`${event} paths equal the list for option ${PUBLISHER_OPTION}, in order`, () => {
      assert.deepEqual(pathsOf(event), EXPECTED_PATHS[PUBLISHER_OPTION]);
    });
  }

  test("five paths under (a), six under (b), and the two lists are the same", () => {
    assert.equal(EXPECTED_PATHS.a.length, 5);
    assert.equal(EXPECTED_PATHS.b.length, 6);
    assert.deepEqual(pathsOf("pull_request"), pathsOf("push"));
  });

  test("top-level permissions are contents: read, and nothing else grants a permission", () => {
    assert.match(text, /^permissions:\n {2}contents: read$/m);
    assert.equal(text.match(/permissions:/g)?.length, 1);
    assert.ok(!text.includes("contents: write"));
  });

  test("no secret is referenced and no token is passed", () => {
    assert.ok(!/secrets\./i.test(text));
    assert.ok(!/token/i.test(text));
  });

  test("exactly one job, named test, with a timeout", () => {
    const jobs = text.split(/^jobs:\n/m)[1] ?? "";
    assert.deepEqual([...jobs.matchAll(/^ {2}([a-z][\w-]*):/gm)].map((m) => m[1]), ["test"]);
    assert.match(jobs, /^ {4}timeout-minutes: \d+$/m);
  });

  test("it runs the package's two make targets, which the Makefile defines", () => {
    assert.match(text, /run: make architecture-maps-typecheck architecture-maps-test$/m);
    const mk = readFileSync(`${ROOT}/Makefile`, "utf8");
    for (const t of ["architecture-maps-typecheck", "architecture-maps-test"]) {
      assert.match(mk, new RegExp(`^${t}:`, "m"));
      assert.match(mk.split("\n", 1)[0]!, new RegExp(`\\b${t}\\b`), `${t} is in .PHONY`);
    }
  });
});
