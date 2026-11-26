import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { describe, test } from "node:test";
import { ROOT } from "./helpers.ts";

// Structural assertions on base-images.yml that a behavioural test cannot reach. The workflow
// is read without its comment lines: prose that names `always()` or `contents: write` must
// not satisfy or break an assertion about the code.
const raw = readFileSync(`${ROOT}/.github/workflows/base-images.yml`, "utf8");
const code = raw.split("\n").filter((l) => !/^\s*#/.test(l));
const text = code.join("\n");

// A job's block: from "  <job>:" to the next two-space key.
function job(name: string): string {
  const out: string[] = [];
  let inside = false;
  for (const l of code) {
    if (new RegExp(`^  ${name}:`).test(l)) {
      inside = true;
      out.push(l);
    } else if (inside && /^  [a-z]/.test(l)) {
      inside = false;
    } else if (inside) out.push(l);
  }
  return out.join("\n");
}

function step(name: string): string {
  const out: string[] = [];
  let inside = false;
  for (const l of code) {
    if (l.includes(`- name: ${name}`)) {
      inside = true;
      out.push(l);
    } else if (inside && /^      - /.test(l)) {
      inside = false;
    } else if (inside) out.push(l);
  }
  return out.join("\n");
}

const sweep = job("sweep");
const publish = job("publish");
const GATE = "github.event_name != 'pull_request' && github.ref == 'refs/heads/main'";

describe("base-images.yml structure", () => {
  test("the self-test step runs make base-images-test", () => {
    assert.match(step("Prove the check can fail"), /run: make base-images-test/);
  });

  test("the program runs under the pinned Node the tests need, before the tests", () => {
    assert.match(sweep, /actions\/setup-node@v4/);
    assert.match(sweep, /node-version: 24/);
    assert.ok(sweep.indexOf("setup-node") < sweep.indexOf("make base-images-test"));
    assert.match(publish, /actions\/setup-node@v4/);
  });

  test("the sweep job stays contents: read (top-level block only)", () => {
    assert.match(text, /^permissions:\n {2}contents: read$/m);
    assert.ok(!sweep.includes("permissions:"));
  });

  test("only the publish job has contents: write", () => {
    assert.equal(text.match(/contents: write/g)?.length, 1);
    assert.ok(publish.includes("contents: write"));
  });

  test("the upload step runs on !cancelled(), the published output and the event/ref gate", () => {
    const upload = step("Upload");
    assert.ok(upload.includes("!cancelled()"));
    assert.ok(upload.includes("steps.sweep.outputs.published == 'true'"));
    assert.ok(upload.includes(GATE));
  });

  test("the upload carries one file with retention-days 1", () => {
    const upload = step("Upload");
    assert.ok(upload.includes("retention-days: 1"));
    assert.ok(upload.includes("base-images.json"));
  });

  test("the publish job's if: has !cancelled(), the published output and the gate", () => {
    const cond = publish.split("\n").find((l) => l.startsWith("    if:")) ?? "";
    assert.ok(cond.includes("!cancelled()"));
    assert.ok(cond.includes("needs.sweep.outputs.published == 'true'"));
    assert.ok(cond.includes(GATE));
  });

  test("no always(): a cancelled run publishes nothing", () => assert.ok(!text.includes("always()")));

  test("the publish job's concurrency group is base-images-publish, cancel-in-progress false", () => {
    const i = publish.split("\n").findIndex((l) => l.startsWith("    concurrency:"));
    const block = publish.split("\n").slice(i, i + 4).join("\n");
    assert.ok(block.includes("group: base-images-publish"));
    assert.ok(block.includes("cancel-in-progress: false"));
  });

  test("the publish checkout does not persist credentials", () => assert.ok(publish.includes("persist-credentials: false")));

  test("no event field is interpolated into the workflow", () => assert.ok(!text.includes("${{ github.event.")));

  test("paths: names the program, the Makefile and the tests for pull_request and push", () => {
    for (const p of ["Makefile", "tools/base-images/**"]) {
      assert.ok((text.match(new RegExp(`- '${p.replace(/\*/g, "\\*")}'`, "g")) ?? []).length >= 2, `paths: missing ${p}`);
    }
  });

  test("the workflow runs the TypeScript program, and no deleted script is named", () => {
    assert.ok(text.includes("tools/base-images/src/sweep.ts"));
    assert.ok(text.includes("tools/base-images/src/publish.ts"));
    assert.ok(!/scripts\/(check-base-images|base-images-sweep|publish-base-images)\.sh/.test(raw), "a retired bash script is still named");
  });

  // backup-test.sh puts all of scripts/test/mock-bin on PATH; a gh or jq there would shadow the
  // real one. This tool's shims live beside its tests, and that directory must stay as it was.
  test("scripts/test/mock-bin holds only docker and tailscale", () => {
    assert.deepEqual(readdirSync(`${ROOT}/scripts/test/mock-bin`).sort(), ["docker", "tailscale"]);
  });
});
