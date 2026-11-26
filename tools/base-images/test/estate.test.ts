import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { after, before, describe, test } from "node:test";
import { check, cleanup, Estate, estateRun, run, CHECK, tempDir, withMocks, write, writePolicy } from "./helpers.ts";

describe("estate states (mock gh)", () => {
  let dir: string;
  let policy: string;
  let estate: Estate;
  let compose: string;

  before(() => {
    dir = tempDir("bi-estate");
    policy = writePolicy(dir);
    estate = new Estate(dir);
    estate.extras();
    estate.repo("fx-ok", "false", { Dockerfile: "FROM alpine:3.23" });
    estate.repo("fx-none", "false");
    estate.repo("fx-unread", "false", {}, { treeFail: true });
    estate.repo("fx-mixed", "false", { Dockerfile: "FROM alpine:3.23", "docker/web.Dockerfile": "FROM alpine:3.23" }, { failPaths: ["docker/web.Dockerfile"] });
    estate.repo("fx-allfail", "false", { Dockerfile: "FROM alpine:3.23", "b.Dockerfile": "FROM alpine:3.23" }, { failPaths: ["Dockerfile", "b.Dockerfile"] });
    compose = estate.compose("states", ["fx-ok", "fx-none", "fx-unread", "fx-mixed", "fx-allfail"]);
  });
  after(() => cleanup(dir));

  test("states: read, partial, unreadable, no_dockerfile, in repo order", () => {
    const r = estateRun(policy, estate, compose, ["--json"]);
    assert.equal(r.rc, 1);
    const doc = JSON.parse(r.out);
    assert.deepEqual(
      doc.repos.map((x: any) => [x.repo, x.state]),
      [
        ["construct-server", "read"],
        ["cta-watch", "no_dockerfile"],
        ["fx-allfail", "unreadable"],
        ["fx-mixed", "partial"],
        ["fx-none", "no_dockerfile"],
        ["fx-ok", "read"],
        ["fx-unread", "unreadable"],
        ["signet", "no_dockerfile"],
      ],
    );
    assert.deepEqual(Object.keys(doc.repos[0]), ["repo", "state", "unreadablePaths"]);
  });

  test("states: unreadablePaths names the failed paths, null otherwise", () => {
    const doc = JSON.parse(estateRun(policy, estate, compose, ["--json"]).out);
    const by = (n: string) => doc.repos.find((x: any) => x.repo === n).unreadablePaths;
    assert.deepEqual(by("fx-mixed"), ["docker/web.Dockerfile"]);
    assert.deepEqual(by("fx-allfail"), ["Dockerfile", "b.Dockerfile"]);
    assert.equal(doc.repos.filter((x: any) => x.unreadablePaths === null).length, 6);
  });

  test("states: an unreadable repo is not in images[]; a partial repo keeps its readable rows; no line 0", () => {
    const doc = JSON.parse(estateRun(policy, estate, compose, ["--json"]).out);
    assert.equal(doc.images.filter((i: any) => i.repo === "fx-unread" || i.repo === "fx-allfail").length, 0);
    assert.deepEqual(doc.images.filter((i: any) => i.repo === "fx-mixed").map((i: any) => i.path), ["Dockerfile"]);
    assert.ok(doc.images.every((i: any) => i.line > 0));
  });

  test("states: summary counts unreadable plus partial; document exit 1; unfiltered nulls", () => {
    const doc = JSON.parse(estateRun(policy, estate, compose, ["--json"]).out);
    assert.equal(doc.exit, 1);
    assert.equal(doc.scope, "unfiltered");
    assert.deepEqual(doc.summary, { findings: 3, warnings: 0, ok: 3, unreadableRepos: 3, withheldRepos: null, visibilityUnreadable: null });
  });

  test("states: the plain run exits 1 too", () => {
    const r = check(policy, ["--estate", compose], withMocks({ MOCK_GH_DIR: estate.dir, GH_TOKEN: "sweep-token" }));
    assert.equal(r.rc, 1);
  });

  test("states: a repo derived from the compose file is read even with its image name in upper case, quoted or overridden", () => {
    const e = new Estate(`${dir}/derive`);
    e.extras();
    e.repo("chronicle", "false", { Dockerfile: "FROM alpine:3.23" });
    e.repo("mixedcase", "false", { Dockerfile: "FROM alpine:3.23" });
    const c = write(`${dir}/derive/compose.yml`, 'services:\n  a:\n    image: "ghcr.io/Einlanzerous/estate-asr:1"\n  b:\n    image: ghcr.io/einlanzerous/MixedCase:2\n  c:\n    image: ghcr.io/other/ignored:1\n');
    const doc = JSON.parse(estateRun(policy, e, c, ["--json"]).out);
    assert.deepEqual(doc.repos.map((x: any) => x.repo), ["chronicle", "construct-server", "cta-watch", "mixedcase", "signet"]);
  });

  test("a compose file that names no first-party image is exit 2, not a sweep of EXTRA_REPOS alone", () => {
    const c = write(`${dir}/none.yml`, "services:\n  a:\n    image: nginx:1.31\n");
    assert.equal(estateRun(policy, estate, c).rc, 2);
  });

  test("a missing compose file, or no Dockerfile anywhere, is exit 2", () => {
    assert.equal(estateRun(policy, estate, `${dir}/nope.yml`).rc, 2);
    const e = new Estate(`${dir}/barren`);
    e.repo("construct-server", "false");
    e.repo("signet", "false");
    e.repo("cta-watch", "false");
    e.repo("fx-x", "false");
    assert.equal(estateRun(policy, e, e.compose("barren", ["fx-x"])).rc, 2);
  });

  test("gh missing from PATH is exit 2", () => {
    const r = run(CHECK, ["--estate", compose], { BASE_IMAGE_POLICY_DIR: policy, BASE_IMAGE_TODAY: "2026-09-11", PATH: "/nonexistent-dir" });
    assert.equal(r.rc, 2);
    assert.ok(r.err.includes("'gh' not found"));
  });
});

describe("privacy gate (mock gh)", () => {
  let dir: string;
  let policy: string;
  let estate: Estate;
  let compose: string;

  before(() => {
    dir = tempDir("bi-gate");
    policy = writePolicy(dir);
    estate = new Estate(dir);
    estate.extras();
    // One public repo; a private one (404 for the low-privilege token) carrying an EOL image;
    // one reporting private:true; one whose visibility lookup fails with a 500.
    estate.repo("fx-pub", "false", { Dockerfile: "FROM alpine:3.23" });
    estate.repo("fx-priv404", "none", { "hiddenpath/Dockerfile": "FROM alpine:3.20" });
    estate.repo("fx-privflag", "true", { "flagpath/Dockerfile": "FROM alpine:3.23" });
    estate.repo("fx-vis500", "500", { "v500path/Dockerfile": "FROM nginx:1.31-alpine" });
    compose = estate.compose("gate", ["fx-pub", "fx-priv404", "fx-privflag", "fx-vis500"]);
  });
  after(() => cleanup(dir));

  const findings = (doc: any): number => doc.images.filter((i: any) => ["EOL", "FLOATING", "UNMAPPED", "UNKNOWN", "UNRESOLVED"].includes(i.status)).length;

  test("gate: the failed lookup makes the process exit 1; only public repos appear; nothing withheld leaks", () => {
    const out = `${dir}/pg.json`;
    const r = estateRun(policy, estate, compose, ["--json", "--json-out", out, "--public-only"]);
    assert.equal(r.rc, 1);
    const doc = JSON.parse(readFileSync(out, "utf8"));
    assert.deepEqual(doc.repos.map((x: any) => x.repo), ["construct-server", "cta-watch", "fx-pub", "signet"]);
    assert.deepEqual([...new Set(doc.images.map((i: any) => i.repo))].sort(), ["construct-server", "fx-pub"]);
    assert.equal(doc.scope, "public-only");
    const leak = /fx-priv|fx-vis500|hiddenpath|flagpath|v500path|alpine:3\.20|1\.31-alpine/;
    assert.ok(!leak.test(readFileSync(out, "utf8")), "a withheld repo, path or image leaked into the file");
    assert.ok(!leak.test(r.out), "a withheld repo, path or image leaked into stdout");
    assert.equal(readFileSync(out, "utf8"), r.out, "--json and --json-out carry the same bytes");
    assert.equal(doc.summary.withheldRepos, 2);
    assert.equal(doc.summary.visibilityUnreadable, 1);
    assert.equal(doc.exit, 1);
    assert.equal(doc.summary.findings, 0);
    assert.ok(r.err.includes("WITHHELD") && r.err.includes("unreadable visibility"), "stderr lacks the WITHHELD / unreadable visibility lines");
    const loud = r.err.split("\n").filter((l) => /WITHHELD|unreadable visibility/.test(l)).join("\n");
    assert.ok(!/fx-priv|fx-vis500/.test(loud), "a withheld name is in the WITHHELD lines");
    assert.equal(findings(doc) + doc.summary.unreadableRepos, doc.summary.findings);
  });

  // A private repo's EOL finding changes neither the summary nor the document exit.
  test("gate: a private EOL finding still turns the process exit red while the document stays clean", () => {
    const c = estate.compose("gate2", ["fx-pub", "fx-priv404"]);
    const r = estateRun(policy, estate, c, ["--json", "--public-only"]);
    assert.equal(r.rc, 1);
    const doc = JSON.parse(r.out);
    assert.equal(doc.exit, 0);
    assert.equal(doc.summary.findings, 0);
    assert.equal(doc.summary.withheldRepos, 1);
    assert.equal(doc.summary.visibilityUnreadable, 0);
    assert.equal(findings(doc) + doc.summary.unreadableRepos, doc.summary.findings);
    assert.ok(doc.exit <= r.rc, "document exit exceeds the process exit");

    // Control: the same estate without the filter shows it. Delete the filter and this goes red.
    const open = JSON.parse(estateRun(policy, estate, c, ["--json"]).out);
    assert.equal(open.scope, "unfiltered");
    assert.ok(open.repos.some((x: any) => x.repo === "fx-priv404"));
    assert.equal(open.summary.withheldRepos, null);
    assert.equal(open.summary.visibilityUnreadable, null);
    assert.equal(open.exit, 1);
    assert.equal(findings(open) + open.summary.unreadableRepos, open.summary.findings);
  });

  test("--public-only without PRIVACY_GH_TOKEN: exit 2, empty stdout", () => {
    const r = check(policy, ["--json", "--public-only", "--estate", compose], withMocks({ MOCK_GH_DIR: estate.dir, GH_TOKEN: "sweep-token" }));
    assert.equal(r.rc, 2);
    assert.equal(r.out, "");
  });

  test("--public-only with a blank PRIVACY_GH_TOKEN: exit 2 (blank is not a value)", () => {
    const r = estateRun(policy, estate, compose, ["--public-only"], { PRIVACY_GH_TOKEN: "" });
    assert.equal(r.rc, 2);
  });

  test("--public-only outside --estate: exit 2", () => {
    const f = write(`${dir}/clean.Dockerfile`, "FROM alpine:3.23\n");
    assert.equal(check(policy, ["--public-only", f], { PRIVACY_GH_TOKEN: "public-token" }).rc, 2);
    assert.equal(check(policy, ["--public-only", "--self-test"], { PRIVACY_GH_TOKEN: "public-token" }).rc, 2);
  });

  test("the privacy token decides, not the sweep token: a 404 for it is private whatever GH_TOKEN could read", () => {
    // fx-priv404 has no vis file for public-token, so a lookup made with the sweep token (which
    // the mock also has no file for) cannot be what makes it public.
    const c = estate.compose("gate3", ["fx-pub", "fx-priv404"]);
    const doc = JSON.parse(estateRun(policy, estate, c, ["--json", "--public-only"], { GH_TOKEN: "public-token" }).out);
    assert.ok(!doc.repos.some((x: any) => x.repo === "fx-priv404"));
  });
});
