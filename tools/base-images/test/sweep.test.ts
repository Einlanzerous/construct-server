import assert from "node:assert/strict";
import { chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { after, before, describe, test } from "node:test";
import { cleanup, run, SWEEP, tempDir, write, type Env } from "./helpers.ts";

// The wrapper's contract is its exit handling, so the check it runs is a fake: FAKE_RC is its
// exit, FAKE_WRITE=1 makes it write the document it was asked for, and it records its argv so
// the test can see what the wrapper passed.
describe("the sweep wrapper", () => {
  let T: string;
  let fake: string;
  let runnerTemp: string;
  let output: string;

  before(() => {
    T = tempDir("bi-sweep");
    runnerTemp = `${T}/runner`;
    mkdirSync(runnerTemp);
    fake = `${T}/fake-check`;
    writeFileSync(
      fake,
      `#!/usr/bin/env node
const fs = require("node:fs");
const argv = process.argv.slice(2);
fs.writeFileSync(process.env.FAKE_ARGV, argv.join("\\n") + "\\n");
const i = argv.indexOf("--json-out");
if (process.env.FAKE_WRITE === "1" && i !== -1) fs.writeFileSync(argv[i + 1], '{"schema":1}\\n');
process.exit(Number(process.env.FAKE_RC || 0));
`,
    );
    chmodSync(fake, 0o755);
    output = `${T}/github-output`;
  });
  after(() => cleanup(T));

  const sweep = (rc: number, writeDoc: boolean, stale = false, env: Env = {}): { rc: number; out: string } => {
    write(output, "");
    mkdirSync(`${runnerTemp}/out`, { recursive: true });
    const doc = `${runnerTemp}/out/base-images.json`;
    if (existsSync(doc)) writeFileSync(doc, "");
    if (stale) writeFileSync(doc, "stale\n");
    else if (existsSync(doc)) writeFileSync(doc, "");
    const r = run(SWEEP, [], {
      BASE_IMAGES_CHECK: fake,
      FAKE_RC: String(rc),
      FAKE_WRITE: writeDoc ? "1" : "0",
      FAKE_ARGV: `${T}/fake.argv`,
      GITHUB_OUTPUT: output,
      RUNNER_TEMP: runnerTemp,
      ...env,
    });
    return { rc: r.rc, out: readFileSync(output, "utf8") };
  };
  const staleGone = (): boolean => !existsSync(`${runnerTemp}/out/base-images.json`) || readFileSync(`${runnerTemp}/out/base-images.json`, "utf8") === "";

  test("exit 1 with a document: published=true, still exits 1 (a week with findings still publishes)", () => {
    const r = sweep(1, true);
    assert.equal(r.rc, 1);
    assert.match(r.out, /^published=true$/m);
    assert.ok(readFileSync(`${runnerTemp}/out/base-images.json`, "utf8").includes('"schema":1'));
  });

  test("exit 0 with a document: published=true, exits 0", () => {
    const r = sweep(0, true);
    assert.equal(r.rc, 0);
    assert.match(r.out, /^published=true$/m);
  });

  test("exit 2 with no file: no output, exits 2", () => {
    const r = sweep(2, false);
    assert.equal(r.rc, 2);
    assert.equal(r.out, "");
  });

  test("a stale file from an earlier step is never published after exit 2", () => {
    const r = sweep(2, false, true);
    assert.equal(r.rc, 2);
    assert.equal(r.out, "");
    assert.ok(!existsSync(`${runnerTemp}/out/base-images.json`));
  });

  test("a stale file is never mistaken for this run's document after a clean exit that wrote none", () => {
    const r = sweep(0, false, true);
    assert.equal(r.rc, 0);
    assert.equal(r.out, "");
  });

  test("exit 2 is never published even if a file appeared", () => {
    const r = sweep(2, true);
    assert.equal(r.rc, 2);
    assert.equal(r.out, "");
    assert.ok(!existsSync(`${runnerTemp}/out/base-images.json`));
  });

  test("the wrapper runs the estate sweep with --json-out, --public-only and --redact (SERV-350)", () => {
    sweep(0, true);
    const argv = readFileSync(`${T}/fake.argv`, "utf8").split("\n");
    for (const a of ["--estate", "--json-out", "--public-only", "--redact"]) assert.ok(argv.includes(a), `${a} missing from ${argv.join(" ")}`);
    assert.ok(argv[argv.indexOf("--estate") + 1]?.endsWith("/docker-compose.yml"));
    assert.equal(argv[argv.indexOf("--json-out") + 1], `${runnerTemp}/out/base-images.json`);
  });

  test("a missing RUNNER_TEMP or GITHUB_OUTPUT is exit 2, and nothing is written to a fixed path", () => {
    assert.equal(run(SWEEP, [], { BASE_IMAGES_CHECK: fake, GITHUB_OUTPUT: output }).rc, 2);
    assert.equal(run(SWEEP, [], { BASE_IMAGES_CHECK: fake, RUNNER_TEMP: runnerTemp }).rc, 2);
  });

  test("a check that cannot be run is exit 2, not a published document", () => {
    write(output, "");
    const r = run(SWEEP, [], { BASE_IMAGES_CHECK: `${T}/nonexistent`, GITHUB_OUTPUT: output, RUNNER_TEMP: runnerTemp });
    assert.equal(r.rc, 2);
    assert.equal(readFileSync(output, "utf8"), "");
  });

  // The default check is check.ts beside the wrapper: with the real program, no gh and no
  // policy, the wrapper must report the program's own exit 2 and publish nothing.
  test("with the real check and nothing to run it against: exit 2, no output", () => {
    write(output, "");
    const r = run(SWEEP, [], { GITHUB_OUTPUT: output, RUNNER_TEMP: runnerTemp, PATH: "/nonexistent-dir:" + process.env["PATH"], PRIVACY_GH_TOKEN: "x", BASE_IMAGE_POLICY_DIR: `${T}/no-policy` });
    assert.equal(r.rc, 2);
    assert.equal(readFileSync(output, "utf8"), "");
    assert.ok(staleGone());
  });
});
