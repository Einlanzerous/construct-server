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

// ---------------------------------------------------------------------------------------------
// The template for the private repo that runs the sweep (C8). It is not a workflow of this repo,
// and the repo that runs it cannot run these tests, so they live here.

const template = readFileSync(`${ROOT}/tools/architecture-maps/drogue/architecture-maps.yml`, "utf8")
  .split("\n")
  .filter((l) => !/^\s*#/.test(l))
  .join("\n");

// The text of one job: from its two-space key to the next job or the end.
function job(name: string): string {
  const jobs = template.split(/^jobs:\n/m)[1] ?? "";
  const m = new RegExp(`^ {2}${name}:\\n([\\s\\S]*?)(?=^ {2}[a-z][\\w-]*:\\n|$(?![\\s\\S]))`, "m").exec(jobs);
  assert.ok(m, `job ${name} exists`);
  return m[1]!;
}

// The step whose `name:` is given, to the next step or the end of its job.
function step(jobText: string, name: string): string {
  const m = new RegExp(`^ {6}- name: ${name}\\n([\\s\\S]*?)(?=^ {6}- |$(?![\\s\\S]))`, "m").exec(jobText);
  assert.ok(m, `step ${name} exists`);
  return m[1]!;
}

describe("the drogue template (C8)", () => {
  test("it has exactly the two jobs, sweep and publish", () => {
    const jobs = template.split(/^jobs:\n/m)[1] ?? "";
    assert.deepEqual([...jobs.matchAll(/^ {2}([a-z][\w-]*):/gm)].map((m) => m[1]), ["sweep", "publish"]);
  });

  test("it has no pull_request event, and schedule, dispatch and push to main only", () => {
    const on = /^on:\n([\s\S]*?)^permissions:/m.exec(template)?.[1] ?? "";
    assert.deepEqual([...on.matchAll(/^ {2}([a-z_]+):/gm)].map((m) => m[1]), ["schedule", "workflow_dispatch", "push"]);
    assert.ok(!/pull_request/.test(template));
    assert.match(on, /^ {4}branches: \["main"\]$/m);
  });

  test("the cadence is the ruling's pick: daily at 06:30 UTC", () => {
    assert.match(template, /^ {4}- cron: '30 6 \* \* \*'$/m);
  });

  test("top-level permissions are contents: read, and only publish has contents: write", () => {
    assert.match(template, /^permissions:\n {2}contents: read$/m);
    assert.equal(template.match(/contents: write/g)?.length, 1);
    assert.match(job("publish"), /^ {4}permissions:\n {6}contents: write$/m);
    assert.ok(!/permissions:/.test(job("sweep")));
    assert.equal(template.match(/permissions:/g)?.length, 2);
  });

  for (const name of ["sweep", "publish"]) {
    test(`${name} is guarded on refs/heads/main and has a timeout`, () => {
      assert.match(job(name), /^ {4}if: .*github\.ref == 'refs\/heads\/main'/m);
      assert.match(job(name), /^ {4}timeout-minutes: [1-9]\d*$/m);
    });
  }

  test("publish keys on !cancelled() and the published output, not on success()", () => {
    const iff = /^ {4}if: (.*)$/m.exec(job("publish"))?.[1] ?? "";
    assert.ok(iff.includes("!cancelled()"));
    assert.ok(iff.includes("needs.sweep.outputs.published == 'true'"));
    assert.ok(!iff.includes("success()"));
    assert.match(job("publish"), /^ {4}needs: sweep$/m);
    assert.match(job("sweep"), /^ {6}published: \$\{\{ steps\.sweep\.outputs\.published \}\}$/m);
  });

  test("the artifact steps run on !cancelled(), so a red sweep still publishes", () => {
    assert.match(step(job("sweep"), "Upload the document"), /^ {8}if: \$\{\{ !cancelled\(\) && steps\.sweep\.outputs\.published == 'true' \}\}$/m);
  });

  test("publish's concurrency never cancels a running publish", () => {
    assert.match(job("publish"), /^ {4}concurrency:\n {6}group: architecture-maps-publish\n {6}cancel-in-progress: false$/m);
    assert.ok(!/cancel-in-progress: true/.test(template));
  });

  test("ESTATE_READ_TOKEN is in the sweep step's env and nowhere else", () => {
    assert.equal(template.match(/ESTATE_READ_TOKEN/g)?.length, 2, "the name and its secret, in one env line");
    assert.match(step(job("sweep"), "Sweep every first-party repo"), /^ {10}ESTATE_READ_TOKEN: \$\{\{ secrets\.ESTATE_READ_TOKEN \}\}$/m);
    assert.ok(!job("publish").includes("ESTATE_READ_TOKEN"));
    assert.ok(!/^env:/m.test(template), "no workflow-level env");
  });

  test("publish is handed GITHUB_TOKEN alone, as PUBLISH_GH_TOKEN", () => {
    assert.deepEqual([...job("publish").matchAll(/secrets\.([A-Z_]+)/g)].map((m) => m[1]), ["GITHUB_TOKEN"]);
    assert.match(step(job("publish"), "Publish to estate-results"), /^ {10}PUBLISH_GH_TOKEN: \$\{\{ secrets\.GITHUB_TOKEN \}\}$/m);
  });

  test("the sweep step runs the sweep, and the publish step runs the picked publisher", () => {
    assert.match(step(job("sweep"), "Sweep every first-party repo"), /^ {8}run: node construct-server\/tools\/architecture-maps\/src\/sweep\.ts$/m);
    const publisher = { a: "tools/base-images/src/publish.ts", b: "tools/estate-publish/src/publish.ts" }[PUBLISHER_OPTION];
    assert.match(step(job("publish"), "Publish to estate-results"), new RegExp(`^ {8}run: node construct-server/${publisher.replace(/\./g, "\\.")} "\\$RUNNER_TEMP/in/architecture-maps\\.json"$`, "m"));
    assert.ok(readFileSync(`${ROOT}/${publisher}`, "utf8").length > 0, "the named publisher exists");
    assert.ok(readFileSync(`${ROOT}/tools/architecture-maps/src/sweep.ts`, "utf8").length > 0);
  });

  test("both jobs check out construct-server at one full SHA, with no token and no persisted credential", () => {
    const pins: string[] = [];
    for (const name of ["sweep", "publish"]) {
      const checkout = /- uses: actions\/checkout@v4\n([\s\S]*?)(?=^ {6}- |$(?![\s\S]))/m.exec(job(name))?.[1] ?? "";
      assert.match(checkout, /^ {10}repository: Einlanzerous\/construct-server$/m);
      assert.match(checkout, /^ {10}persist-credentials: false$/m);
      assert.ok(!/token:/.test(checkout));
      const ref = /^ {10}ref: (.+)$/m.exec(checkout)?.[1] ?? "";
      assert.match(ref, /^[0-9a-f]{40}$/, `${name}'s ref is a 40-hex SHA`);
      pins.push(ref);
    }
    assert.equal(pins[0], pins[1], "both jobs run the same commit");
  });

  test("ruling 0 picked a pinned SHA alone: nothing fetches the estate list from main at run time", () => {
    assert.ok(!/ref: main/.test(template));
    assert.ok(!/gh api/.test(template));
    assert.ok(!/ARCH_MAPS_COMPOSE/.test(template));
    assert.ok(!/docker-compose/.test(template));
  });

  test("no event data is interpolated into a script, and nothing is written to a fixed path", () => {
    assert.ok(!/github\.event\./.test(template));
    assert.ok(!/\$HOME|~\/|\/tmp\//.test(template));
  });

  test("uses: lines are the house form, a major tag of a first-party action", () => {
    const uses = [...template.matchAll(/uses: (\S+)/g)].map((m) => m[1]!);
    assert.ok(uses.length >= 6);
    for (const u of uses) assert.match(u, /^actions\/[a-z-]+@v\d+$/);
  });

  test("the artifact lives one day", () => {
    assert.match(template, /^ {10}retention-days: 1$/m);
  });
});
