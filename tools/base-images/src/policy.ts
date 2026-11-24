import { readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { die } from "./errors.ts";

export interface Release {
  name: string;
  codename?: string | null;
  isEol?: boolean | null;
  eolFrom?: string | null;
  releaseDate?: string | null;
}

export interface Policy {
  releases: Release[];
}

const DEFAULT_API = "https://endoflife.date/api/v1/products";

// What the policy data must look like before anything is judged against it. A document that
// does not fit is a refusal: judging against a half-read table could only ever lean green.
export function parsePolicy(text: string): Policy | null {
  let data: unknown;
  try {
    data = JSON.parse(text);
  } catch {
    return null;
  }
  const releases = (data as { result?: { releases?: unknown } } | null)?.result?.releases;
  if (!Array.isArray(releases) || releases.length === 0) return null;
  for (const r of releases) {
    if (typeof r !== "object" || r === null || typeof (r as { name?: unknown }).name !== "string") return null;
  }
  return { releases: releases as Release[] };
}

// One product's release list, cached per run so a product is asked for once however many
// images use it. Unreachable or unusable policy is exit 2 and never 0: "could not check"
// must not read as "checked and fine".
export class PolicyStore {
  readonly fromApi: boolean;
  readonly source: string;
  private readonly cache = new Map<string, Policy>();

  private readonly dir: string;
  private readonly api: string;

  constructor(dir: string, api: string) {
    this.dir = dir;
    this.api = api;
    this.fromApi = dir === "";
    this.source = this.fromApi ? api : dir;
  }

  static fromEnv(env: NodeJS.ProcessEnv): PolicyStore {
    // blankAsDefault: an empty variable is the default, not a value.
    return new PolicyStore(env["BASE_IMAGE_POLICY_DIR"] || "", env["BASE_IMAGE_API"] || DEFAULT_API);
  }

  async get(product: string): Promise<Policy> {
    const hit = this.cache.get(product);
    if (hit) return hit;
    const policy = this.fromApi ? await this.fetchProduct(product) : this.readProduct(product);
    this.cache.set(product, policy);
    return policy;
  }

  private readProduct(product: string): Policy {
    const file = join(this.dir, `${product}.json`);
    let size = 0;
    try {
      size = statSync(file).size;
    } catch {
      // missing: handled below with the empty case
    }
    if (size === 0) die(`no policy for '${product}' in ${this.dir}`);
    const policy = parsePolicy(readFileSync(file, "utf8"));
    if (!policy) die(`policy for '${product}' in ${file} has no result.releases — refusing to report green`);
    return policy;
  }

  private async fetchProduct(product: string): Promise<Policy> {
    const url = `${this.api}/${product}`;
    let code = "none";
    let policy: Policy | null = null;
    // Two retries on a transient failure, like the curl this replaced.
    for (let attempt = 0; attempt < 3 && !policy; attempt++) {
      try {
        const res = await fetch(url, { signal: AbortSignal.timeout(20_000) });
        code = String(res.status);
        if (res.status === 200) {
          policy = parsePolicy(await res.text());
          break;
        }
        if (res.status < 500 && res.status !== 408 && res.status !== 429) break;
      } catch {
        code = "none";
      }
      if (attempt < 2) await new Promise((r) => setTimeout(r, 1000 * (attempt + 1)));
    }
    if (!policy) die(`could not fetch policy for '${product}' from ${url} (HTTP ${code}) — refusing to report green`);
    return policy;
  }
}
