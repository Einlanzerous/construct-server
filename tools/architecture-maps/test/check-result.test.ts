import assert from "node:assert/strict";
import { chmodSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { join } from "node:path";
import { after, describe, test } from "node:test";
import {
  DEFAULT_SLUG,
  HERE,
  OTHER_SLUG,
  SCRIPT,
  baseEnv,
  makeRepo,
  runScript,
  scenarios,
  tempRoot,
  type Env,
  type FixtureSpec,
} from "./helpers.ts";

// Runs the REAL scripts/architecture-map-check.sh over fixture git repositories built in a
// temp directory. The environment is built here (helpers.baseEnv), never inherited, so the same
// test passes on a developer machine and in the CI `test` job, which sets GITHUB_ACTIONS.
const root = tempRoot();
const home = join(root, "home");
after(() => rmSync(root, { recursive: true, force: true }));

interface GoldenRun {
  rc: number | null;
  out: string;
  err: string;
}
interface Golden {
  scenarios: Record<string, GoldenRun>;
}
const golden = (form: string): Golden =>
  JSON.parse(readFileSync(join(HERE, "golden", `${form}.json`), "utf8")) as Golden;

let n = 0;
function repo(spec: FixtureSpec): string {
  return makeRepo(root, `r${n++}`, spec, home);
}

describe("defaults: ARCH_MAP_SLUG and ARCH_MAP_RESULT unset", () => {
  // The goldens were captured from the script as it was before SERV-356 (see capturedFrom in
  // each file), so they prove the two additions are off when unset, byte for byte.
  for (const [form, extra] of [
    ["plain", {}],
    ["annotations", { GITHUB_ACTIONS: "true" }],
  ] as const) {
    describe(`golden, ${form}`, () => {
      const g = golden(form);
      for (const [name, spec] of Object.entries(scenarios(DEFAULT_SLUG))) {
        test(name, () => {
          const r = runScript(repo(spec), baseEnv(home, extra));
          const want = g.scenarios[name];
          assert.ok(want, `golden has no scenario ${name}`);
          assert.deepEqual({ rc: r.rc, out: r.out, err: r.err }, want);
        });
      }
    });
  }

  test("the goldens cover every scenario and the two forms differ", () => {
    const names = Object.keys(scenarios(DEFAULT_SLUG)).sort();
    assert.deepEqual(Object.keys(golden("plain").scenarios).sort(), names);
    assert.deepEqual(Object.keys(golden("annotations").scenarios).sort(), names);
    assert.notDeepEqual(golden("plain").scenarios["stale"], golden("annotations").scenarios["stale"]);
  });
});

interface Result {
  state: string;
  references: number | null;
  errors: number | null;
  driftedFiles: number | null;
}

// state, exit code and the figures, for each scenario under another repo's slug.
const WANT: Record<string, { rc: number; result: Result }> = {
  no_map: { rc: 0, result: { state: "no_map", references: null, errors: null, driftedFiles: null } },
  in_sync: { rc: 0, result: { state: "in_sync", references: 1, errors: 0, driftedFiles: 0 } },
  stale: { rc: 0, result: { state: "stale", references: 1, errors: 0, driftedFiles: 1 } },
  broken_path_absent: { rc: 1, result: { state: "broken", references: 1, errors: 1, driftedFiles: null } },
  broken_line_past_eof: { rc: 1, result: { state: "broken", references: 1, errors: 1, driftedFiles: null } },
  broken_four_sources: { rc: 1, result: { state: "broken", references: null, errors: 1, driftedFiles: null } },
  broken_wrong_url: { rc: 1, result: { state: "broken", references: null, errors: 1, driftedFiles: null } },
  broken_not_json: { rc: 1, result: { state: "broken", references: null, errors: 1, driftedFiles: null } },
  skipped_pin_absent: { rc: 0, result: { state: "skipped", references: null, errors: null, driftedFiles: null } },
};

describe("ARCH_MAP_SLUG and ARCH_MAP_RESULT set", () => {
  for (const [name, spec] of Object.entries(scenarios(OTHER_SLUG))) {
    test(`${name}: state and unchanged exit code`, () => {
      const out = join(root, `res-${n}.json`);
      const r = runScript(repo(spec), baseEnv(home, { ARCH_MAP_SLUG: OTHER_SLUG, ARCH_MAP_RESULT: out }));
      const want = WANT[name];
      assert.ok(want, `no expectation for ${name}`);
      assert.equal(r.rc, want.rc, r.out + r.err);
      const text = readFileSync(out, "utf8");
      assert.equal(text.split("\n").length, 2, "exactly one line");
      assert.deepEqual(JSON.parse(text), want.result);
    });
  }

  test("every scenario has an expectation", () => {
    assert.deepEqual(Object.keys(WANT).sort(), Object.keys(scenarios(OTHER_SLUG)).sort());
  });

  test("the result adds nothing to the output: stdout and stderr equal the run without it", () => {
    for (const extra of [{}, { GITHUB_ACTIONS: "true" }] as Env[]) {
      for (const [name, spec] of Object.entries(scenarios(OTHER_SLUG))) {
        const dir = repo(spec);
        const plain = runScript(dir, baseEnv(home, { ...extra, ARCH_MAP_SLUG: OTHER_SLUG }));
        const withResult = runScript(
          dir,
          baseEnv(home, { ...extra, ARCH_MAP_SLUG: OTHER_SLUG, ARCH_MAP_RESULT: join(root, `x-${n++}.json`) }),
        );
        assert.deepEqual(withResult, plain, name);
      }
    }
  });

  test("a mixed-case slug matches, and so does a mixed-case map url", () => {
    const dir = repo({
      map: {
        url: "https://github.com/Example-Org/Widget-Service.git",
        revision: "pin",
        components: [{ id: "svc", sources: [{ path: "a.txt" }] }],
      },
    });
    const out = join(root, "mixed.json");
    const r = runScript(dir, baseEnv(home, { ARCH_MAP_SLUG: "EXAMPLE-org/Widget-SERVICE", ARCH_MAP_RESULT: out }));
    assert.equal(r.rc, 0, r.out + r.err);
    assert.equal((JSON.parse(readFileSync(out, "utf8")) as Result).state, "in_sync");
  });

  test("a slug for another repo does not match this one's map", () => {
    const dir = repo(scenarios(DEFAULT_SLUG)["in_sync"]!);
    const out = join(root, "other.json");
    const r = runScript(dir, baseEnv(home, { ARCH_MAP_SLUG: OTHER_SLUG, ARCH_MAP_RESULT: out }));
    assert.equal(r.rc, 1);
    assert.equal((JSON.parse(readFileSync(out, "utf8")) as Result).state, "broken");
  });

  test("ARCH_MAP_RESULT alone keeps the default slug", () => {
    const out = join(root, "default-slug.json");
    const r = runScript(repo(scenarios(DEFAULT_SLUG)["in_sync"]!), baseEnv(home, { ARCH_MAP_RESULT: out }));
    assert.equal(r.rc, 0);
    assert.equal((JSON.parse(readFileSync(out, "utf8")) as Result).state, "in_sync");
  });

  test("a stale result file from an earlier run is removed, not read", () => {
    const out = join(root, "leftover.json");
    writeFileSync(out, '{"state":"in_sync","references":9,"errors":0,"driftedFiles":0}\n');
    // The fixture has no map, so the run's own answer (no_map) differs from the leftover's.
    const r = runScript(repo({}), baseEnv(home, { ARCH_MAP_RESULT: out }));
    assert.equal(r.rc, 0);
    assert.deepEqual(JSON.parse(readFileSync(out, "utf8")), WANT["no_map"]!.result);
  });
});

describe("set-but-empty is an error, never the default", () => {
  test("ARCH_MAP_SLUG= fails without falling back, even for a map the default slug would pass", () => {
    const dir = repo(scenarios(DEFAULT_SLUG)["in_sync"]!);
    const out = join(root, "empty-slug.json");
    const r = runScript(dir, baseEnv(home, { ARCH_MAP_SLUG: "", ARCH_MAP_RESULT: out }));
    assert.equal(r.rc, 2);
    assert.match(r.err, /ARCH_MAP_SLUG is set but empty/);
    assert.equal(r.out, "");
    assert.ok(!existsSync(out), "no result is written for a refused run");
  });

  test("ARCH_MAP_RESULT= fails and writes nothing", () => {
    const r = runScript(repo(scenarios(DEFAULT_SLUG)["in_sync"]!), baseEnv(home, { ARCH_MAP_RESULT: "" }));
    assert.equal(r.rc, 2);
    assert.match(r.err, /ARCH_MAP_RESULT is set but empty/);
    assert.equal(r.out, "");
  });
});

describe("killed by timeout", () => {
  // A git that hangs on the pin lookup, ahead of the real one on PATH. The script is killed
  // before it chooses an exit, so there is no result file: the reader must call that unreadable.
  const shim = join(root, "shim");
  mkdirSync(shim, { recursive: true });
  writeFileSync(join(shim, "git"), '#!/bin/sh\n[ "$1" = cat-file ] && exec sleep 30\nexec /usr/bin/git "$@"\n');
  chmodSync(join(shim, "git"), 0o755);

  for (const sig of ["TERM", "KILL"]) {
    test(`SIG${sig} leaves no result file, whatever came before`, () => {
      const dir = repo(scenarios(OTHER_SLUG)["in_sync"]!);
      const out = join(root, `timeout-${sig}.json`);
      writeFileSync(out, '{"state":"in_sync","references":1,"errors":0,"driftedFiles":0}\n');
      const env: Env = baseEnv(home, {
        ARCH_MAP_SLUG: OTHER_SLUG,
        ARCH_MAP_RESULT: out,
        PATH: `${shim}:/usr/local/bin:/usr/bin:/bin`,
      });
      // timeout(1) signals its whole process group, so the hung child dies with the script.
      const r = spawnSync("timeout", ["-s", sig, "1", "bash", SCRIPT], {
        cwd: dir,
        env,
        encoding: "utf8",
        timeout: 15000,
      });
      assert.notEqual(r.status, 0, "the script did not finish");
      assert.ok(!existsSync(out), "a killed run writes no result, and removed the earlier one");
    });
  }
});
