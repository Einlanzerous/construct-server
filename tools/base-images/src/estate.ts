import { readFileSync } from "node:fs";
import { checkDockerfile, type Clock } from "./judge.ts";
import { chomp, gh } from "./gh.ts";
import { die } from "./errors.ts";
import { onPath, type Console } from "./io.ts";
import type { PolicyStore } from "./policy.ts";
import { EXTRA_REPOS, IMAGE_REPO_OVERRIDES } from "./ref.ts";
import type { RepoRecord, Run } from "./run.ts";

export const GITHUB_OWNER = "Einlanzerous";

// Every Dockerfile in a repo's tree. This is gh's own jq dialect; the filter runs on
// GitHub's side of `gh api --jq`, and the tests' mock gh answers with what it would print.
const TREE_FILTER =
  '.tree[] | select(.type=="blob") | .path | select(test("(^|/)(Dockerfile[^/]*|[^/]+\\\\.Dockerfile|Containerfile[^/]*)$")) | select(test("(^|/)(node_modules|vendor)/") | not)';

// Every first-party repo: the ghcr.io images in the compose file map onto repos the same
// way verify-tag.sh and the wiki derive them, so a new service needs no edit here.
//
// Case-insensitive and quote-tolerant, because a compose file accepts both and a pattern
// that silently stopped matching would shrink the sweep to EXTRA_REPOS with nothing going
// red — the one place this program could narrow to nothing. So the derived list is
// asserted: matching no image at all is exit 2, not an empty result.
export function estateRepos(compose: string): string[] {
  const text = readFileSync(compose, "utf8");
  const derived = [...text.matchAll(/image: *["']?ghcr\.io\/einlanzerous\/([a-z0-9_-]+)/gi)].map((m) => (m[1] ?? "").toLowerCase());
  if (derived.length === 0) {
    die(`no ghcr.io/einlanzerous images found in ${compose} — the repo list would be EXTRA_REPOS alone, refusing`);
  }
  const repos = derived.map((img) => IMAGE_REPO_OVERRIDES[img] ?? img);
  return [...new Set([...repos, ...EXTRA_REPOS])].sort();
}

export type Visibility = "public" | "private" | "unreadable";

// Is this repo world-readable? Asked with the privacy token, one that cannot read private
// repos: GitHub answers 404 for those, and a 200 `private:false` is itself the proof. The
// sweep token is deliberately not used, since it can read private repos and answers 200 for
// them. Fail closed: only a success printing exactly `false` is public. `private` is a 404
// or private:true; `unreadable` is anything else: 5xx, rate limit, network, odd output.
export function repoVisibility(repo: string, privacyToken: string): Visibility {
  const r = gh(["api", `repos/${GITHUB_OWNER}/${repo}`, "--jq", ".private"], { ...process.env, GH_TOKEN: privacyToken });
  if (r.ok) {
    const out = chomp(r.stdout);
    return out === "false" ? "public" : out === "true" ? "private" : "unreadable";
  }
  return r.stderr.includes("HTTP 404") ? "private" : "unreadable";
}

export interface EstateOptions {
  compose: string;
  publicOnly: boolean;
  redact: boolean;
  privacyToken: string;
}

export async function checkEstate(
  run: Run,
  con: Console,
  policies: PolicyStore,
  clock: Clock,
  opts: EstateOptions,
): Promise<void> {
  const { publicOnly, redact } = opts;
  const repos = estateRepos(opts.compose);
  let readFiles = 0;

  for (const repo of repos) {
    // Withheld repos are still swept below, so they still count toward the process exit;
    // --public-only omits them from the document and --redact from the printed output.
    let published = true;
    run.curRedact = false;
    if (publicOnly || redact) {
      const vis = repoVisibility(repo, opts.privacyToken);
      if (vis === "private") {
        if (publicOnly) {
          published = false;
          run.withheld++;
        }
        run.curRedact = redact;
      } else if (vis === "unreadable") {
        if (publicOnly) published = false;
        run.visUnread++;
        run.curRedact = redact;
      }
    }
    const err0 = run.errors;
    const warn0 = run.warnings;
    run.curRepo = repo;
    run.curPath = "";
    let state: RepoRecord["state"];
    const unreadablePaths: string[] = [];
    let okFiles = 0;

    // HEAD on the trees API is the default branch. A repo that cannot be read is a
    // finding: a token that silently skips the private repos would report green on an
    // estate it only half examined.
    const tree = gh(["api", `repos/${GITHUB_OWNER}/${repo}/git/trees/HEAD?recursive=1`, "--jq", TREE_FILTER]);
    if (!tree.ok) {
      const why = chomp(tree.stdout + tree.stderr).replaceAll("\n", " ");
      run.emit("UNRESOLVED", `${repo}:0`, repo, `could not read the repo tree via gh api (${why}) — does the token have access?`);
      state = "unreadable";
    } else {
      const paths = chomp(tree.stdout)
        .split("\n")
        .map((p) => p.trim())
        .filter((p) => p !== "");
      if (paths.length === 0) {
        if (!run.curRedact) con.human(`${"-".padEnd(10)} ${repo.padEnd(50)} no Dockerfile\n`);
        state = "no_dockerfile";
      } else {
        for (const path of paths) {
          run.curPath = path;
          const file = gh(["api", `repos/${GITHUB_OWNER}/${repo}/contents/${path}`, "-H", "Accept: application/vnd.github.raw+json"]);
          if (!file.ok) {
            // gh's own error text may carry the repo or path, so it is held back and only
            // replayed for a repo whose detail is allowed out.
            if (!run.curRedact) con.err(file.stderr);
            run.emit("UNRESOLVED", `${repo}/${path}:0`, path, "could not read the file via gh api");
            unreadablePaths.push(path);
            continue;
          }
          readFiles++;
          okFiles++;
          await checkDockerfile(run, policies, clock, `${repo}/${path}`, chomp(file.stdout));
        }
        state = unreadablePaths.length === 0 ? "read" : okFiles === 0 ? "unreadable" : "partial";
      }
    }
    if (published) {
      run.docRepos.push({ repo, state, unreadablePaths: unreadablePaths.length > 0 ? unreadablePaths : null });
    }
    run.flushRepo(published);
    if (run.curRedact) {
      run.redRepos++;
      run.redFind += run.errors - err0;
      run.redWarn += run.warnings - warn0;
    }
    run.curRedact = false;
  }

  if (readFiles === 0) die("no Dockerfiles found across the estate — that is not a clean result");
  // Counts only, never a name: this reaches the world-readable log.
  if (publicOnly) con.err(`WITHHELD ${run.withheld} repo(s) from the published document (not public)\n`);
  if (run.visUnread > 0) {
    con.err(`${run.visUnread} repo(s) with unreadable visibility, withheld and counted as findings\n`);
    run.errors += run.visUnread;
  }
}

export function requireGh(): void {
  if (!onPath("gh")) die("required dependency 'gh' not found in PATH (needed for --estate)");
}
