import assert from "node:assert/strict";
import { after, before, describe, test } from "node:test";
import { check, cleanup, run, CHECK, tempDir, write, writePolicy } from "./helpers.ts";

// "The guard must be able to fail": each fixture Dockerfile has an expected exit and, where
// it matters, a status that must open a row of the human output. The same fixture is run
// again under --json, which must exit the same and print one schema-1 document alone.
describe("the guard must be able to fail", () => {
  let dir: string;
  let policy: string;
  before(() => {
    dir = tempDir("bi-cases");
    policy = writePolicy(dir);
  });
  after(() => cleanup(dir));

  const D = "0000000000000000000000000000000000000000000000000000000000000000";
  const cases: [string, number, string, string][] = [
    ["clean", 0, "OK", "FROM alpine:3.23 AS build\nFROM build AS test\nFROM gcr.io/distroless/static-debian12:nonroot\nFROM scratch\n"],
    ["eol", 1, "EOL", "FROM alpine:3.20\n"],
    ["floating-major-only", 1, "FLOATING", "FROM alpine:3\n"],
    ["floating-no-version", 1, "FLOATING", "FROM nginx:alpine\n"],
    ["unmapped", 1, "UNMAPPED", "FROM example.com/nobody/mystery:1.0\n"],
    ["unknown-cycle", 1, "UNKNOWN", "FROM alpine:9.99\n"],
    // Ruling position 1: a digest pins the image (rule 2) but cannot say whether its cycle is
    // supported (rule 1), so a digest on a tag that names no cycle stays UNKNOWN, exit 1.
    ["digest-no-cycle", 1, "UNKNOWN", `FROM alpine@sha256:${D}\n`],
    ["eol-soon-warns-only", 0, "SOON", "FROM alpine:3.22\n"],
    ["codename-pinned", 0, "OK", "FROM debian:trixie-slim\n"],
    // No EOL date published (go, nginx): the oldest supported cycle warns once its
    // estimated retirement (newest release + the cadence between the oldest supported
    // cycle and its predecessor) is inside the window — nginx 1.30 here lands
    // ~2026-09-29, 18 days out; go 1.26 lands ~2027-02-17, so it stays OK.
    ["no-date-oldest-in-window-warns", 0, "SOON", "FROM nginx:1.30-alpine\n"],
    ["no-date-oldest-far-ok", 0, "OK", "FROM golang:1.26-bookworm\n"],
    ["no-date-newest-ok", 0, "OK", "FROM nginx:1.31-alpine\n"],
    ["arg-resolved", 0, "OK", "ARG UBUNTU=24.04\nFROM ubuntu:${UBUNTU} AS sdk\n"],
    ["arg-unresolved", 1, "UNRESOLVED", "FROM ubuntu:${UBUNTU}\n"],
    // A FROM that names no image cannot be judged, so it is a finding and not a skip.
    ["from-flags-only", 1, "UNRESOLVED", "FROM --platform=linux/amd64\nFROM alpine:3.23\n"],
    ["from-nothing", 1, "UNRESOLVED", "FROM \nFROM alpine:3.23\n"],
    ["platform-flag-and-digest", 0, "OK", `FROM --platform=linux/amd64 alpine:3.23@sha256:${D} AS x\n`],
  ];

  for (const [name, expect, status, body] of cases) {
    test(`${name}: exit ${expect} (${status})`, () => {
      const file = write(`${dir}/${name}.Dockerfile`, body);
      const plain = check(policy, [file]);
      const json = check(policy, ["--json", file]);
      assert.equal(plain.rc, expect, plain.out + plain.err);
      assert.ok(`${plain.out}${plain.err}`.split("\n").some((l) => l.startsWith(`${status} `)), `no ${status} row in:\n${plain.out}`);
      assert.equal(json.rc, plain.rc, "--json exit differs from the plain exit");
      const doc = JSON.parse(json.out);
      assert.equal(doc.schema, 1);
      assert.ok(Array.isArray(doc.images), "--json stdout is not one schema-1 document");
    });
  }

  test("a missing policy is exit 2, never 0", () => {
    const file = write(`${dir}/p.Dockerfile`, "FROM alpine:3.23\n");
    const r = run(CHECK, [file], { BASE_IMAGE_POLICY_DIR: `${dir}/nowhere`, BASE_IMAGE_TODAY: "2026-09-11" });
    assert.equal(r.rc, 2);
  });

  test("a policy with no releases is exit 2, never read as clean", () => {
    write(`${dir}/empty/alpine-linux.json`, JSON.stringify({ result: { releases: [] } }));
    const file = write(`${dir}/q.Dockerfile`, "FROM alpine:3.23\n");
    assert.equal(run(CHECK, [file], { BASE_IMAGE_POLICY_DIR: `${dir}/empty`, BASE_IMAGE_TODAY: "2026-09-11" }).rc, 2);
  });

  test("the process exit never depends on --json", () => {
    // Covered case by case above; this is the explicit statement of it for the findings case.
    const file = write(`${dir}/r.Dockerfile`, "FROM alpine:3.20\n");
    assert.equal(check(policy, ["--json", file]).rc, 1);
    assert.equal(check(policy, ["--json-out", `${dir}/r.json`, file]).rc, 1);
  });
});
