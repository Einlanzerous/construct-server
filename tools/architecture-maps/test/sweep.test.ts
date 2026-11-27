import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { after, describe, test } from "node:test";
import { estateRepos, GITHUB_OWNER } from "../../base-images/src/estate.ts";
import { HERE, ROOT, TOOL, baseEnv, git, makeRepo, scenarios, tempRoot, type FixtureSpec } from "./helpers.ts";

// The sweep runs as a black box: a child process with an environment built here, a mock git that
// stands in for github.com (test/mock-bin/git) and the base-images mock gh. Every repo name is
// synthetic except the three the estate list adds itself (EXTRA_REPOS), which come from
// estateRepos and are never written here.
const SWEEP = join(TOOL, "src/sweep.ts");
const MOCK_GIT = join(HERE, "mock-bin");
const MOCK_GH = join(ROOT, "tools/base-images/test/mock-bin/gh");

const WORKFLOW_TOKEN = "sentinel-workflow-token-0123456789";
const READ_TOKEN = "sentinel-read-token-abcdef0123456789";
const DEST = "example-owner/drogue-fixture";
const READ_B64 = Buffer.from(`x-access-token:${READ_TOKEN}`).toString("base64");
const WORKFLOW_B64 = Buffer.from(`x-access-token:${WORKFLOW_TOKEN}`).toString("base64");

const root = tempRoot();
after(() => { if (!process.env["KEEP"]) rmSync(root, { recursive: true, force: true }); });

// The directory the sweep's PATH gets for gh: the one mock, not the base-images directory, whose
// git shim would shadow this package's.
const ghBin = join(root, "gh-bin");
mkdirSync(ghBin);
symlinkSync(MOCK_GH, join(ghBin, "gh"));

const REAL_GIT = (process.env["PATH"] ?? "").split(":").map((d) => join(d, "git")).find((p) => existsSync(p)) ?? "git";

interface Out {
  rc: number;
  out: string;
  err: string;
}

interface World {
  dir: string;
  runnerTemp: string;
  output: string;
  doc: string;
  gitLog: string;
  ghLog: string;
  repos: string[];
  run(env?: Record<string, string | undefined>, timeoutMs?: number): Out;
  document(): { schema: number; scope: string; generatedAt: string; summary: Record<string, number>; repos: Row[] };
  published(): boolean;
}
interface Row {
  repo: string;
  state: string;
  references: number | null;
  errors: number | null;
  driftedFiles: number | null;
}

let n = 0;

// `images` are the first-party services in the fixture compose file; a value of null is a repo with
// no remote at all (the clone fails), a spec is the repository served for it. Every repo the
// estate list adds beyond those is served as a repo with no map.
function world(images: Record<string, FixtureSpec | null>, opts: { lock?: string | null; lockToken?: string } = {}): World {
  const dir = join(root, `w${n++}`);
  const home = join(dir, "home");
  const remotes = join(dir, "remotes");
  const runnerTemp = join(dir, "runner");
  mkdirSync(remotes, { recursive: true });
  mkdirSync(runnerTemp);
  mkdirSync(home);
  const compose = join(dir, "docker-compose.yml");
  writeFileSync(compose, `services:\n${Object.keys(images).map((i) => `  ${i}:\n    image: ghcr.io/einlanzerous/${i}:1.0.0\n`).join("")}`);
  const repos = estateRepos(compose);
  for (const repo of repos) {
    const spec = repo in images ? images[repo] : {};
    if (spec === null || spec === undefined) continue;
    const d = makeRepo(remotes, repo, spec, home);
    git(d, ["config", "uploadpack.allowAnySHA1InWant", "true"], baseEnv(home));
  }
  const gh = join(dir, "gh");
  mkdirSync(join(gh, "drogue-fixture"), { recursive: true });
  const lock = opts.lock === undefined ? "true" : opts.lock;
  if (lock !== null) writeFileSync(join(gh, "drogue-fixture", `vis.${opts.lockToken ?? WORKFLOW_TOKEN}`), lock);

  const w: World = {
    dir,
    runnerTemp,
    output: join(dir, "github-output"),
    doc: join(runnerTemp, "out/architecture-maps.json"),
    gitLog: join(dir, "git.log"),
    ghLog: join(dir, "gh.log"),
    repos,
    run(env = {}, timeoutMs = 60_000) {
      writeFileSync(w.output, "");
      // The sweep gives git an allow-listed environment, so the shim's settings are baked into a
      // per-run wrapper rather than passed down.
      const settings = Object.entries({ MOCK_GIT_REAL: REAL_GIT, MOCK_GIT_REMOTES: remotes, SHIM_LOG: w.gitLog, MOCK_GIT_FETCH_AUTH: env["MOCK_GIT_FETCH_AUTH"], MOCK_GIT_HANG_FETCH: env["MOCK_GIT_HANG_FETCH"] })
        .filter(([, v]) => v !== undefined)
        .map(([k, v]) => `export ${k}='${v}'\n`)
        .join("");
      mkdirSync(join(dir, "bin"), { recursive: true });
      writeFileSync(join(dir, "bin/git"), `#!/usr/bin/env bash\n${settings}exec '${join(MOCK_GIT, "git")}' "$@"\n`, { mode: 0o755 });
      const e: NodeJS.ProcessEnv = {
        PATH: `${join(dir, "bin")}:${MOCK_GIT}:${ghBin}:${process.env["PATH"]}`,
        HOME: home,
        MOCK_GH_DIR: gh,
        MOCK_GH_LOG: w.ghLog,
        GITHUB_REPOSITORY: DEST,
        GITHUB_TOKEN: WORKFLOW_TOKEN,
        ESTATE_READ_TOKEN: READ_TOKEN,
        RUNNER_TEMP: runnerTemp,
        GITHUB_OUTPUT: w.output,
        ARCH_MAPS_COMPOSE: compose,
      };
      for (const [k, v] of Object.entries(env)) {
        if (k.startsWith("MOCK_GIT_")) continue;
        if (v === undefined) delete e[k];
        else e[k] = v;
      }
      const r = spawnSync(process.execPath, [SWEEP], { env: e, encoding: "utf8", timeout: timeoutMs });
      return { rc: r.status ?? -1, out: r.stdout, err: r.stderr };
    },
    document: () => JSON.parse(readFileSync(w.doc, "utf8")),
    published: () => /^published=true$/m.test(readFileSync(w.output, "utf8")),
  };
  return w;
}

const read = (p: string): string => (existsSync(p) ? readFileSync(p, "utf8") : "");
const slugOf = (repo: string): string => `${GITHUB_OWNER}/${repo}`;
const state = (w: World, repo: string): string | undefined => w.document().repos.find((r) => r.repo === repo)?.state;

describe("the destination lock (C3)", () => {
  // Each answer but a clean `true` refuses before a clone, and leaves no document and no output.
  for (const [name, answer] of [
    ["private:false", "false"],
    ["a 404", "404"],
    ["a 5xx", "503"],
    ["output that is neither true nor false", "odd"],
    ["no answer for this token at all", null],
  ] as const) {
    test(`${name}: exit 2 before any clone, no document, no published`, () => {
      const w = world({ svc: {} }, { lock: answer });
      mkdirSync(join(w.runnerTemp, "out"), { recursive: true });
      writeFileSync(w.doc, "stale\n");
      const r = w.run();
      assert.equal(r.rc, 2, r.err);
      assert.equal(read(w.gitLog), "", "git was run before the lock answered");
      assert.ok(!existsSync(w.doc), "an exit 2 left a document");
      assert.equal(read(w.output), "");
      assert.ok(!w.repos.some((x) => r.out.includes(x)), "a repo was swept");
    });
  }

  test("private:true passes (the control: the test can see the difference)", () => {
    const w = world({ svc: {} });
    const r = w.run();
    assert.equal(r.rc, 0, r.out + r.err);
    assert.ok(read(w.gitLog).includes("clone"));
    assert.ok(w.published());
  });

  test("the lock is asked with the workflow's token, not the read token", () => {
    // Only the read token can see the destination here, which is what repoVisibility's reading
    // of "visible" would accept. The sweep must still refuse.
    const w = world({ svc: {} }, { lockToken: READ_TOKEN });
    assert.equal(w.run().rc, 2);
    assert.equal(read(w.gitLog), "");
  });

  test("GITHUB_REPOSITORY missing, or GITHUB_TOKEN missing: exit 2, no clone", () => {
    for (const env of [{ GITHUB_REPOSITORY: undefined }, { GITHUB_TOKEN: undefined }, { GITHUB_TOKEN: "" }]) {
      const w = world({ svc: {} });
      assert.equal(w.run(env).rc, 2);
      assert.equal(read(w.gitLog), "");
      assert.ok(!existsSync(w.doc));
    }
  });
});

describe("states and the exit policy (C4, C9)", () => {
  const sc = (name: string, key: string): FixtureSpec => scenarios(slugOf(name))[key]!;

  test("every state a repo can be in is read, and the document is exactly what the rows say", () => {
    const w = world({
      "s-nomap": sc("s-nomap", "no_map"),
      "s-sync": sc("s-sync", "in_sync"),
      "s-stale": sc("s-stale", "stale"),
      "s-path": sc("s-path", "broken_path_absent"),
      "s-four": sc("s-four", "broken_four_sources"),
      "s-url": sc("s-url", "broken_wrong_url"),
      "s-pin": sc("s-pin", "skipped_pin_absent"),
      "s-gone": null,
    });
    const r = w.run();
    assert.equal(r.rc, 1, r.err);
    const want: Record<string, string> = {
      "s-nomap": "no_map",
      "s-sync": "in_sync",
      "s-stale": "stale",
      "s-path": "broken",
      "s-four": "broken",
      "s-url": "broken",
      "s-pin": "skipped",
      "s-gone": "unreadable",
    };
    for (const [repo, s] of Object.entries(want)) assert.equal(state(w, repo), s, repo);
    const d = w.document();
    assert.equal(d.schema, 1);
    assert.equal(d.scope, "estate");
    assert.match(d.generatedAt, /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/);
    assert.deepEqual(d.repos.map((x) => x.repo), w.repos);
    // The summary is computed from the rows, and an unreadable row measured nothing.
    assert.deepEqual(d.summary, {
      repos: w.repos.length,
      noMap: 1 + (w.repos.length - 8),
      inSync: 1,
      stale: 1,
      broken: 3,
      skipped: 1,
      unreadable: 1,
    });
    assert.deepEqual(d.repos.find((x) => x.repo === "s-gone"), { repo: "s-gone", state: "unreadable", references: null, errors: null, driftedFiles: null });
    // A broken map has no drift count (not measured), a stale one has.
    assert.equal(d.repos.find((x) => x.repo === "s-path")?.driftedFiles, null);
    assert.equal(d.repos.find((x) => x.repo === "s-stale")?.driftedFiles, 1);
    assert.equal(d.repos.find((x) => x.repo === "s-sync")?.driftedFiles, 0);
  });

  test("a repo whose clone fails is unreadable, never no_map", () => {
    const w = world({ "s-gone": null });
    assert.equal(w.run().rc, 1);
    assert.equal(state(w, "s-gone"), "unreadable");
  });

  test("a clone that never answers is killed by its deadline and reads unreadable", () => {
    const w = world({ "s-hang": {} });
    writeFileSync(join(w.dir, "remotes/s-hang.hang"), "");
    const t0 = Date.now();
    const r = w.run({ ARCH_MAPS_CLONE_TIMEOUT_MS: "700" });
    assert.equal(r.rc, 1, r.err);
    assert.equal(state(w, "s-hang"), "unreadable");
    assert.ok(Date.now() - t0 < 20_000);
  });

  test("a check that never finishes is killed, and no result file reads unreadable", () => {
    // A depth-1 clone does not hold the pin, so the script fetches it, and that fetch hangs.
    const w = world({ "s-sync": sc("s-sync", "in_sync") });
    const r = w.run({ MOCK_GIT_HANG_FETCH: "1", ARCH_MAPS_CHECK_TIMEOUT_MS: "700" });
    assert.equal(r.rc, 1, r.err);
    assert.equal(state(w, "s-sync"), "unreadable");
  });

  test("a pin that needs the authenticated remote: in_sync with the credential, skipped without", () => {
    const withCred = world({ "s-sync": sc("s-sync", "in_sync") });
    assert.equal(withCred.run({ MOCK_GIT_FETCH_AUTH: "1" }).rc, 0);
    assert.equal(state(withCred, "s-sync"), "in_sync");

    const without = world({ "s-sync": sc("s-sync", "in_sync") });
    const r = without.run({ MOCK_GIT_FETCH_AUTH: "1", ESTATE_READ_TOKEN: undefined });
    assert.equal(r.rc, 0, "skipped is data, not a red run");
    assert.equal(state(without, "s-sync"), "skipped");
    assert.match(r.err, /ESTATE_READ_TOKEN is not set/);
  });

  test("a private repo cannot be cloned without the credential: unreadable, never no_map", () => {
    const w = world({ "s-priv": sc("s-priv", "no_map") });
    writeFileSync(join(w.dir, "remotes/s-priv.private"), "");
    w.run({ ESTATE_READ_TOKEN: undefined });
    assert.equal(state(w, "s-priv"), "unreadable");
    const ok = world({ "s-priv": sc("s-priv", "no_map") });
    writeFileSync(join(ok.dir, "remotes/s-priv.private"), "");
    ok.run();
    assert.equal(state(ok, "s-priv"), "no_map");
  });

  test("the child is handed the repo's own slug: a map for another repo is broken", () => {
    const w = world({ "s-other": { map: { url: "https://github.com/example-owner/someone-else", revision: "pin", components: [{ id: "c", sources: [{ path: "a.txt" }] }] } } });
    w.run();
    assert.equal(state(w, "s-other"), "broken");
  });

  // C9: the colour policy. Red when a repo is unreadable or no document was produced; a broken
  // map is data. A red run still publishes its document.
  test("exit 0: a valid document and every repo read, even with broken, stale and skipped maps", () => {
    const w = world({ "s-path": sc("s-path", "broken_path_absent"), "s-stale": sc("s-stale", "stale"), "s-pin": sc("s-pin", "skipped_pin_absent") });
    const r = w.run();
    assert.equal(r.rc, 0, r.out + r.err);
    assert.ok(w.published());
    assert.equal(w.document().summary["unreadable"], 0);
  });

  test("exit 1: one unreadable repo, and the document is still published", () => {
    const w = world({ "s-gone": null });
    assert.equal(w.run().rc, 1);
    assert.ok(w.published());
    assert.ok(existsSync(w.doc));
  });

  test("exit 2: no document and no published, and a stale file from an earlier step is gone", () => {
    const w = world({ svc: {} }, { lock: "false" });
    mkdirSync(join(w.runnerTemp, "out"), { recursive: true });
    writeFileSync(w.doc, "stale\n");
    assert.equal(w.run().rc, 2);
    assert.ok(!existsSync(w.doc));
    assert.equal(read(w.output), "");
  });

  test("a stale file from an earlier step is never read as this run's document", () => {
    const w = world({ svc: {} });
    mkdirSync(join(w.runnerTemp, "out"), { recursive: true });
    writeFileSync(w.doc, "stale\n");
    assert.equal(w.run().rc, 0);
    assert.equal(w.document().scope, "estate");
  });

  test("the working clones are removed once the document exists", () => {
    const w = world({ svc: {} });
    w.run();
    assert.deepEqual(readdirSync(w.runnerTemp).sort(), ["out"]);
    assert.deepEqual(readdirSync(join(w.runnerTemp, "out")), ["architecture-maps.json"]);
  });

  test("missing RUNNER_TEMP or GITHUB_OUTPUT is exit 2, and nothing runs", () => {
    for (const env of [{ RUNNER_TEMP: undefined }, { GITHUB_OUTPUT: undefined }, { RUNNER_TEMP: "" }]) {
      const w = world({ svc: {} });
      assert.equal(w.run(env).rc, 2);
      assert.equal(read(w.gitLog), "");
    }
  });

  test("a deadline that is not a positive number is exit 2", () => {
    for (const v of ["", "0", "-5", "1.5", "soon"]) {
      const w = world({ svc: {} });
      assert.equal(w.run({ ARCH_MAPS_CLONE_TIMEOUT_MS: v }).rc, 2, JSON.stringify(v));
    }
  });
});

describe("the repo list comes from estateRepos of the compose file it is handed (C4)", () => {
  test("a new ghcr.io image adds a repo, and the list is the one estateRepos derives", () => {
    const a = world({ "s-one": {} });
    const b = world({ "s-one": {}, "s-two": {} });
    assert.equal(a.run().rc, 0);
    assert.equal(b.run().rc, 0);
    const names = (w: World): string[] => w.document().repos.map((r) => r.repo);
    assert.deepEqual(names(a), a.repos);
    assert.deepEqual(names(b), b.repos);
    assert.deepEqual(names(b).filter((x) => !names(a).includes(x)), ["s-two"]);
  });

  test("a compose file with no ghcr.io image is exit 2: no clone, no document, no published", () => {
    const w = world({ svc: {} });
    writeFileSync(join(w.dir, "docker-compose.yml"), "services:\n  db:\n    image: postgres:17\n");
    const r = w.run();
    assert.equal(r.rc, 2);
    assert.equal(read(w.gitLog), "");
    assert.ok(!existsSync(w.doc));
    assert.equal(read(w.output), "");
  });

  test("a compose path that is set but empty is exit 2, not the default", () => {
    const w = world({ svc: {} });
    assert.equal(w.run({ ARCH_MAPS_COMPOSE: "" }).rc, 2);
    assert.equal(read(w.gitLog), "");
  });

  test("by default the list is derived from this checkout's docker-compose.yml", () => {
    // Not run against github.com: the lock fails first, so only the path is exercised, via exit 2
    // on a destination that is public. The default path is the repository's own compose file.
    const w = world({ svc: {} }, { lock: "false" });
    assert.equal(w.run({ ARCH_MAPS_COMPOSE: undefined }).rc, 2);
    assert.ok(estateRepos(join(ROOT, "docker-compose.yml")).length > 0);
  });
});

describe("the sweep never forwards what a map says (C2)", () => {
  // A component id is printed by the script inside its own error line, so a map can make the
  // script emit `::error::` text. None of it may reach this run's output.
  const hostile = (name: string): FixtureSpec => ({
    map: {
      url: `https://github.com/${slugOf(name)}`,
      revision: "pin",
      components: [{ id: "::error::forged ::set-output name=x::y", sources: [{ path: "gone.txt" }] }],
    },
  });

  test("no `::` reaches stdout or stderr, and the repo still reads broken", () => {
    const w = world({ "s-evil": hostile("s-evil") });
    const r = w.run({ GITHUB_ACTIONS: undefined });
    assert.equal(r.rc, 0, r.out + r.err);
    assert.equal(state(w, "s-evil"), "broken");
    assert.ok(!(r.out + r.err).includes("::"), `output carried a workflow command:\n${r.out}${r.err}`);
    assert.ok(!(r.out + r.err).includes("forged"));
  });

  test("under GITHUB_ACTIONS=true the only workflow command is the add-mask for the credential", () => {
    const w = world({ "s-evil": hostile("s-evil") });
    const r = w.run({ GITHUB_ACTIONS: "true" });
    assert.equal(r.rc, 0, r.out + r.err);
    const cmds = (r.out + r.err).split("\n").filter((l) => l.includes("::"));
    assert.deepEqual(cmds, [`::add-mask::${READ_B64}`]);
  });

  test("GITHUB_ACTIONS is absent from the environment of git and of the child, whatever the job's", () => {
    const w = world({ "s-sync": scenarios(slugOf("s-sync"))["in_sync"]! });
    assert.equal(w.run({ GITHUB_ACTIONS: "true" }, 60_000).rc, 0);
    const headers = read(w.gitLog).split("\n").filter((l) => l.startsWith("--- git"));
    assert.ok(headers.length > 5, "the log should hold the clones and the script's own git calls");
    for (const h of headers) assert.match(h, /GITHUB_ACTIONS=unset/);
    assert.ok(read(w.gitLog).split("\n").includes("fetch"), "the script's fetch of the pin ran");
  });

  test("a clone's own output is not forwarded either", () => {
    const w = world({ "s-noisy": {} });
    writeFileSync(join(w.dir, "remotes/s-noisy.noisy"), "");
    const r = w.run({ GITHUB_ACTIONS: undefined });
    assert.equal(r.rc, 0, r.out + r.err);
    assert.ok(read(w.gitLog).includes("clone"));
    assert.ok(!(r.out + r.err).includes("::"));
  });
});

describe("the credential reaches git only as an environment extraheader (C5, sweep half)", () => {
  test("the sentinel tokens are in no argv, no log, no document and no file left behind", () => {
    const w = world({ "s-sync": scenarios(slugOf("s-sync"))["in_sync"]!, "s-gone": null });
    const r = w.run({ MOCK_GIT_FETCH_AUTH: "1", GITHUB_ACTIONS: "true" });
    assert.equal(r.rc, 1, r.err);
    const argvAndLogs = [read(w.gitLog), read(w.ghLog), r.err, read(w.doc), read(w.output)];
    for (const [i, text] of argvAndLogs.entries()) {
      for (const s of [WORKFLOW_TOKEN, READ_TOKEN, WORKFLOW_B64]) assert.ok(!text.includes(s), `a credential is in artefact ${i}`);
    }
    // The base64 form is allowed in one place only: the add-mask command that hides it.
    const outWithoutMask = r.out.replace(`::add-mask::${READ_B64}\n`, "");
    for (const s of [WORKFLOW_TOKEN, READ_TOKEN, READ_B64, WORKFLOW_B64]) assert.ok(!outWithoutMask.includes(s));
    for (const s of [READ_B64]) {
      assert.ok(!read(w.gitLog).includes(s) && !read(w.doc).includes(s) && !r.err.includes(s));
    }
    // And the credential did reach git: the fetch authenticated, so it ran with the header.
    assert.match(read(w.gitLog), /credential=yes/);
    assert.equal(state(w, "s-sync"), "in_sync");
  });

  test("the workflow token is never given to git, only to the lock's gh call", () => {
    const w = world({ "s-sync": scenarios(slugOf("s-sync"))["in_sync"]! });
    w.run({ MOCK_GIT_FETCH_AUTH: "1" });
    // The header git was handed carries the read token, never the workflow's: with only the
    // workflow token set, the authenticated fetch is refused and the repo is skipped.
    const only = world({ "s-sync": scenarios(slugOf("s-sync"))["in_sync"]! });
    only.run({ MOCK_GIT_FETCH_AUTH: "1", ESTATE_READ_TOKEN: undefined });
    assert.equal(state(only, "s-sync"), "skipped");
  });

  test("hooks are off for every git call the sweep and the script make", () => {
    const w = world({ "s-sync": scenarios(slugOf("s-sync"))["in_sync"]! });
    w.run();
    const headers = read(w.gitLog).split("\n").filter((l) => l.startsWith("--- git"));
    assert.ok(headers.length > 5);
    for (const h of headers) assert.match(h, /hooks=core\.hooksPath=\/dev\/null$/);
  });
});
