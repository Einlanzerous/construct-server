// Read the tracked first-party image pins (SERV-96).
//
// `versions.env` is the one env-shaped file in this repo that is deliberately in
// git, because an image tag is not a credential. It is therefore the only such
// file this generator is allowed to read — the deployed `.env` next to it carries
// real secrets and is off limits (see the header of sources/compose.ts).

import { readFileSync } from "node:fs";

export type PinStyle = "major.minor" | "sha" | "other";

export interface VersionPin {
  /** The variable name, e.g. `LYCEUM_TAG`. */
  variable: string;
  /** The source repo it pins, e.g. `lyceum`. */
  repo: string;
  value: string;
  style: PinStyle;
}

export function parseVersions(path: string): VersionPin[] {
  const out: VersionPin[] = [];
  for (const line of readFileSync(path, "utf8").split("\n")) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;

    const eq = trimmed.indexOf("=");
    if (eq === -1) continue;

    const variable = trimmed.slice(0, eq).trim();
    // Strip surrounding quotes the way compose does, so a quoted empty string is
    // seen here as the empty value it actually is rather than as two characters.
    const value = trimmed.slice(eq + 1).trim().replace(/^(["'])(.*)\1$/, "$2");

    out.push({ variable, repo: repoFromVariable(variable), value, style: classify(value) });
  }
  return out;
}

/**
 * `SWITCHYARD_TAG` -> `switchyard`. One variable per source repo, by convention.
 * The dev pin file uses the same convention behind a `DEV_` prefix (SERV-97), which
 * names the same repo — strip it, or `DEV_SWITCHYARD_TAG` claims a repo that does
 * not exist.
 */
function repoFromVariable(variable: string): string {
  return variable.replace(/^DEV_/, "").replace(/_TAG$/, "").toLowerCase();
}

function classify(value: string): PinStyle {
  if (/^\d+\.\d+$/.test(value)) return "major.minor";
  // argosy publishes `sha-<short>`; drydock publishes the bare 40-char commit sha.
  // Both forms are real and neither should be normalised into the other.
  if (/^(sha-)?[0-9a-f]{7,40}$/.test(value)) return "sha";
  return "other";
}

/**
 * What a pin actually means for what lands on the next `docker compose pull`.
 * Stated per style because the difference is the entire point of the convention:
 * one of these keeps floating deliberately, and the other does not float at all.
 */
export function pinBehaviour(style: PinStyle): string {
  switch (style) {
    case "major.minor":
      return "Patch releases under this minor still arrive on a pull — the one float kept deliberately, so a security fix lands without an edit here.";
    case "sha":
      return "Immutable. A pull is a no-op; the version only changes when this file changes.";
    default:
      return "Unrecognised form — neither a major.minor pin nor a commit sha. Worth a look.";
  }
}
