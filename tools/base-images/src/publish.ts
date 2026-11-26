#!/usr/bin/env node
// publish.ts — publish the public-only base-images document to the `estate-results` branch
// (SERV-294).
//
//   publish.ts <base-images.json>
//
// The branch is a world-readable data branch holding exactly one file, base-images.json, in
// exactly one orphan commit that is force-pushed on every publish: it is the current reading,
// not a history. Satlink reads it through the contents API (docs/base-images.md).
//
// It REFUSES (exit 2, nothing pushed) a document that does not parse, whose schema is not 1,
// whose scope is not "public-only", or that has no parseable generatedAt. The scope check is
// the second lock on the privacy filter in check.ts: an unfiltered document can never reach
// the branch by a workflow mistake.
//
// It publishes nothing, and exits 0 with a notice, when the branch already holds a document
// with a NEWER generatedAt: queued runs can finish out of order, and the older sweep must not
// overwrite the newer one. (Equal is republished.)
//
// First publish: `ls-remote --exit-code` exits 2 for an absent branch, and the push carries
// --force-with-lease=refs/heads/estate-results: (expect absence), so a racing first publisher
// makes this one lose cleanly (exit 1) instead of overwriting it. Otherwise the lease expects
// the sha that was fetched. Any other ls-remote failure is exit 2 and is not read as absent.
//
// The push credential is only ever in the ENVIRONMENT of the git commands that talk to the
// remote (an http extraheader), never an argv element and never a URL.
//
// ENV
//   PUBLISH_GH_TOKEN   required; the token git authenticates with (the workflow's GITHUB_TOKEN)
//   RUNNER_TEMP        required; the clone lives under it
//   PUBLISH_REMOTE     default https://github.com/Einlanzerous/construct-server.git
//                      (the test points it at a local bare repo)
//
// EXIT  0 published, or skipped as stale   1 the push failed or lost a race
//       2 refused: bad input, missing token, or the remote could not be listed
import { spawnSync } from "node:child_process";
import { copyFileSync, mkdtempSync, readFileSync, rmSync, statSync } from "node:fs";
import { join } from "node:path";
import { die, Refusal } from "./errors.ts";
import { onPath, stderr, stdout } from "./io.ts";

const BRANCH = "estate-results";
const REF = `refs/heads/${BRANCH}`;

// jq's fromdateiso8601 took exactly this shape; anything looser is not a timestamp this
// pipeline wrote.
function isoSeconds(s: string): number | null {
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(s)) return null;
  const t = Date.parse(s);
  if (Number.isNaN(t) || new Date(t).toISOString().slice(0, 19) + "Z" !== s) return null;
  return t / 1000;
}

interface Doc {
  schema?: unknown;
  scope?: unknown;
  generatedAt?: unknown;
}

function git(args: string[], env: NodeJS.ProcessEnv, quiet = false): { status: number; stdout: string } {
  const r = spawnSync("git", args, { env, encoding: "utf8", stdio: ["ignore", "pipe", quiet ? "ignore" : "inherit"] });
  return { status: r.status ?? 128, stdout: r.stdout ?? "" };
}

function main(argv: string[]): number {
  if (argv.length !== 1) die("usage: publish.ts <base-images.json>");
  const docPath = argv[0] as string;
  const token = process.env["PUBLISH_GH_TOKEN"] ?? "";
  const runnerTemp = process.env["RUNNER_TEMP"] ?? "";
  if (token === "") die("PUBLISH_GH_TOKEN is not set");
  if (runnerTemp === "") die("RUNNER_TEMP is not set");
  const remote = process.env["PUBLISH_REMOTE"] || "https://github.com/Einlanzerous/construct-server.git";
  if (!onPath("git")) die("required dependency 'git' not found in PATH");

  try {
    if (!statSync(docPath).isFile()) throw new Error("not a file");
  } catch {
    die(`no such file: ${docPath}`);
  }
  let doc: Doc;
  try {
    doc = JSON.parse(readFileSync(docPath, "utf8")) as Doc;
  } catch {
    die(`${docPath} is not parseable JSON`);
  }
  if (typeof doc !== "object" || doc === null || Array.isArray(doc)) die(`${docPath} is not a JSON object`);
  if (doc.schema !== 1) die(`${docPath} has schema ${JSON.stringify(doc.schema)}, not 1: refusing`);
  if (doc.scope !== "public-only") {
    die(`${docPath} has scope ${JSON.stringify(doc.scope)}, not "public-only": refusing to publish an unfiltered document`);
  }
  const generated = typeof doc.generatedAt === "string" ? doc.generatedAt : "";
  const generatedSec = isoSeconds(generated);
  if (generatedSec === null || generatedSec <= 0) die(`${docPath} has no parseable generatedAt`);

  const work = mkdtempSync(join(runnerTemp, "publish-base-images."));
  try {
    // git's header value is base64 of "x-access-token:<token>", computed in this process, so
    // the token is in no argv. GitHub masks the raw secret but not its base64.
    const b64 = Buffer.from(`x-access-token:${token}`).toString("base64");
    if (process.env["GITHUB_ACTIONS"] === "true") stdout(`::add-mask::${b64}\n`);
    // The token's own variable stays out of git's environment; only the header is in it.
    const base: NodeJS.ProcessEnv = { ...process.env };
    delete base["PUBLISH_GH_TOKEN"];
    const authEnv: NodeJS.ProcessEnv = {
      ...base,
      GIT_CONFIG_COUNT: "1",
      GIT_CONFIG_KEY_0: "http.https://github.com/.extraheader",
      GIT_CONFIG_VALUE_0: `AUTHORIZATION: basic ${b64}`,
    };
    // An explicit identity: the runner has none, and a stray global one must not leak in.
    const identity = ["-c", "user.name=base-images", "-c", "user.email=base-images@users.noreply.github.com", "-c", "commit.gpgsign=false"];

    const repo = join(work, "repo");
    if (git(["init", "-q", repo], base).status !== 0) die("could not create the working repository");
    if (git(["-C", repo, "remote", "add", "origin", remote], base).status !== 0) die("could not add the remote");

    const ls = git(["-C", repo, "ls-remote", "--exit-code", "origin", REF], authEnv, true).status;
    if (ls !== 0 && ls !== 2) die(`could not list ${REF} on the remote (git exit ${ls}): not treating that as absent`);
    const present = ls === 0;

    let lease: string;
    if (present) {
      if (git(["-C", repo, "fetch", "-q", "--depth=1", "origin", REF], authEnv).status !== 0) die(`could not fetch ${REF}`);
      const prevSha = git(["-C", repo, "rev-parse", "FETCH_HEAD"], base).stdout.trim();
      let prevGen = "";
      const shown = git(["-C", repo, "show", "FETCH_HEAD:base-images.json"], base, true);
      if (shown.status === 0) {
        try {
          const g = (JSON.parse(shown.stdout) as Doc).generatedAt;
          if (typeof g === "string") prevGen = g;
        } catch {
          // an unreadable previous document is not a newer one
        }
      }
      const prevSec = prevGen === "" ? null : isoSeconds(prevGen);
      if (prevSec !== null && prevSec > generatedSec) {
        stdout(`stale, not published: the branch holds generatedAt ${prevGen}, newer than this document's ${generated}\n`);
        return 0;
      }
      lease = `--force-with-lease=${REF}:${prevSha}`;
    } else {
      lease = `--force-with-lease=${REF}:`;
    }

    // One orphan commit holding only the document (ruling position 7).
    if (git(["-C", repo, "checkout", "-q", "--orphan", "publish"], base).status !== 0) die("could not start the orphan commit");
    copyFileSync(docPath, join(repo, "base-images.json"));
    if (git(["-C", repo, "add", "base-images.json"], base).status !== 0) die("could not stage the document");
    if (git([...identity, "-C", repo, "commit", "-q", "-m", `base-images: ${generated}`], base).status !== 0) die("could not commit the document");

    const push = git(["-C", repo, "push", "-q", lease, "origin", `HEAD:${REF}`], authEnv).status;
    if (push !== 0) {
      stderr(`ERROR: push to ${BRANCH} failed (git exit ${push}); another publisher may have won, re-run to retry\n`);
      return 1;
    }
    stdout(`published ${generated} to ${BRANCH}\n`);
    return 0;
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
}

try {
  process.exit(main(process.argv.slice(2)));
} catch (e) {
  stderr(`ERROR: ${e instanceof Refusal ? e.message : `internal error: ${e instanceof Error ? (e.stack ?? e.message) : String(e)}`}\n`);
  process.exit(2);
}
