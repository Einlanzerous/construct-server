import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { basename, dirname } from "node:path";
import { after, before, describe, test } from "node:test";
import { cleanup, MOCK, PUBLISH, run, tempDir, withMocks, write, type Env, type Result } from "./helpers.ts";

// Every case here can fail: each refusal is checked against a branch that must stay untouched.
// The `git` on PATH is a shim over the real one (mock-bin/git): inert unless SHIM_LOG says
// to record every argv, or SHIM_RACE_* says to let a competing publisher push first.
const GIT_ENV = {
  GIT_CONFIG_GLOBAL: "/dev/null",
  GIT_CONFIG_SYSTEM: "/dev/null",
  GIT_AUTHOR_NAME: "test",
  GIT_AUTHOR_EMAIL: "test@example.invalid",
  GIT_COMMITTER_NAME: "test",
  GIT_COMMITTER_EMAIL: "test@example.invalid",
};
// Synthetic: it only has to be recognisable if it ever shows up somewhere it must not.
const TOKEN = "sentinel-token-0123456789abcdef";

describe("publish", () => {
  let T: string;
  let runnerTemp: string;
  const git = (cwd: string, ...args: string[]): string =>
    spawnSync("git", ["-C", cwd, ...args], { env: { ...process.env, ...GIT_ENV }, encoding: "utf8" }).stdout.trim();
  const bare = (p: string): string => {
    spawnSync("git", ["init", "-q", "--bare", p], { env: { ...process.env, ...GIT_ENV } });
    return p;
  };
  const branchSha = (remote: string): string => git(remote, "rev-parse", "-q", "--verify", "refs/heads/estate-results");
  // The publisher reads the document's NAME from its basename, so a fixture `<dir>/x.json` lives
  // at `<dir>/x/base-images.json`. nm() maps one to the other and leaves a path that already
  // carries a publishable name alone, so a test body keeps naming its fixtures as before.
  const nm = (p: string): string => (["base-images.json", "architecture-maps.json"].includes(basename(p)) ? p : `${dirname(p)}/${basename(p, ".json")}/base-images.json`);
  const mkdoc = (file: string, generatedAt: string, scope = "public-only", schema: unknown = 1): string =>
    write(nm(file), JSON.stringify({ schema, scope, generatedAt, today: "2026-11-23", mode: "estate", exit: 0, summary: { findings: 0 }, repos: [], images: [] }, null, 2) + "\n");
  const publish = (remote: string, doc: string, env: Env = {}): Result =>
    run(PUBLISH, [nm(doc)], withMocks({ ...GIT_ENV, RUNNER_TEMP: runnerTemp, PUBLISH_REMOTE: remote, PUBLISH_GH_TOKEN: TOKEN, ...env }));

  before(() => {
    T = tempDir("bi-publish");
    runnerTemp = `${T}/runner`;
    mkdirSync(runnerTemp);
  });
  after(() => cleanup(T));

  describe("refusals", () => {
    let R: string;
    before(() => {
      R = bare(`${T}/refuse.git`);
      mkdoc(`${T}/good.json`, "2026-11-23T07:00:00Z");
    });

    const bad: [string, () => string][] = [
      ["unfiltered", () => mkdoc(`${T}/unfiltered.json`, "2026-11-23T07:00:00Z", "unfiltered")],
      ["schema2", () => mkdoc(`${T}/schema2.json`, "2026-11-23T07:00:00Z", "public-only", 2)],
      ["a schema that is the string \"1\"", () => mkdoc(`${T}/schemastr.json`, "2026-11-23T07:00:00Z", "public-only", "1")],
      ["garbage", () => write(nm(`${T}/garbage.json`), "not json\n")],
      ["noscope", () => write(nm(`${T}/noscope.json`), JSON.stringify({ schema: 1, generatedAt: "2026-11-23T07:00:00Z" }))],
      ["nogen", () => write(nm(`${T}/nogen.json`), JSON.stringify({ schema: 1, scope: "public-only" }))],
      ["a generatedAt that is not a timestamp", () => mkdoc(`${T}/badgen.json`, "yesterday")],
      ["a generatedAt in another shape", () => mkdoc(`${T}/shapegen.json`, "2026-11-23 07:00:00")],
      ["a JSON array", () => write(nm(`${T}/array.json`), "[]")],
    ];
    for (const [name, make] of bad) {
      test(`refuses ${name}: exit 2, nothing pushed`, () => {
        const r = publish(R, make());
        assert.equal(r.rc, 2, r.err);
        assert.equal(branchSha(R), "");
      });
    }

    test("refuses a missing file: exit 2", () => assert.equal(publish(R, `${T}/missing.json`).rc, 2));
    test("refuses no argument and two arguments: exit 2", () => {
      const env = withMocks({ ...GIT_ENV, RUNNER_TEMP: runnerTemp, PUBLISH_REMOTE: R, PUBLISH_GH_TOKEN: TOKEN });
      assert.equal(run(PUBLISH, [], env).rc, 2);
      assert.equal(run(PUBLISH, [nm(`${T}/good.json`), nm(`${T}/good.json`)], env).rc, 2);
    });
    test("a missing PUBLISH_GH_TOKEN exits 2, nothing pushed", () => {
      const r = run(PUBLISH, [nm(`${T}/good.json`)], withMocks({ ...GIT_ENV, RUNNER_TEMP: runnerTemp, PUBLISH_REMOTE: R }));
      assert.equal(r.rc, 2);
      assert.equal(branchSha(R), "");
    });
    test("a blank PUBLISH_GH_TOKEN exits 2", () => assert.equal(publish(R, `${T}/good.json`, { PUBLISH_GH_TOKEN: "" }).rc, 2));
    test("a missing RUNNER_TEMP exits 2", () => assert.equal(publish(R, `${T}/good.json`, { RUNNER_TEMP: undefined }).rc, 2));
    // An unreachable remote is exit 2, not "branch absent, push away".
    test("an unlistable remote is exit 2, not read as absent", () => assert.equal(publish(`${T}/does-not-exist.git`, `${T}/good.json`).rc, 2));
  });

  describe("the allow-list", () => {
    let R: string;
    before(() => {
      R = bare(`${T}/allow.git`);
    });
    // The basename is the name; nothing else on the branch can be written through this program.
    for (const bad of ["other.json", "base-images.json.bak", "Base-Images.json", "architecture-maps.json.bak", "estate.json", "base-images"]) {
      test(`refuses the name ${bad}: exit 2, nothing pushed`, () => {
        const p = write(`${T}/names/${bad}/${bad}`, JSON.stringify({ schema: 1, scope: "public-only", generatedAt: "2026-11-23T07:00:00Z" }));
        const r = run(PUBLISH, [p], withMocks({ ...GIT_ENV, RUNNER_TEMP: runnerTemp, PUBLISH_REMOTE: R, PUBLISH_GH_TOKEN: TOKEN }));
        assert.equal(r.rc, 2, r.err);
        assert.ok(r.err.includes("not a publishable name"), r.err);
        assert.equal(branchSha(R), "");
      });
    }
    test("the control: the same document under the allowed name publishes", () => {
      assert.equal(publish(R, mkdoc(`${T}/allowed.json`, "2026-11-23T07:00:00Z")).rc, 0);
      assert.notEqual(branchSha(R), "");
    });
  });

  // architecture-maps.json is private data: it goes only to a destination GitHub says is private.
  describe("the destination lock (architecture-maps.json)", () => {
    const DEST = "example-owner/destination-fixture";
    const answer = (v: string | null): void => {
      mkdirSync(`${T}/gh/destination-fixture`, { recursive: true });
      rmSync(`${T}/gh/destination-fixture/vis.${TOKEN}`, { force: true });
      if (v !== null) write(`${T}/gh/destination-fixture/vis.${TOKEN}`, v);
    };
    const mkmaps = (name: string, generatedAt: string, scope = "estate"): string =>
      write(`${T}/maps/${name}/architecture-maps.json`, JSON.stringify({ schema: 1, scope, generatedAt, summary: { repos: 0 }, repos: [] }, null, 2) + "\n");
    const publishMaps = (remote: string, doc: string, env: Env = {}): Result =>
      run(PUBLISH, [doc], withMocks({ ...GIT_ENV, RUNNER_TEMP: runnerTemp, PUBLISH_REMOTE: remote, PUBLISH_GH_TOKEN: TOKEN, GITHUB_REPOSITORY: DEST, MOCK_GH_DIR: `${T}/gh`, ...env }));
    let R: string;
    before(() => {
      R = bare(`${T}/lock.git`);
    });

    // The control: only `true` publishes, so the cases below can tell a refusal from a bug.
    test("a destination that is private:true publishes, one commit holding architecture-maps.json", () => {
      answer("true");
      const doc = mkmaps("ok", "2026-11-23T07:00:00Z");
      const r = publishMaps(R, doc);
      assert.equal(r.rc, 0, r.err);
      assert.equal(git(R, "ls-tree", "-r", "--name-only", "estate-results"), "architecture-maps.json");
      assert.equal(git(R, "show", "estate-results:architecture-maps.json") + "\n", readFileSync(doc, "utf8"));
      assert.equal(git(R, "log", "-1", "--format=%s", "estate-results"), "architecture-maps: 2026-11-23T07:00:00Z");
    });

    const refused: [string, string | null, Env][] = [
      ["private:false", "false", {}],
      ["a 404", "404", {}],
      ["a 5xx", "503", {}],
      ["odd output", "odd", {}],
      ["a destination the token cannot see at all", null, {}],
      ["a missing GITHUB_REPOSITORY", "true", { GITHUB_REPOSITORY: undefined }],
      ["a blank GITHUB_REPOSITORY", "true", { GITHUB_REPOSITORY: "" }],
    ];
    for (const [name, vis, env] of refused) {
      test(`refuses ${name}: exit 2, before the remote is touched, nothing pushed`, () => {
        answer(vis);
        const R6 = bare(`${T}/lock-${name.replace(/\W+/g, "-")}.git`);
        const log = `${T}/lock-argv-${name.replace(/\W+/g, "-")}.log`;
        const r = publishMaps(R6, mkmaps("x", "2026-11-23T07:00:00Z"), { SHIM_LOG: log, ...env });
        assert.equal(r.rc, 2, r.err);
        assert.ok(r.err.includes("not confirmed private"), r.err);
        assert.equal(branchSha(R6), "");
        assert.ok(!existsSync(log), "git ran before the lock refused");
      });
    }

    test("refuses an architecture-maps.json that is not scope estate (public-only, unfiltered): exit 2", () => {
      answer("true");
      const R7 = bare(`${T}/lock-scope.git`);
      assert.equal(publishMaps(R7, mkmaps("pub", "2026-11-23T07:00:00Z", "public-only")).rc, 2);
      assert.equal(publishMaps(R7, mkmaps("unf", "2026-11-23T07:00:00Z", "unfiltered")).rc, 2);
      assert.equal(branchSha(R7), "");
    });

    test("base-images.json still publishes to a destination that is public (its own policy needs no lookup)", () => {
      answer("false");
      const R8 = bare(`${T}/lock-public.git`);
      const log = `${T}/lock-gh.log`;
      const r = publishMaps(R8, mkdoc(`${T}/pubdoc.json`, "2026-11-23T07:00:00Z"), { MOCK_GH_LOG: log });
      assert.equal(r.rc, 0, r.err);
      assert.ok(!existsSync(log), "a destination lookup was made for base-images.json");
    });

    test("the token is in no gh or git argv and not in the output", () => {
      answer("true");
      const R9 = bare(`${T}/lock-argv.git`);
      const glog = `${T}/sentinel-gh.log`;
      const log = `${T}/sentinel-git.log`;
      const r = publishMaps(R9, mkmaps("s", "2026-11-23T07:00:00Z"), { MOCK_GH_LOG: glog, SHIM_LOG: log });
      assert.equal(r.rc, 0, r.err);
      const b64 = Buffer.from(`x-access-token:${TOKEN}`).toString("base64");
      for (const f of [glog, log]) {
        const argv = readFileSync(f, "utf8");
        assert.ok(argv.length > 0);
        for (const secret of [TOKEN, b64]) assert.ok(!argv.includes(secret), `${secret.slice(0, 12)}… reached an argv in ${f}`);
      }
      assert.ok(!(r.out + r.err).includes(TOKEN) && !(r.out + r.err).includes(b64));
    });
  });

  describe("first publish, commit shape, ordering", () => {
    let R: string;
    before(() => {
      R = bare(`${T}/remote.git`);
      mkdoc(`${T}/good.json`, "2026-11-23T07:00:00Z");
    });

    // These run in order and share the remote.
    test("publishes when the branch is absent; one orphan commit holding only base-images.json; the token is in no argv", () => {
      const log = `${T}/argv.log`;
      const r = publish(R, `${T}/good.json`, { SHIM_LOG: log });
      assert.equal(r.rc, 0, r.err);
      const sha = branchSha(R);
      assert.notEqual(sha, "");
      assert.equal(git(R, "rev-list", "--count", sha), "1");
      assert.equal(git(R, "log", "-1", "--format=%P", "estate-results"), "");
      assert.equal(git(R, "ls-tree", "-r", "--name-only", "estate-results"), "base-images.json");
      assert.equal(git(R, "show", "estate-results:base-images.json") + "\n", readFileSync(nm(`${T}/good.json`), "utf8"), "the branch file is the document, byte for byte");
      const argv = readFileSync(log, "utf8");
      assert.ok(argv.length > 0, "no argv was recorded");
      const b64 = Buffer.from(`x-access-token:${TOKEN}`).toString("base64");
      for (const secret of [TOKEN, b64, "x-access-token"]) assert.ok(!argv.includes(secret), `${secret.slice(0, 12)}… reached a git argv`);
      assert.ok(!(r.out + r.err).includes(TOKEN), "the token is in the output");
      assert.equal(git(R, "log", "-1", "--format=%s", "estate-results"), "base-images: 2026-11-23T07:00:00Z");
    });

    test("a newer document replaces the single orphan commit (no history grows)", () => {
      const r = publish(R, mkdoc(`${T}/newer.json`, "2026-11-30T07:00:00Z"));
      assert.equal(r.rc, 0, r.err);
      assert.equal(git(R, "rev-list", "--count", "estate-results"), "1");
      assert.equal(JSON.parse(git(R, "show", "estate-results:base-images.json")).generatedAt, "2026-11-30T07:00:00Z");
    });

    test("an equal generatedAt is republished, not skipped as stale", () => {
      const r = publish(R, `${T}/newer.json`);
      assert.equal(r.rc, 0, r.err);
      assert.ok(r.out.includes("published 2026-11-30T07:00:00Z"), r.out);
      assert.ok(!r.out.includes("stale"));
    });

    test("refuses to overwrite a newer branch document: stale, exit 0, branch untouched", () => {
      const before = branchSha(R);
      const r = publish(R, mkdoc(`${T}/older.json`, "2026-11-16T07:00:00Z"));
      assert.equal(r.rc, 0, r.err);
      assert.equal(branchSha(R), before);
      assert.ok(r.out.includes("stale, not published"));
    });

    test("a branch whose document cannot be read is replaced, not trusted", () => {
      const W = `${T}/junk`;
      spawnSync("git", ["init", "-q", W], { env: { ...process.env, ...GIT_ENV } });
      write(`${W}/base-images.json`, "not json");
      git(W, "add", "base-images.json");
      spawnSync("git", ["-C", W, "commit", "-q", "-m", "junk"], { env: { ...process.env, ...GIT_ENV } });
      const R3 = bare(`${T}/junk.git`);
      git(W, "push", "-q", R3, "HEAD:refs/heads/estate-results");
      const r = publish(R3, `${T}/good.json`);
      assert.equal(r.rc, 0, r.err);
      assert.equal(JSON.parse(git(R3, "show", "estate-results:base-images.json")).schema, 1);
    });
  });

  describe("the lease", () => {
    // The lease expects absence on a first publish: a branch that appears between the listing
    // and the push wins, and this publish loses cleanly instead of overwriting it.
    test("a racing first publisher wins, this publish loses (exit 1), the winner's commit stays", () => {
      const R2 = bare(`${T}/race.git`);
      const W = `${T}/winner`;
      spawnSync("git", ["init", "-q", W], { env: { ...process.env, ...GIT_ENV } });
      mkdoc(`${W}/base-images.json`, "2026-11-22T07:00:00Z");
      git(W, "add", "base-images.json");
      spawnSync("git", ["-C", W, "commit", "-q", "-m", "winner"], { env: { ...process.env, ...GIT_ENV } });
      const winner = git(W, "rev-parse", "HEAD");
      mkdoc(`${T}/good.json`, "2026-11-23T07:00:00Z");
      const r = publish(R2, `${T}/good.json`, { SHIM_RACE_FROM: W, SHIM_RACE_TO: R2 });
      assert.equal(r.rc, 1, r.err);
      assert.equal(branchSha(R2), winner);
    });

    // The same for an existing branch: the lease expects the sha that was fetched, so a
    // publisher that moves the branch after the fetch makes this one lose.
    test("a branch that moves after the fetch wins, this publish loses (exit 1)", () => {
      const R4 = bare(`${T}/race2.git`);
      assert.equal(publish(R4, mkdoc(`${T}/seed.json`, "2026-11-20T07:00:00Z")).rc, 0);
      const W = `${T}/winner2`;
      spawnSync("git", ["init", "-q", W], { env: { ...process.env, ...GIT_ENV } });
      mkdoc(`${W}/base-images.json`, "2026-11-22T07:00:00Z");
      git(W, "add", "base-images.json");
      spawnSync("git", ["-C", W, "commit", "-q", "-m", "winner"], { env: { ...process.env, ...GIT_ENV } });
      const winner = git(W, "rev-parse", "HEAD");
      // The shim pushes `winner` just before this publish's push; the push below force-pushes
      // with a lease on the sha it fetched, which is no longer the branch tip.
      const r = publish(R4, mkdoc(`${T}/later.json`, "2026-11-23T07:00:00Z"), { SHIM_RACE_FROM: W, SHIM_RACE_TO: R4, SHIM_RACE_FORCE: "1" });
      assert.equal(r.rc, 1, r.err);
      assert.equal(branchSha(R4), winner);
    });

    test("the push is a force-with-lease, never a bare force, on every publish", () => {
      const R5 = bare(`${T}/lease.git`);
      const log = `${T}/lease.log`;
      assert.equal(publish(R5, mkdoc(`${T}/l1.json`, "2026-11-20T07:00:00Z"), { SHIM_LOG: log }).rc, 0);
      assert.equal(publish(R5, mkdoc(`${T}/l2.json`, "2026-11-21T07:00:00Z"), { SHIM_LOG: log }).rc, 0);
      const lines = readFileSync(log, "utf8").split("\n");
      const pushes = lines.map((l, i) => (l === "push" ? lines.slice(i, i + 8) : null)).filter((x): x is string[] => x !== null);
      assert.equal(pushes.length, 2);
      assert.ok(pushes[0]?.includes("--force-with-lease=refs/heads/estate-results:"), "first publish must expect absence");
      assert.ok(pushes[1]?.some((a) => /^--force-with-lease=refs\/heads\/estate-results:[0-9a-f]{40}$/.test(a)), "a later publish must expect the fetched sha");
      for (const p of pushes) assert.ok(!p.includes("--force") && !p.includes("-f"), "a bare force");
    });
  });

  test("the mock git shim is inert without its variables", () => {
    assert.ok(existsSync(`${MOCK}/git`));
    writeFileSync(`${T}/probe`, "");
    assert.equal(spawnSync("git", ["--version"], { env: { ...process.env, PATH: `${MOCK}:${process.env["PATH"]}` } }).status, 0);
  });
});
