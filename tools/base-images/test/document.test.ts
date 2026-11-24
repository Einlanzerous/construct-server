import assert from "node:assert/strict";
import { chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { after, before, describe, test } from "node:test";
import { check, cleanup, run, CHECK, ROOT, tempDir, write, writePolicy, type Result } from "./helpers.ts";

const ZEROS = "0".repeat(64);

describe("the document", () => {
  let dir: string;
  let policy: string;
  let matrix: string;
  let result: Result;
  let doc: any;

  before(() => {
    dir = tempDir("bi-doc");
    policy = writePolicy(dir);
    // One fixture, every status. Stdout is the document alone: it is read WITHOUT stderr.
    matrix = write(
      `${dir}/matrix.Dockerfile`,
      [
        "FROM alpine:3.23",
        "FROM alpine:3.20",
        "FROM alpine:3",
        `FROM alpine@sha256:${ZEROS}`,
        "FROM alpine:3.22",
        "FROM nginx:1.30-alpine",
        "FROM golang:1.26-bookworm",
        "FROM nginx:1.31-alpine",
        "FROM example.com/nobody/mystery:1.0",
        "FROM alpine:9.99",
        "FROM ubuntu:${NOARG}",
        "",
      ].join("\n"),
    );
    result = check(policy, ["--json", matrix]);
    doc = JSON.parse(result.out);
  });
  after(() => cleanup(dir));

  test("matrix: --json keeps process exit 1", () => assert.equal(result.rc, 1));

  test("matrix: schema 1, files mode, unfiltered", () => {
    assert.equal(doc.schema, 1);
    assert.equal(doc.mode, "files");
    assert.equal(doc.scope, "unfiltered");
    assert.equal(doc.repos, null);
    assert.equal(doc.exit, 1);
  });

  // Key order is part of the shape: the bash this replaced built the object in this order and
  // a consumer may diff bytes.
  test("matrix: golden top-level keys, in order", () => {
    assert.deepEqual(Object.keys(doc), ["schema", "scope", "generatedAt", "today", "policy", "mode", "exit", "summary", "repos", "images"]);
    assert.deepEqual(Object.keys(doc.policy), ["source", "warnDays"]);
  });

  test("matrix: golden summary keys", () => {
    assert.deepEqual(Object.keys(doc.summary), ["findings", "warnings", "ok", "unreadableRepos", "withheldRepos", "visibilityUnreadable"]);
  });

  test("matrix: golden image keys on every row", () => {
    const keys = ["repo", "path", "line", "ref", "image", "tag", "digest", "product", "cycle", "eolDate", "eolDateEstimated", "newestSupported", "status", "detail"];
    for (const row of doc.images) assert.deepEqual(Object.keys(row), keys);
  });

  test("matrix: status, cycle, dates, newest, image, tag, digest per fixture", () => {
    const got = doc.images.map((i: any) => [i.status, i.cycle, i.eolDate, i.eolDateEstimated, i.newestSupported, i.image, i.tag, i.digest]);
    assert.deepEqual(got, [
      ["OK", "3.23", "2027-11-01", false, "3.23", "alpine", "3.23", null],
      ["EOL", "3.20", "2026-04-01", false, "3.23", "alpine", "3.20", null],
      ["FLOATING", null, null, false, "3.23", "alpine", "3", null],
      ["UNKNOWN", null, null, false, "3.23", "alpine", null, `sha256:${ZEROS}`],
      ["SOON", "3.22", "2026-11-01", false, "3.23", "alpine", "3.22", null],
      ["SOON", "1.30", "2026-09-29", true, "1.31", "nginx", "1.30-alpine", null],
      ["OK", "1.26", "2027-02-17", true, "1.27", "golang", "1.26-bookworm", null],
      ["OK", "1.31", null, false, "1.31", "nginx", "1.31-alpine", null],
      ["UNMAPPED", null, null, false, null, "example.com/nobody/mystery", "1.0", null],
      ["UNKNOWN", null, null, false, "3.23", "alpine", "9.99", null],
      ["UNRESOLVED", null, null, false, null, null, null, null],
    ]);
  });

  test("matrix: nothing is coalesced to an empty string or 0", () => {
    const strings: string[] = [];
    const walk = (v: unknown): void => {
      if (typeof v === "string") strings.push(v);
      else if (Array.isArray(v)) v.forEach(walk);
      else if (v && typeof v === "object") Object.values(v).forEach(walk);
    };
    walk(doc.images);
    assert.ok(!strings.includes(""));
    assert.ok(doc.images.every((i: any) => i.line > 0));
  });

  test("matrix: one object per FROM line the human output reports (11), on stderr", () => {
    const shown = result.err.split("\n").filter((l) => /^(OK|SOON|EOL|FLOATING|UNMAPPED|UNKNOWN|UNRESOLVED) /.test(l)).length;
    assert.equal(shown, 11);
    assert.equal(doc.images.length, 11);
  });

  test("a digest with no cycle (position 1): UNKNOWN, no cycle, digest kept", () => {
    const i = doc.images[3];
    assert.equal(i.status, "UNKNOWN");
    assert.equal(i.cycle, null);
    assert.ok(i.digest.startsWith("sha256:"));
  });

  test("summary reconciles with images", () => {
    assert.deepEqual(doc.summary, { findings: 6, warnings: 2, ok: 3, unreadableRepos: 0, withheldRepos: null, visibilityUnreadable: null });
  });

  test("the document is serialised as jq printed it: two-space indent, trailing newline", () => {
    assert.equal(result.out, JSON.stringify(doc, null, 2) + "\n");
  });

  test("--json-out writes the file and leaves the table on stdout", () => {
    const out = `${dir}/o.json`;
    const r = check(policy, ["--json-out", out, matrix]);
    assert.equal(r.rc, 1);
    assert.equal(JSON.parse(readFileSync(out, "utf8")).schema, 1);
    assert.ok(r.out.split("\n").some((l) => l.startsWith("EOL ")));
  });

  test("--json and --json-out carry the same bytes", () => {
    const out = `${dir}/same.json`;
    const r = check(policy, ["--json", "--json-out", out, matrix]);
    assert.equal(readFileSync(out, "utf8"), r.out);
  });

  // The digest wording agrees across the three texts (position 1).
  test("digest wording: --help and docs/base-images.md say UNKNOWN for a digest with no cycle", () => {
    const phrase = "digest-pinned ref whose tag names no cycle";
    const help = run(CHECK, ["--help"]);
    assert.ok(help.out.includes(phrase));
    assert.ok(readFileSync(`${ROOT}/docs/base-images.md`, "utf8").includes(phrase));
    assert.ok(help.out.includes("a digest-pinned ref whose tag names no cycle (UNKNOWN"));
  });

  // --help prints the whole manual and keeps exit 2 (the usage exit).
  test("--help: whole header on stdout, exit 2", () => {
    const r = run(CHECK, ["--help"]);
    assert.equal(r.rc, 2);
    assert.ok(r.out.includes("The workflow runs it before the real check."));
    assert.equal(run(CHECK, []).rc, 2);
    assert.equal(run(CHECK, ["-h"]).rc, 2);
  });

  test("--help under --json goes to stderr, stdout stays empty", () => {
    const r = run(CHECK, ["--json", "--help"]);
    assert.equal(r.rc, 2);
    assert.equal(r.out, "");
    assert.ok(r.err.includes("The workflow runs it before the real check."));
  });

  // Exit 2 prints nothing to stdout and leaves no file, even over a stale one.
  test("policy unreachable: exit 2, empty stdout, stale --json-out removed", () => {
    const clean = write(`${dir}/clean.Dockerfile`, "FROM alpine:3.23\n");
    const stale = write(`${dir}/stale.json`, "stale\n");
    const r = run(CHECK, ["--json", "--json-out", stale, clean], { BASE_IMAGE_POLICY_DIR: `${dir}/nowhere` });
    assert.equal(r.rc, 2);
    assert.equal(r.out, "");
    assert.ok(!existsSync(stale));
  });

  // The old test injected a jq failure into the assembly. There is no jq now; the equivalent
  // failure at the same seam is a document that cannot be written. It is exit 2, never 1, with
  // no document on stdout or on disk.
  test("a document that cannot be written: exit 2, empty stdout, no file", () => {
    const ro = `${dir}/readonly`;
    mkdirSync(ro);
    chmodSync(ro, 0o555);
    try {
      const r = check(policy, ["--json", "--json-out", `${ro}/j.json`, matrix]);
      if (process.getuid?.() === 0) return; // root writes anywhere; the case cannot be staged
      assert.equal(r.rc, 2);
      assert.equal(r.out, "");
      assert.ok(!existsSync(`${ro}/j.json`));
      assert.ok(r.err.includes("could not write"));
    } finally {
      chmodSync(ro, 0o755);
    }
  });

  test("control: the same run into a writable directory exits 1 and writes the file", () => {
    const r = check(policy, ["--json", "--json-out", `${dir}/j2.json`, matrix]);
    assert.equal(r.rc, 1);
    assert.ok(readFileSync(`${dir}/j2.json`, "utf8").length > 0);
  });

  test("--json-out into a directory that does not exist is exit 2", () => {
    const r = check(policy, ["--json-out", `${dir}/no/such/dir/o.json`, matrix]);
    assert.equal(r.rc, 2);
  });

  test("--json-out with no file is exit 2", () => {
    assert.equal(check(policy, [matrix, "--json-out"]).rc, 2);
  });

  // A product with no supported cycle left: newestSupported is null, not the string "null".
  test("all cycles EOL: newestSupported is JSON null, not the string \"null\"", () => {
    write(`${dir}/policy/python.json`, JSON.stringify({ result: { name: "python", releases: [{ name: "3.8", codename: null, isEol: true, eolFrom: "2024-10-07" }] } }));
    const f = write(`${dir}/alleol.Dockerfile`, "FROM python:3.8\n");
    const d = JSON.parse(check(policy, ["--json", f]).out);
    const i = d.images[0];
    assert.equal(i.status, "EOL");
    assert.equal(i.newestSupported, null);
    assert.ok(!i.detail.includes("newest supported is null"));
  });

  test("a directory named like a Dockerfile is not a file: exit 2", () => {
    mkdirSync(`${dir}/trap.Dockerfile`, { recursive: true });
    assert.equal(check(policy, [`${dir}/trap.Dockerfile`]).rc, 2);
  });

  test("a malformed BASE_IMAGE_WARN_DAYS or BASE_IMAGE_TODAY is exit 2; blank is the default", () => {
    const f = write(`${dir}/w.Dockerfile`, "FROM alpine:3.22\n");
    assert.equal(check(policy, [f], { BASE_IMAGE_WARN_DAYS: "soon" }).rc, 2);
    assert.equal(check(policy, [f], { BASE_IMAGE_TODAY: "tomorrow" }).rc, 2);
    assert.equal(check(policy, [f], { BASE_IMAGE_WARN_DAYS: "" }).rc, 0);
    // The window decides warning from nothing: 3.22 ends 2026-11-01, 51 days after the fixture clock.
    const narrow = JSON.parse(check(policy, ["--json", f], { BASE_IMAGE_WARN_DAYS: "10" }).out);
    assert.equal(narrow.images[0].status, "OK");
    assert.equal(narrow.policy.warnDays, 10);
  });

  test("file arguments that do not exist are exit 2", () => {
    assert.equal(check(policy, [`${dir}/missing.Dockerfile`]).rc, 2);
  });

  test("--dir finds Dockerfile*, *.Dockerfile and Containerfile*, and prunes node_modules, vendor and .git", () => {
    const tree = `${dir}/tree`;
    write(`${tree}/a/Dockerfile`, "FROM alpine:3.23\n");
    write(`${tree}/b/web.Dockerfile`, "FROM alpine:3.23\n");
    write(`${tree}/c/Containerfile.prod`, "FROM alpine:3.23\n");
    write(`${tree}/node_modules/x/Dockerfile`, "FROM alpine:3.20\n");
    write(`${tree}/vendor/Dockerfile`, "FROM alpine:3.20\n");
    write(`${tree}/.git/Dockerfile`, "FROM alpine:3.20\n");
    const d = JSON.parse(check(policy, ["--json", "--dir", tree]).out);
    assert.equal(d.mode, "dir");
    assert.deepEqual(d.images.map((i: any) => i.path), [`${tree}/a/Dockerfile`, `${tree}/b/web.Dockerfile`, `${tree}/c/Containerfile.prod`]);
    assert.equal(check(policy, ["--dir", `${dir}/nothing-here`]).rc, 2);
    mkdirSync(`${dir}/empty-tree`);
    assert.equal(check(policy, ["--dir", `${dir}/empty-tree`]).rc, 2);
    writeFileSync(`${dir}/not-a-dir`, "");
    assert.equal(check(policy, ["--dir", `${dir}/not-a-dir`]).rc, 2);
  });
});
