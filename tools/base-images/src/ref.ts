import type { Policy } from "./policy.ts";

// Image repository -> endoflife.date product. Keyed on the repo as written in FROM with
// the docker.io/library/ prefix normalised away. A repo missing here is a FINDING, not a
// skip: the whole point is that nothing in a Dockerfile goes unexamined. Fix UNMAPPED by
// extending this table, never by an exemption.
//
// `gcr.io/distroless/*` is handled in productFor(): its images carry the Debian release
// in the name (`static-debian12`) and follow that cycle.
export const PRODUCT_MAP: Readonly<Record<string, string>> = {
  alpine: "alpine-linux",
  node: "nodejs",
  golang: "go",
  nginx: "nginx",
  debian: "debian",
  ubuntu: "ubuntu",
  "oven/bun": "bun",
  postgres: "postgresql",
  redis: "redis",
  python: "python",
};

// Repos with no first-party image in the compose file, which therefore cannot be
// discovered from it: the two the wiki names in EXTRA_REPOS (wiki/generate/sources/
// repos.ts — this repo, and signet, a host binary with no Dockerfile today), plus
// cta-watch, which is first-party but not deployed on this stack. sextant is NOT here:
// its checkout has no remote, so only `--dir ~/projects` can reach it.
export const EXTRA_REPOS: readonly string[] = ["construct-server", "signet", "cta-watch"];

// Images whose ghcr.io name is not the repo that builds them.
export const IMAGE_REPO_OVERRIDES: Readonly<Record<string, string>> = {
  "estate-asr": "chronicle",
};

export interface SplitRef {
  repo: string;
  tag: string;
  digest: string;
}

// Normalise a FROM reference into repo, tag and digest.
export function splitRef(input: string): SplitRef {
  let ref = input;
  let digest = "";
  let tag = "";
  if (ref.includes("@sha256:")) {
    digest = ref.slice(ref.lastIndexOf("@") + 1);
    ref = ref.slice(0, ref.indexOf("@"));
  }
  // A ':' after the last '/' is the tag; one before it is a registry port.
  const last = ref.slice(ref.lastIndexOf("/") + 1);
  let repo: string;
  if (last.includes(":")) {
    tag = last.slice(last.lastIndexOf(":") + 1);
    repo = ref.slice(0, ref.lastIndexOf(":"));
  } else {
    repo = ref;
  }
  if (repo.startsWith("docker.io/")) repo = repo.slice("docker.io/".length);
  if (repo.startsWith("library/")) repo = repo.slice("library/".length);
  return { repo, tag, digest };
}

// endoflife.date product for a repo and, for distroless, the cycle implied by the name.
// An empty product means unmapped.
export function productFor(repo: string): { product: string; forced: string } {
  const m = /^gcr\.io\/distroless\/.*-debian([0-9]+)$/.exec(repo);
  if (m) return { product: "debian", forced: m[1] ?? "" };
  return { product: Object.hasOwn(PRODUCT_MAP, repo) ? (PRODUCT_MAP[repo] ?? "") : "", forced: "" };
}

// How many dotted components a cycle name carries for this product (alpine "3.23" -> 2,
// nodejs "24" -> 1). Read from the data, not assumed.
export function cyclePrecision(policy: Policy): number {
  return (policy.releases[0]?.name ?? "").split(".").length;
}

const asciiLower = (s: string): string => s.replace(/[A-Z]/g, (c) => c.toLowerCase());

export type TagCycle = { kind: "cycle"; cycle: string } | { kind: "floating" } | { kind: "unknown" };

// Resolve a tag to a cycle of the product: FLOATING when it names fewer version components
// than the product's cycles, UNKNOWN when the version is not a cycle endoflife.date lists.
export function tagCycle(policy: Policy, tag: string): TagCycle {
  const prec = cyclePrecision(policy);
  if (tag === "") return { kind: "floating" };

  const v = /^v?([0-9]+(\.[0-9]+)*)/.exec(tag);
  if (!v) {
    // A codename (`trixie`, `noble`, `bookworm-slim`): first word, matched
    // case-insensitively against the release's codename.
    const word = asciiLower(tag.split("-")[0] ?? "");
    const hit = policy.releases.find((r) => {
      const codename = asciiLower(r.codename ?? "");
      return codename !== "" && (codename.split(" ")[0] ?? "") === word;
    });
    return hit ? { kind: "cycle", cycle: hit.name } : { kind: "floating" };
  }

  const parts = (v[1] ?? "").split(".");
  if (parts.length < prec) return { kind: "floating" };
  const cycle = parts.slice(0, prec).join(".");
  return policy.releases.some((r) => r.name === cycle) ? { kind: "cycle", cycle } : { kind: "unknown" };
}
