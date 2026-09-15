// Assemble the sources into one model. Everything downstream renders from this;
// nothing downstream reads a file.

import { loadArchitecture } from "./sources/architecture.ts";
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
  /** The dev project's own pins (SERV-97). Empty when `dev-versions.env` is absent. */
  devPins: VersionPin[];
  repos: Repo[];
  /** Local files ingested verbatim into the reference section. */
  reference: { title: string; path: string; body: string }[];
  buildRef: string;
}

export interface EstateInputs {
  composePath: string;
  devComposePath: string | null;
  versionsPath: string;
  devVersionsPath: string | null;
  repoDocsCache: string;
  reference: { title: string; path: string; body: string }[];
  buildRef: string;
}

export function buildEstate(inputs: EstateInputs): Estate {
  const prod = parseCompose(inputs.composePath);
  const dev = inputs.devComposePath ? parseCompose(inputs.devComposePath) : null;
  const pins = parseVersions(inputs.versionsPath);
  // Deliberately NOT merged into `pins`. They are different vocabularies for different
  // environments, and the version page's whole job is to say what PROD runs.
  const devPins = inputs.devVersionsPath ? parseVersions(inputs.devVersionsPath) : [];

  return {
    prod,
    dev,
    pins,
    devPins,
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
        architecture: null,
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

  // The pin named after the repo wins over the first image's variable. Compose order
  // puts `asr` before `chronicle`, and both are chronicle's (IMAGE_REPO_ALIASES), so
  // the loop above would call chronicle "pinned by ASR_TAG" — the pin of a subtree
  // on its own release train, not the repo's. A pin whose repo never appears in
  // compose is left alone here and reported by the versions page: a stale pin is a
  // real finding, not something to silently drop.
  for (const pin of pins) {
    const repo = byName.get(pin.repo);
    if (repo) repo.tagVariable = pin.variable;
  }

  for (const repo of byName.values()) {
    repo.docs = loadRepoDocs(cacheDir, repo.name);
    repo.missing = repo.docs.length === 0;
    // Paths only. The IR is archify's input, so nothing here reads its body beyond
    // the `meta` the page's provenance line needs.
    repo.architecture = loadArchitecture(cacheDir, repo.name);
  }

  return [...byName.values()].sort((a, b) => a.name.localeCompare(b.name));
}

export interface ServiceGroup {
  /** The nav label — see `ComposeService.group`. */
  label: string;
  /** The banner as written in compose, for the page body. Null only for the fallback group. */
  banner: string | null;
  services: ComposeService[];
}

/**
 * Group services in compose-file order, preserving the `# --- SECTION ---` runs.
 * A service with no banner above it lands under "Ungrouped" — that is a finding about
 * the compose file, and it is emitted rather than hidden so that it gets fixed there.
 * As of SERV-186 every service has one, including the first (whose banner the parser
 * used to lose).
 */
export function groupBySection(services: ComposeService[]): ServiceGroup[] {
  const out: ServiceGroup[] = [];
  for (const svc of services) {
    const label = svc.group ?? "Ungrouped";
    const last = out[out.length - 1];
    if (last && last.label === label) last.services.push(svc);
    else out.push({ label, banner: svc.sectionDoc, services: [svc] });
  }
  return out;
}

/**
 * The banner for a group, when it says more than the label does. `FILE SHARING` and
 * `File Sharing` are the same words and rendering both would be noise; `ESTATE WIKI
 * (SERV-101) — generated, served read-only` carries the ticket and the description
 * that the label was stripped of, and that is what the page body keeps.
 */
export function groupDescription(group: ServiceGroup): string | null {
  if (!group.banner) return null;
  const fold = (s: string) => s.toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
  return fold(group.banner) === fold(group.label) ? null : group.banner;
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
