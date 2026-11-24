import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { checkDockerfile, type Clock } from "./judge.ts";
import { die } from "./errors.ts";
import type { PolicyStore } from "./policy.ts";
import type { Run } from "./run.ts";

// File and --dir modes know no repo, so they cannot tell a private path from a public one.
// Under redaction that is "privacy unknown", which is withheld, so they do not run at all.
export function redactRefuse(redact: boolean): void {
  if (redact) {
    die(
      "file and --dir modes print local paths and cannot tell whether they are private; refusing under redaction (CI, GITHUB_STEP_SUMMARY or --redact). Run it locally.",
    );
  }
}

const isFile = (p: string): boolean => {
  try {
    return statSync(p).isFile();
  } catch {
    return false;
  }
};

export async function checkFiles(run: Run, policies: PolicyStore, clock: Clock, redact: boolean, files: string[]): Promise<void> {
  redactRefuse(redact);
  if (files.length === 0) die("no Dockerfiles given");
  for (const f of files) {
    if (!isFile(f)) die(`no such file: ${f}`);
    run.curPath = f;
    await checkDockerfile(run, policies, clock, f, readFileSync(f, "utf8"));
  }
  run.flushRepo(true);
}

const BUILD_FILE = (name: string): boolean => name.startsWith("Dockerfile") || name.endsWith(".Dockerfile") || name.startsWith("Containerfile");
const PRUNED = new Set(["node_modules", "vendor", ".git"]);

// `find <root> -type d (-name node_modules ...) -prune -o -type f ...`: symlinks are not
// followed, and a pruned directory takes nothing beneath it.
function findBuildFiles(dir: string, shown: string, out: string[]): void {
  const base = shown.endsWith("/") ? shown : `${shown}/`;
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    if (e.isDirectory()) {
      if (!PRUNED.has(e.name)) findBuildFiles(`${dir}/${e.name}`, `${base}${e.name}`, out);
    } else if (e.isFile() && BUILD_FILE(e.name)) {
      out.push(`${base}${e.name}`);
    }
  }
}

export async function checkDir(run: Run, policies: PolicyStore, clock: Clock, redact: boolean, root: string): Promise<void> {
  redactRefuse(redact);
  if (!existsSync(root) || !statSync(root).isDirectory()) die(`no such directory: ${root}`);
  const files: string[] = [];
  const rootName = root.replace(/\/+$/, "").split("/").pop() ?? "";
  if (!PRUNED.has(rootName)) findBuildFiles(root, root, files);
  files.sort();
  if (files.length === 0) die(`no Dockerfile* under ${root} — that is not a clean result`);
  await checkFiles(run, policies, clock, redact, files);
}
