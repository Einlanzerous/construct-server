#!/usr/bin/env node
// check.ts — the base-image check (SERV-170). `--help` is the manual; rules and the
// document's shape are in docs/base-images.md.
import { spawnSync } from "node:child_process";
import { existsSync, readdirSync, rmSync, statSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parseDay } from "./dates.ts";
import { buildDocument, serialize, writeDocumentFile, type Mode } from "./document.ts";
import { checkEstate, requireGh } from "./estate.ts";
import { die, Refusal } from "./errors.ts";
import { checkDir, checkFiles } from "./inputs.ts";
import { Console, stderr, stdout } from "./io.ts";
import { PolicyStore } from "./policy.ts";
import { Run } from "./run.ts";
import { USAGE } from "./usage.ts";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(HERE, "../../..");

interface Cli {
  json: boolean;
  jsonOut: string;
  publicOnly: boolean;
  redact: boolean;
  rest: string[];
}

function parseArgs(argv: string[]): Cli {
  const cli: Cli = { json: false, jsonOut: "", publicOnly: false, redact: false, rest: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i] as string;
    if (a === "--json") cli.json = true;
    else if (a === "--json-out") {
      const next = argv[i + 1];
      if (next === undefined || next === "") die("--json-out needs a file");
      cli.jsonOut = next;
      i++;
    } else if (a === "--public-only") cli.publicOnly = true;
    else if (a === "--redact") cli.redact = true;
    else cli.rest.push(a);
  }
  return cli;
}

// A blank number is the default, a malformed one is a refusal: the window decides whether
// an end-of-life is a warning, so a typo must not quietly widen or close it.
function warnDaysFromEnv(raw: string | undefined): number {
  const v = raw || "90";
  if (!/^\d+$/.test(v)) die(`BASE_IMAGE_WARN_DAYS must be a whole number of days, got '${v}'`);
  return Number(v);
}

// The self-test is the test suite: the same cases that prove the port against the bash it
// replaced, run as black boxes against this program.
function selfTest(): number {
  const dir = resolve(HERE, "../test");
  if (!existsSync(dir)) die(`no test directory at ${dir}`);
  const files = readdirSync(dir)
    .filter((f) => f.endsWith(".test.ts"))
    .sort()
    .map((f) => resolve(dir, f));
  if (files.length === 0) die(`no *.test.ts under ${dir}`);
  const r = spawnSync(process.execPath, ["--test", "--test-reporter=spec", ...files], { stdio: "inherit" });
  if (r.status !== 0) {
    stderr("self-test: case(s) failed\n");
    return 1;
  }
  stdout("self-test: passed\n");
  return 0;
}

async function main(argv: string[]): Promise<number> {
  const env = process.env;
  const cli = parseArgs(argv);
  const con = new Console(cli.json);

  // A stale document must never survive a run that does not produce one.
  if (cli.jsonOut !== "") {
    rmSync(cli.jsonOut, { force: true });
    const parent = dirname(cli.jsonOut);
    if (!existsSync(parent) || !statSync(parent).isDirectory()) die(`no such directory for --json-out: ${parent}`);
  }

  // Redaction is on whenever this looks like a hosted run, whatever it is called: the
  // variables are tested for being set to anything at all (CI=false still redacts), so an
  // environment that is not recognised errs towards withholding. --self-test is the one
  // mode that never reads a repo, and its children clear these on purpose.
  let redact = cli.redact;
  if ((env["GITHUB_ACTIONS"] ?? "") + (env["CI"] ?? "") + (env["GITHUB_STEP_SUMMARY"] ?? "") !== "") redact = true;
  const first = cli.rest[0] ?? "";
  // A document is output too: --json prints it to stdout (the run log) and --json-out writes
  // a file a workflow may upload, so under redaction an estate document is always the
  // public-only one. Otherwise `--estate --json` in CI would name every private repo in the log.
  let publicOnly = cli.publicOnly;
  if (redact && first === "--estate") publicOnly = true;
  if (publicOnly && first !== "--estate") die("--public-only applies to --estate only");
  const privacyToken = env["PRIVACY_GH_TOKEN"] ?? "";
  if (first === "--estate" && (publicOnly || redact) && privacyToken === "") {
    die("--public-only and redaction need PRIVACY_GH_TOKEN (a token that cannot read private repos); there is no fallback to GH_TOKEN");
  }

  if (first === "--self-test") return selfTest();
  if (first === "-h" || first === "--help" || first === "") {
    con.human(USAGE);
    return 2;
  }

  const policies = PolicyStore.fromEnv(env);
  const today = env["BASE_IMAGE_TODAY"] || new Date().toISOString().slice(0, 10);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(today)) die(`BASE_IMAGE_TODAY must be YYYY-MM-DD, got '${today}'`);
  parseDay(today, "BASE_IMAGE_TODAY");
  const clock = { today, warnDays: warnDaysFromEnv(env["BASE_IMAGE_WARN_DAYS"]) };
  const run = new Run(con, env["GITHUB_ACTIONS"] === "true");

  let mode: Mode = "files";
  if (first === "--estate") {
    mode = "estate";
    const compose = cli.rest[1] || resolve(REPO_ROOT, "docker-compose.yml");
    if (!existsSync(compose) || !statSync(compose).isFile()) die(`no compose file at ${compose}`);
    requireGh();
    await checkEstate(run, con, policies, clock, { compose, publicOnly, redact, privacyToken });
  } else if (first === "--dir") {
    mode = "dir";
    const root = cli.rest[1] ?? "";
    if (root === "") die("--dir needs a path");
    await checkDir(run, policies, clock, redact, root);
  } else {
    await checkFiles(run, policies, clock, redact, cli.rest);
  }

  if (cli.jsonOut !== "" || cli.json) {
    const text = serialize(
      buildDocument(run, { mode, publicOnly, today, warnDays: clock.warnDays, policySource: policies.source, now: new Date() }),
    );
    if (cli.jsonOut !== "") writeDocumentFile(cli.jsonOut, text);
    if (cli.json) stdout(text);
  }

  con.human("\n");
  if (redact) {
    con.human(
      `${run.redRepos} repo(s) withheld (private or privacy unknown): ${run.redFind} finding(s), ${run.redWarn} warning(s) — run make base-images-check locally for the detail\n`,
    );
  }
  con.human(`base images: ${run.errors} finding(s), ${run.warnings} warning(s), ${run.oks} ok (policy: ${policies.source}, today: ${today})\n`);

  const summary = env["GITHUB_STEP_SUMMARY"] ?? "";
  if (summary !== "") {
    let md = "## Base images\n\n";
    if (publicOnly) {
      md += `Withheld from the published file: ${run.withheld} repo(s) not public, ${run.visUnread} repo(s) with unreadable visibility.\n\n`;
    }
    if (redact) {
      md += `${run.redRepos} repo(s) withheld (private or privacy unknown): ${run.redFind} finding(s), ${run.redWarn} warning(s). Their detail is not printed here because this log is public; run \`make base-images-check\` locally.\n\n`;
    }
    md += "| status | where | image | detail |\n|---|---|---|---|\n";
    for (const r of run.table) md += `| ${r.status} | \`${r.where}\` | \`${r.image}\` | ${r.detail} |\n`;
    run.appendStepSummary(summary, md);
  }

  return run.errors === 0 ? 0 : 1;
}

// Every way out that is not "findings" is exit 2, an internal error included: a crash must
// never read as exit 1, and an exit-2 run never leaves a document behind.
function fail(e: unknown): never {
  const message = e instanceof Refusal ? e.message : `internal error: ${e instanceof Error ? (e.stack ?? e.message) : String(e)}`;
  stderr(`ERROR: ${message}\n`);
  const out = parseArgsSafely(process.argv.slice(2));
  if (out !== "") {
    try {
      rmSync(out, { force: true });
    } catch {
      // nothing more to do
    }
  }
  process.exit(2);
}

function parseArgsSafely(argv: string[]): string {
  const i = argv.indexOf("--json-out");
  return i !== -1 ? (argv[i + 1] ?? "") : "";
}

main(process.argv.slice(2)).then(
  (code) => process.exit(code),
  (e: unknown) => fail(e),
);
