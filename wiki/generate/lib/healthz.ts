// The wiki's /healthz body (SERV-343). nginx serves the file this writes on 200 and
// a fixed copy of the same shape from config/wiki/nginx.conf on 503.

import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

/**
 * Not a release: the wiki is a bundle, not an image, so it has no version to claim
 * and must stay out of Switchyard's inventory (PRINCIPLES section 4 exception).
 * Defined here and, necessarily, in the conf's 503 body; checkHealthzConf() fails
 * the build if the two differ.
 */
export const HEALTHZ_VERSION = "static";

const FULL_SHA = /^[0-9a-f]{40}$/;

/**
 * Full commit or null, never a guess. WIKI_BUILD_REF is 7 characters and can be
 * the string "working tree", so only the dedicated full-sha variable is accepted.
 */
export function healthzSha(raw: string | undefined): string | null {
  return raw !== undefined && FULL_SHA.test(raw) ? raw : null;
}

export function writeHealthz(publicDir: string, rawSha: string | undefined): void {
  const body = { status: "ok", version: HEALTHZ_VERSION, sha: healthzSha(rawSha) };
  writeFileSync(join(publicDir, "healthz.json"), JSON.stringify(body) + "\n", "utf8");
}

/** Throws if the conf's fixed 503 body does not carry the generator's version. */
export function checkHealthzConf(confPath: string): void {
  const conf = readFileSync(confPath, "utf8");
  const m = /location @healthz_unavailable\s*\{[^}]*?"version":"([^"]*)"/.exec(conf);
  if (!m) throw new Error(`${confPath}: no healthz 503 body with a version found`);
  if (m[1] !== HEALTHZ_VERSION) {
    throw new Error(
      `healthz version drift: generator says "${HEALTHZ_VERSION}", ${confPath} says "${m[1]}"`,
    );
  }
}
