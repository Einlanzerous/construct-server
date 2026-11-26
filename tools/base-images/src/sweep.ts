#!/usr/bin/env node
// sweep.ts — run the estate sweep for base-images.yml and say whether a document exists to
// publish (SERV-294).
//
// A workflow step cannot tell exit 1 from exit 2 (`steps.<id>.outcome` is just "failure"),
// and the two mean opposite things here: exit 1 is "the sweep found something", and the week
// with findings is exactly the week the published file must still move; exit 2 is "the sweep
// could not run" and leaves no document. So the exit code is captured and re-raised, and
// `published=true` is written to $GITHUB_OUTPUT only when a document was produced (exit 0 or
// 1 with the file present). The job still fails on findings, so the Monday email still comes.
//
// The sweep is --public-only: the file this writes is already filtered, so the artifact and
// the branch downstream never hold private data. It is also --redact (SERV-350), passed
// explicitly even though GITHUB_ACTIONS implies it: the run log and step summary of a public
// repo's workflow are world-readable, so a private repo is reported as counts only there. The
// flag is the contract; the environment detection is the backstop. See docs/base-images.md.
//
// ENV
//   RUNNER_TEMP        where the document is written ($RUNNER_TEMP/out/base-images.json)
//   GITHUB_OUTPUT      where `published=true` goes
//   GH_TOKEN           the sweep token (reads private repos so they are still swept)
//   PRIVACY_GH_TOKEN   the low-privilege token that decides which repos are public
//   BASE_IMAGES_CHECK  the check program to run (default: check.ts beside this file); the
//                      test points it at a fake
//
// EXIT: the check's own exit code (0, 1 or 2); 2 also for this wrapper's own setup errors.
import { spawnSync } from "node:child_process";
import { appendFileSync, mkdirSync, rmSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { die, Refusal } from "./errors.ts";
import { stderr } from "./io.ts";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(HERE, "../../..");

function main(): number {
  const runnerTemp = process.env["RUNNER_TEMP"] ?? "";
  const githubOutput = process.env["GITHUB_OUTPUT"] ?? "";
  if (runnerTemp === "") die("RUNNER_TEMP is not set (nothing is written to a fixed path)");
  if (githubOutput === "") die("GITHUB_OUTPUT is not set");
  const outDir = join(runnerTemp, "out");
  const out = join(outDir, "base-images.json");
  try {
    mkdirSync(outDir, { recursive: true });
  } catch {
    die(`cannot create ${outDir}`);
  }
  // A leftover from an earlier step must never read as this run's document.
  rmSync(out, { force: true });

  const override = process.env["BASE_IMAGES_CHECK"] ?? "";
  const checkArgs = ["--estate", join(REPO_ROOT, "docker-compose.yml"), "--json-out", out, "--public-only", "--redact"];
  const r =
    override !== ""
      ? spawnSync(override, checkArgs, { stdio: "inherit" })
      : spawnSync(process.execPath, [join(HERE, "check.ts"), ...checkArgs], { stdio: "inherit" });
  if (r.error) die(`could not run the check: ${r.error.message}`);
  // A signal is not a verdict: it is exit 2, so nothing from it is published.
  const rc = r.status ?? 2;

  const size = ((): number => {
    try {
      return statSync(out).size;
    } catch {
      return 0;
    }
  })();
  if (rc <= 1 && size > 0) {
    appendFileSync(githubOutput, "published=true\n");
  } else {
    // Exit 2, or a document nobody should trust: nothing to publish.
    rmSync(out, { force: true });
  }
  return rc;
}

try {
  process.exit(main());
} catch (e) {
  stderr(`ERROR: ${e instanceof Refusal ? e.message : `internal error: ${e instanceof Error ? (e.stack ?? e.message) : String(e)}`}\n`);
  process.exit(2);
}
