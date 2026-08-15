// Assemble the sources into one model. Everything downstream renders from this;
// nothing downstream reads a file.

import { parseCompose, type ComposeFile, type ComposeService } from "./sources/compose.ts";
import { parseVersions, type VersionPin } from "./sources/versions.ts";
import {
  EXTRA_REPOS,
  loadRepoDocs,
  repoFromImage,
  type Repo,
} from "./sources/repos.ts";

export interface Estate {
  prod: ComposeFile;
  dev: ComposeFile | null;
  pins: VersionPin[];
  repos: Repo[];
  /** Local files ingested verbatim into the reference section. */
  reference: { title: string; path: string; body: string }[];
  buildRef: string;
}

export interface EstateInputs {
  composePath: string;
  devComposePath: string | null;
  versionsPath: string;
  repoDocsCache: string;
  reference: { title: string; path: string; body: string }[];
  buildRef: string;
}

export function buildEstate(inputs: EstateInputs): Estate {
  const prod = parseCompose(inputs.composePath);
  const dev = inputs.devComposePath ? parseCompose(inputs.devComposePath) : null;
  const pins = parseVersions(inputs.versionsPath);

  return {
    prod,
    dev,
    pins,
    repos: deriveRepos(prod, pins, inputs.repoDocsCache),
    reference: inputs.reference,
    buildRef: inputs.buildRef,
  };
}

/**
 * Derive the repo list from the compose file rather than hardcoding it, so adding
 * a first-party service to the stack adds it to the wiki with no second edit. Only
 * repos that ship no image at all need naming explicitly (EXTRA_REPOS).
 */
function deriveRepos(prod: ComposeFile, pins: VersionPin[], cacheDir: string): Repo[] {
  const byName = new Map<string, Repo>();

  const ensure = (name: string): Repo => {
    let repo = byName.get(name);
    if (!repo) {
      repo = {
        name,
        slug: `Einlanzerous/${name}`,
        images: [],
        services: [],
        tagVariable: null,
        docs: [],
        missing: false,
      };
      byName.set(name, repo);
    }
    return repo;
  };

  for (const svc of prod.services) {
    if (!svc.image?.firstParty) continue;
    const name = repoFromImage(svc.image.repo);
    if (!name) continue;

    const repo = ensure(name);
    if (!repo.images.includes(svc.image.repo)) repo.images.push(svc.image.repo);
    repo.services.push(svc.name);
    repo.tagVariable ??= svc.image.tagVar;
  }

  for (const name of EXTRA_REPOS) ensure(name);

  // Attach the pin by repo name. A pin whose repo never appears in compose is left
  // alone here and reported by the versions page — a stale pin is a real finding,
  // not something to silently drop.
  for (const pin of pins) {
    const repo = byName.get(pin.repo);
    if (repo) repo.tagVariable ??= pin.variable;
  }

  for (const repo of byName.values()) {
    repo.docs = loadRepoDocs(cacheDir, repo.name);
    repo.missing = repo.docs.length === 0;
  }

  return [...byName.values()].sort((a, b) => a.name.localeCompare(b.name));
}

/** Group services in compose-file order, preserving the `# --- SECTION ---` runs. */
export function groupBySection(services: ComposeService[]): { section: string; services: ComposeService[] }[] {
  const out: { section: string; services: ComposeService[] }[] = [];
  for (const svc of services) {
    const section = svc.section ?? "Ungrouped";
    const last = out[out.length - 1];
    if (last && last.section === section) last.services.push(svc);
    else out.push({ section, services: [svc] });
  }
  return out;
}

/** Which pin, if any, decides this service's image tag. */
export function pinFor(estate: Estate, svc: ComposeService): VersionPin | null {
  if (!svc.image?.tagVar) return null;
  return estate.pins.find((p) => p.variable === svc.image?.tagVar) ?? null;
}

/** Services that name this one in `depends_on`. */
export function dependents(services: ComposeService[], name: string): string[] {
  return services.filter((s) => s.dependsOn.includes(name)).map((s) => s.name);
}
