import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { after, before, describe, test } from "node:test";
import { cleanup, Estate, estateRun, tempDir, withMocks, check, write, writePolicy, type Env, type Result } from "./helpers.ts";

// A public repo with findings, and three repos that must not be named anywhere a CI log
// reaches: private (404 for the low-privilege token) with an EOL and a SOON row, one whose
// privacy lookup fails (500) with a floating tag, and private:true with no Dockerfile. A
// private repo whose file read fails, and a public one that does the same as the control
// that gh's own error text is only held back for the private one.
describe("redaction in CI output (mock gh)", () => {
  let dir: string;
  let policy: string;
  let estate: Estate;
  let compose: string;
  const LEAK = /fx-rpriv|fx-rvis|fx-rflag|fx-rfail|secretpath|vispath|failpath|3\.20|nginx/;

  before(() => {
    dir = tempDir("bi-redact");
    policy = writePolicy(dir);
    estate = new Estate(dir);
    estate.extras();
    estate.repo("fx-pub", "false", { Dockerfile: "FROM alpine:3.23" });
    estate.repo("fx-priv404", "none", { "hiddenpath/Dockerfile": "FROM alpine:3.20" });
    estate.repo("fx-rpub", "false", { "pubpath/Dockerfile": "FROM golang:1.25" });
    estate.repo("fx-rpriv", "none", { "secretpath/Dockerfile": "FROM alpine:3.20\nFROM nginx:1.30-alpine" });
    estate.repo("fx-rvis", "500", { "vispath/Dockerfile": "FROM nginx:alpine" });
    estate.repo("fx-rflag", "true");
    estate.repo("fx-rfail", "none", { "failpath/Dockerfile": "FROM alpine:3.23" }, { failPaths: ["failpath/Dockerfile"] });
    estate.repo("fx-rpubfail", "false", { "failpubpath/Dockerfile": "FROM alpine:3.23" }, { failPaths: ["failpubpath/Dockerfile"] });
    compose = estate.compose("redact", ["fx-rpub", "fx-rpriv", "fx-rvis", "fx-rflag", "fx-rfail", "fx-rpubfail"]);
  });
  after(() => cleanup(dir));

  // red NAME COMPOSE ENV FLAGS: the fixture with the given CI environment; the step summary
  // file is kept so the test can read it.
  const red = (name: string, env: Env, flags: string[] = [], c: string = compose): Result & { sum: string } => {
    const sum = write(`${dir}/${name}.sum`, "");
    const e: Env = { ...env };
    if (e["GITHUB_STEP_SUMMARY"] === "@") e["GITHUB_STEP_SUMMARY"] = sum;
    const r = estateRun(policy, estate, c, flags, e);
    return { ...r, sum };
  };
  const summaryOf = (r: { sum: string }): string => readFileSync(r.sum, "utf8");
  const CI = { GITHUB_ACTIONS: "true", CI: "true", GITHUB_STEP_SUMMARY: "@" };

  test("a CI run exits 1 on the withheld findings, and no withheld name, path or image is anywhere", () => {
    const r = red("ci", CI);
    assert.equal(r.rc, 1, "the alarm must still go red");
    const sum = summaryOf(r);
    for (const [where, text] of [["stdout", r.out], ["stderr", r.err], ["step summary", sum]] as const) {
      assert.ok(!LEAK.test(text), `${where} leaked: ${text.match(LEAK)?.[0]}`);
    }
    assert.ok(!r.out.split("\n").filter((l) => l.startsWith("::")).some((l) => LEAK.test(l)), "an annotation leaked");
  });

  test("the public repo is shown in full: log row, annotation and step summary row", () => {
    const r = red("ci-full", CI);
    assert.match(r.out, /^::error file=fx-rpub\/pubpath\/Dockerfile,line=1::EOL golang:1\.25/m);
    assert.match(r.out, /^EOL +fx-rpub\/pubpath\/Dockerfile:1 +golang:1\.25/m);
    assert.ok(summaryOf(r).includes("`fx-rpub/pubpath/Dockerfile:1`"));
  });

  test("a public repo's gh error text is still replayed (control for the private one)", () => {
    const r = red("ci-ctl", CI);
    assert.ok(r.out.includes("failpubpath"));
    assert.ok(r.err.includes("HTTP 502"));
  });

  // 4 withheld repos: rpriv (EOL + SOON), rvis (FLOATING), rflag (nothing), rfail (UNRESOLVED).
  test("the log and the step summary carry the withheld counts and nothing else; the footer counts the whole estate", () => {
    const r = red("ci-counts", CI);
    const line = "4 repo(s) withheld (private or privacy unknown): 3 finding(s), 1 warning(s)";
    assert.ok(r.out.includes(line));
    assert.ok(summaryOf(r).includes(line));
    // The footer still counts the whole estate: public EOL + public UNRESOLVED + 3 withheld + 1 unreadable visibility.
    assert.match(r.out, /^base images: 6 finding\(s\), 1 warning\(s\)/m);
  });

  test("the same estate outside CI is unchanged: everything shown, the same exit, no withheld line", () => {
    const r = red("local", {});
    assert.equal(r.rc, 1);
    const missing = [
      "fx-rpriv/secretpath/Dockerfile:1",
      "fx-rpriv/secretpath/Dockerfile:2",
      "fx-rvis/vispath/Dockerfile:1",
      "fx-rflag +no Dockerfile",
      "fx-rfail/failpath/Dockerfile:0",
      "alpine:3.20",
      "nginx:alpine",
      "nginx:1.30-alpine",
      "fx-rpub/pubpath/Dockerfile:1",
    ].filter((w) => !new RegExp(w).test(r.out));
    assert.deepEqual(missing, []);
    assert.ok(!r.out.includes("withheld"));
  });

  // Fail safe: anything that looks like a hosted run, or the explicit flag, redacts on its own.
  for (const [name, env, flags] of [
    ["CI alone (an unrecognised CI)", { CI: "1" }, []],
    ["--redact alone, with no CI variable", {}, ["--redact"]],
    ["GITHUB_STEP_SUMMARY alone", { GITHUB_STEP_SUMMARY: "@" }, []],
    ["CI=false (set to anything is on)", { CI: "false" }, []],
  ] as [string, Env, string[]][]) {
    test(`redact: ${name} withholds`, () => {
      const r = red(`fs-${name.length}`, env, flags);
      assert.equal(r.rc, 1);
      for (const t of [r.out, r.err, summaryOf(r)]) assert.ok(!LEAK.test(t));
    });
  }

  test("a blank CI is not a signal: nothing is redacted (blank is not a value)", () => {
    const r = red("blank", { CI: "", GITHUB_ACTIONS: "", GITHUB_STEP_SUMMARY: "" });
    assert.ok(r.out.includes("fx-rpriv/secretpath/Dockerfile:1"));
  });

  // Redaction composes with the filter exactly as the sweep wrapper runs them.
  test("with --json --public-only --redact, the document and the log are both clean", () => {
    const r = red("both", { GITHUB_ACTIONS: "true", CI: "true" }, ["--json", "--public-only", "--redact"]);
    assert.equal(r.rc, 1);
    assert.ok(!LEAK.test(r.out) && !LEAK.test(r.err));
    assert.equal(JSON.parse(r.out).scope, "public-only");
  });

  // A private repo's finding alone, next to a clean public one: red process, counts only.
  test("only a private finding: exit 1, one withheld repo, one finding, no detail", () => {
    const c = estate.compose("redact2", ["fx-pub", "fx-priv404"]);
    const r = red("only", { GITHUB_ACTIONS: "true", CI: "true" }, [], c);
    assert.equal(r.rc, 1);
    assert.ok(!/fx-priv404|hiddenpath|3\.20/.test(r.out + r.err));
    assert.ok(r.out.includes("1 repo(s) withheld (private or privacy unknown): 1 finding(s), 0 warning(s)"));
  });

  test("a clean public estate still exits 0", () => {
    const r = red("clean", { GITHUB_ACTIONS: "true", CI: "true" }, [], estate.compose("redact3", ["fx-pub"]));
    assert.equal(r.rc, 0);
    assert.ok(r.out.includes("0 repo(s) withheld"));
  });

  // --json without --public-only in CI used to print the unfiltered document to the log.
  test("--json alone in CI prints the public-only document, no private repo", () => {
    const c = estate.compose("redact5", ["fx-rpub", "fx-rpriv", "fx-rvis"]);
    const r = red("jsonleak", { GITHUB_ACTIONS: "true", CI: "true" }, ["--json"], c);
    assert.equal(r.rc, 1);
    assert.ok(!LEAK.test(r.out) && !LEAK.test(r.err));
    assert.equal(JSON.parse(r.out).scope, "public-only");
  });

  test("--json-out alone in CI writes the public-only document, no private repo", () => {
    const c = estate.compose("redact6", ["fx-rpub", "fx-rpriv", "fx-rvis"]);
    const out = `${dir}/jsonout.json`;
    const r = red("jsonout", { GITHUB_ACTIONS: "true", CI: "true" }, ["--json-out", out], c);
    assert.equal(r.rc, 1);
    const text = readFileSync(out, "utf8");
    assert.ok(!LEAK.test(text));
    assert.equal(JSON.parse(text).scope, "public-only");
  });

  // No privacy token under redaction is exit 2, never a guess; file modes refuse too.
  test("no PRIVACY_GH_TOKEN in CI: exit 2, nothing printed", () => {
    const r = check(policy, ["--estate", estate.compose("redact4", ["fx-pub"])], withMocks({ GITHUB_ACTIONS: "true", CI: "true", MOCK_GH_DIR: estate.dir, GH_TOKEN: "sweep-token" }));
    assert.equal(r.rc, 2);
    assert.equal(r.out, "");
  });

  test("file and --dir modes in CI refuse (exit 2): they cannot tell a private path", () => {
    const f = write(`${dir}/matrix.Dockerfile`, "FROM alpine:3.20\n");
    const r = check(policy, [f], { GITHUB_ACTIONS: "true", CI: "true" });
    assert.equal(r.rc, 2);
    assert.equal(r.out, "");
    assert.equal(check(policy, ["--dir", dir], { CI: "true" }).rc, 2);
    assert.equal(check(policy, ["--redact", f]).rc, 2);
  });

  // A workflow command ends at a newline and escapes `%`: a FROM line in a public repo's
  // Dockerfile cannot inject one into the log.
  test("an annotation cannot be forged by a Dockerfile's contents", () => {
    const e = new Estate(`${dir}/forge`);
    e.extras();
    e.repo("fx-forge", "false", { Dockerfile: "FROM example.com/x%0A::error::forged:1.0" });
    const r = estateRun(policy, e, e.compose("forge", ["fx-forge"]), [], { GITHUB_ACTIONS: "true", CI: "true" });
    assert.ok(!r.out.split("\n").some((l) => l.startsWith("::error::forged")));
  });
});
