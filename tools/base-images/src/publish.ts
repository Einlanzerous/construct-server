#!/usr/bin/env node
// publish.ts — publish one estate result document to the `estate-results` branch (SERV-294,
// generalised by SERV-356).
//
//   publish.ts <base-images.json | architecture-maps.json>
//
// The file's basename is its name, and the name must be on the allow-list below; each name has
// its own policy (the `scope` its document must carry). The branch is a data branch holding the
// current reading in exactly one orphan commit that is force-pushed on every publish, not a
// history. Satlink reads it through the contents API (docs/base-images.md).
//
// It REFUSES (exit 2, nothing pushed) a name that is not on the list, a document that does not
// parse, whose schema is not 1, whose scope is not the one its name requires, or that has no
// parseable generatedAt. architecture-maps.json (scope "estate") is private data and is also
// refused unless the destination repo, GITHUB_REPOSITORY, is confirmed private by
// destination.ts: false, a 404, a 5xx or odd output all refuse. For base-images.json the scope check is the second lock on the privacy
// filter in check.ts: an unfiltered document can never reach the branch by a workflow mistake.
//
// CARRY-OVER. The commit holds the other allow-listed files that the fetched tip already holds,
// byte for byte, so base-images.json and architecture-maps.json (two workflows, one branch) do
// not erase each other. A carried file that is no longer a valid document (parse, schema 1,
// generatedAt) is dropped with a notice. A private-only file (architecture-maps.json) needs the
// destination lookup first, and only then: a branch holding none means no lookup at all.
//   lookup says private   carried unchanged
//   lookup says public    dropped with a notice: a private-only file must not stay on a public branch
//   lookup cannot answer  the whole publish is refused, exit 1, nothing pushed (a failure to
//                         learn, and a rerun retries; dropping would erase good data on a 5xx)
//
// It publishes nothing, and exits 0 with a notice, when the branch already holds a document
// of the SAME NAME (the check is per file) with a NEWER generatedAt: queued runs can finish out
// of order, and the older sweep must not overwrite the newer one. (Equal is republished.)
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
//   PUBLISH_GH_TOKEN   required; the token git authenticates with (the workflow's GITHUB_TOKEN);
//                      the destination lookup uses it too, through gh's environment
//   RUNNER_TEMP        required; the clone lives under it
//   PUBLISH_REMOTE     default https://github.com/Einlanzerous/construct-server.git
//                      (the test points it at a local bare repo)
//
// EXIT  0 published, or skipped as stale   1 the push failed or lost a race, or a carry-over
//       lookup could not answer   2 refused: bad input, missing token, the destination lock, or
//       the remote could not be listed
import { spawnSync } from "node:child_process";
import { copyFileSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { basename, join } from "node:path";
import { type DestinationState, destinationState } from "./destination.ts";
import { die, Refusal } from "./errors.ts";
import { onPath, stderr, stdout } from "./io.ts";

const BRANCH = "estate-results";
const REF = `refs/heads/${BRANCH}`;

// The allow-list: the file's BASENAME is its name, and an unknown name is refused, so the
// publisher cannot be pointed at an arbitrary path on the branch. Each name carries its own
// policy; adding a producer is adding a row here.
interface NamePolicy {
  /** The one `scope` the document must carry. */
  scope: string;
  /**
   * The document is private data: it is published only after the destination (the repo this
   * workflow runs in) is confirmed `private: true`. A public, unreadable or unknown
   * destination is a refusal, never a push.
   */
  privateOnly: boolean;
}
const POLICY: Record<string, NamePolicy> = {
  "base-images.json": { scope: "public-only", privateOnly: false },
  "architecture-maps.json": { scope: "estate", privateOnly: true },
};

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

// `buf` is the raw stdout: a carried file is copied byte for byte, never through a string.
function git(args: string[], env: NodeJS.ProcessEnv, quiet = false): { status: number; stdout: string; buf: Buffer } {
  const r = spawnSync("git", args, { env, stdio: ["ignore", "pipe", quiet ? "ignore" : "inherit"], maxBuffer: 256 * 1024 * 1024 });
  const buf = r.stdout ?? Buffer.alloc(0);
  return { status: r.status ?? 128, stdout: buf.toString("utf8"), buf };
}

// A file on the branch is worth carrying only if it is still a document this pipeline wrote.
function carriable(text: string): boolean {
  try {
    const d = JSON.parse(text) as Doc;
    return typeof d === "object" && d !== null && !Array.isArray(d) && d.schema === 1 && typeof d.generatedAt === "string" && isoSeconds(d.generatedAt) !== null;
  } catch {
    return false;
  }
}

function main(argv: string[]): number {
  if (argv.length !== 1) die("usage: publish.ts <base-images.json | architecture-maps.json>");
  const docPath = argv[0] as string;
  const name = basename(docPath);
  const policy = Object.hasOwn(POLICY, name) ? POLICY[name] : undefined;
  if (policy === undefined) die(`${name} is not a publishable name (allowed: ${Object.keys(POLICY).join(", ")})`);
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
  if (doc.scope !== policy.scope) {
    die(`${docPath} has scope ${JSON.stringify(doc.scope)}, not ${JSON.stringify(policy.scope)}: refusing to publish it`);
  }
  const generated = typeof doc.generatedAt === "string" ? doc.generatedAt : "";
  const generatedSec = isoSeconds(generated);
  if (generatedSec === null || generatedSec <= 0) die(`${docPath} has no parseable generatedAt`);

  // The destination lock. The scope check cannot protect a document that is unfiltered by
  // design, so what protects it is where it goes: only a destination GitHub says is private.
  // It runs before anything touches the remote.
  if (policy.privateOnly) {
    const dest = destinationState(token);
    if (dest !== "private") {
      die(`${name} is private data and the destination repo (GITHUB_REPOSITORY) is not confirmed private (${dest}): refusing to publish`);
    }
  }

  const work = mkdtempSync(join(runnerTemp, "publish."));
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
    const identity = ["-c", "user.name=estate-results", "-c", "user.email=estate-results@users.noreply.github.com", "-c", "commit.gpgsign=false"];

    const repo = join(work, "repo");
    if (git(["init", "-q", repo], base).status !== 0) die("could not create the working repository");
    if (git(["-C", repo, "remote", "add", "origin", remote], base).status !== 0) die("could not add the remote");

    const ls = git(["-C", repo, "ls-remote", "--exit-code", "origin", REF], authEnv, true).status;
    if (ls !== 0 && ls !== 2) die(`could not list ${REF} on the remote (git exit ${ls}): not treating that as absent`);
    const present = ls === 0;

    // The other allow-listed files already on the branch, to be committed unchanged beside this
    // one, so one producer's publish does not erase another's.
    const carried: { name: string; buf: Buffer }[] = [];
    let lease: string;
    if (present) {
      if (git(["-C", repo, "fetch", "-q", "--depth=1", "origin", REF], authEnv).status !== 0) die(`could not fetch ${REF}`);
      const prevSha = git(["-C", repo, "rev-parse", "FETCH_HEAD"], base).stdout.trim();
      let prevGen = "";
      const shown = git(["-C", repo, "show", `FETCH_HEAD:${name}`], base, true);
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

      // Carry-over. A destination lookup happens here only when the tip holds a valid
      // private-only file that would be carried: a branch with none (a first publish, the
      // public branch) makes no lookup and cannot fail on one.
      let dest: DestinationState | undefined;
      for (const other of Object.keys(POLICY)) {
        if (other === name) continue;
        const held = git(["-C", repo, "show", `FETCH_HEAD:${other}`], base, true);
        if (held.status !== 0) continue;
        if (!carriable(held.stdout)) {
          stdout(`notice: ${other} on the branch is not a valid document (parse, schema 1, generatedAt); not carried\n`);
          continue;
        }
        if (POLICY[other]?.privateOnly) {
          dest ??= destinationState(token);
          if (dest === "unknown") {
            // Dropping it would erase a good file on a transient failure; carrying it would
            // risk a public branch. So neither: nothing is pushed and a rerun tries again.
            stderr(`ERROR: ${other} is on the branch and the destination repo (GITHUB_REPOSITORY) could not be confirmed private or public; nothing pushed, re-run to retry\n`);
            return 1;
          }
          if (dest === "public") {
            stdout(`notice: the destination is public, so ${other} is dropped from the branch rather than carried\n`);
            continue;
          }
        }
        carried.push({ name: other, buf: held.buf });
      }
    } else {
      lease = `--force-with-lease=${REF}:`;
    }

    // One orphan commit holding only the document (ruling position 7).
    if (git(["-C", repo, "checkout", "-q", "--orphan", "publish"], base).status !== 0) die("could not start the orphan commit");
    copyFileSync(docPath, join(repo, name));
    for (const c of carried) writeFileSync(join(repo, c.name), c.buf);
    if (git(["-C", repo, "add", name, ...carried.map((c) => c.name)], base).status !== 0) die("could not stage the document");
    if (git([...identity, "-C", repo, "commit", "-q", "-m", `${name.replace(/\.json$/, "")}: ${generated}`], base).status !== 0) die("could not commit the document");

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
