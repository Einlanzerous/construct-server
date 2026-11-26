import assert from "node:assert/strict";
import { mkdirSync, readFileSync } from "node:fs";
import { after, before, describe, test } from "node:test";
import { destinationSlug, destinationState, isPrivateDestination } from "../src/destination.ts";
import { cleanup, MOCK, tempDir, write } from "./helpers.ts";

// The lock's whole job is to tell `true` from everything else, so every other answer has its
// own case, and a control proves the test can see the difference.
const TOKEN = "sentinel-token-0123456789abcdef";
const SLUG = "example-owner/destination-fixture";

describe("destination", () => {
  let T: string;
  let log: string;
  const answer = (v: string | null): void => {
    mkdirSync(`${T}/gh/destination-fixture`, { recursive: true });
    if (v === null) return;
    write(`${T}/gh/destination-fixture/vis.${TOKEN}`, v);
  };
  const env = (extra: Record<string, string | undefined> = {}): NodeJS.ProcessEnv => {
    const e: NodeJS.ProcessEnv = { PATH: `${MOCK}:${process.env["PATH"]}`, MOCK_GH_DIR: `${T}/gh`, MOCK_GH_LOG: log, GITHUB_REPOSITORY: SLUG };
    for (const [k, v] of Object.entries(extra)) {
      if (v === undefined) delete e[k];
      else e[k] = v;
    }
    return e;
  };

  before(() => {
    T = tempDir("bi-destination");
    log = `${T}/gh.log`;
  });
  after(() => cleanup(T));

  test("true is private and passes the lock (the control)", () => {
    answer("true");
    assert.equal(destinationState(TOKEN, env()), "private");
    assert.equal(isPrivateDestination(TOKEN, env()), true);
  });

  test("false is public and fails the lock", () => {
    answer("false");
    assert.equal(destinationState(TOKEN, env()), "public");
    assert.equal(isPrivateDestination(TOKEN, env()), false);
  });

  // A 404 is what GitHub says to a token that cannot see the repo: here that is "could not
  // tell", never "private" (the repoVisibility reading).
  for (const [name, v] of [["a 404", "404"], ["a 5xx", "503"], ["output that is neither true nor false", "odd"]] as const) {
    test(`${name} is unknown and fails the lock`, () => {
      answer(v);
      assert.equal(destinationState(TOKEN, env()), "unknown");
      assert.equal(isPrivateDestination(TOKEN, env()), false);
    });
  }

  test("a repo the mock has no answer for (404 to this token) is unknown", () => {
    answer(null);
    assert.equal(destinationState(TOKEN, env()), "unknown");
  });

  test("a missing, blank or malformed GITHUB_REPOSITORY is unknown and makes no call", () => {
    answer("true");
    write(log, "");
    for (const v of [undefined, "", "no-slash", "a/b/c", "a b/c", "--flag/x"]) {
      assert.equal(destinationState(TOKEN, env({ GITHUB_REPOSITORY: v })), "unknown", String(v));
    }
    assert.equal(readFileSync(log, "utf8"), "", "a gh call was made without a usable slug");
  });

  test("a blank token is unknown and makes no call", () => {
    answer("true");
    write(log, "");
    assert.equal(destinationState("", env()), "unknown");
    assert.equal(readFileSync(log, "utf8"), "");
  });

  test("gh missing from PATH is unknown, not a throw", () => {
    answer("true");
    assert.equal(destinationState(TOKEN, env({ PATH: "/nonexistent" })), "unknown");
  });

  test("the token is in no gh argv", () => {
    answer("true");
    write(log, "");
    destinationState(TOKEN, env());
    const argv = readFileSync(log, "utf8");
    assert.ok(argv.includes(`repos/${SLUG}`), argv);
    assert.ok(!argv.includes(TOKEN), "the token reached a gh argument");
  });

  test("destinationSlug accepts an owner/name slug and nothing else", () => {
    assert.equal(destinationSlug({ GITHUB_REPOSITORY: "Some-Owner/some.repo_1" }), "Some-Owner/some.repo_1");
    assert.equal(destinationSlug({}), null);
    assert.equal(destinationSlug({ GITHUB_REPOSITORY: "https://github.com/a/b" }), null);
  });
});
