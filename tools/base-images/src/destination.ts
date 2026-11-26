// destination.ts — is the repository a publish is about to write to private? (SERV-356)
//
// One definition of the destination lock, imported by the publisher and by the
// architecture-map sweep's self-check. It is NOT `repoVisibility` in estate.ts: that function
// is asked with a token that cannot see private repos, so it reads a 404 as "private". Here
// the token CAN see the destination, a 404 is "could not tell", and only an exact `true`
// from GitHub passes.
//
//   private   `gh api repos/<slug> --jq .private` succeeded and printed exactly `true`
//   public    it succeeded and printed exactly `false`
//   unknown   anything else: no slug, a 404, a 5xx, a rate limit, gh missing, odd output
//
// Callers choose what unknown means. A lock refuses on public AND unknown; a carry-over lookup
// treats public as a definite answer and unknown as "could not learn" (a different exit).
// The token reaches gh through its environment only, never an argument.
import { gh } from "./gh.ts";

export type DestinationState = "private" | "public" | "unknown";

const SLUG = /^[A-Za-z0-9][A-Za-z0-9._-]*\/[A-Za-z0-9._-]+$/;

/** `GITHUB_REPOSITORY` when it is an owner/name slug, else null (never guessed or repaired). */
export function destinationSlug(env: NodeJS.ProcessEnv = process.env): string | null {
  const v = env["GITHUB_REPOSITORY"] ?? "";
  return SLUG.test(v) ? v : null;
}

export function destinationState(token: string, env: NodeJS.ProcessEnv = process.env): DestinationState {
  const slug = destinationSlug(env);
  if (slug === null || token === "") return "unknown";
  // Only what gh needs: its own token variable and the caller's PATH and home.
  const ghEnv: NodeJS.ProcessEnv = { ...env, GH_TOKEN: token };
  delete ghEnv["PUBLISH_GH_TOKEN"];
  const r = gh(["api", `repos/${slug}`, "--jq", ".private"], ghEnv);
  if (!r.ok) return "unknown";
  const out = r.stdout.trim();
  if (out === "true") return "private";
  if (out === "false") return "public";
  return "unknown";
}

/** The lock: true only when the destination is confirmed private. */
export const isPrivateDestination = (token: string, env: NodeJS.ProcessEnv = process.env): boolean =>
  destinationState(token, env) === "private";
