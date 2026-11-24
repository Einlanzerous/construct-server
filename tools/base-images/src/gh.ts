import { spawnSync } from "node:child_process";

export interface GhResult {
  ok: boolean;
  stdout: string;
  stderr: string;
}

// One `gh api` call. The token reaches gh through its environment only, never an argument.
export function gh(args: string[], env: NodeJS.ProcessEnv = process.env): GhResult {
  const r = spawnSync("gh", args, {
    env,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    maxBuffer: 256 * 1024 * 1024,
  });
  return { ok: r.status === 0 && !r.error, stdout: r.stdout ?? "", stderr: r.stderr ?? (r.error?.message ?? "") };
}

// `$(...)` drops trailing newlines; the callers compared against values that had lost them.
export const chomp = (s: string): string => s.replace(/\n+$/, "");
