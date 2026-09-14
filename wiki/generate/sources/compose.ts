// Parse a docker-compose file into the model the emitters render.
//
// TWO RULES GOVERN THIS FILE, and both are about not leaking credentials into a
// generated site.
//
//  1. Parse the RAW YAML. Never `docker compose config`, never read a `.env`.
//     The resolved view interpolates every variable, which means it carries real
//     passwords, tokens and API keys — running it here would pipe the contents of
//     PROD_ENV_FILE straight into a Markdown page. The raw file is tracked in git
//     and therefore contains no secret by construction (SERV-31): the only thing
//     an `environment:` entry can hold is a literal that was already public, or a
//     `${VAR}` reference whose value lives somewhere this generator cannot see.
//     That is the whole safety argument, and it only holds while this stays true.
//
//  2. Consequently the generator has no way to know a value it did not read, and
//     that is the point. `env[].value` is populated only for literals present in
//     the tracked file; a `${VAR}` entry records the variable NAME and nothing
//     else.
//
// The other reason to parse raw rather than resolved: comments. This compose file
// carries genuinely good prose — the reasoning behind Watchtower's label gate, why
// Ollama's context length is 64K, what an `extra_hosts` entry is working around.
// `docker compose config` discards all of it, and a wiki assembled from the
// resolved model would be a table dump with the documentation stripped out. So we
// keep the comments and treat them as the primary content.

import { readFileSync } from "node:fs";
import { basename } from "node:path";
import {
  parseDocument,
  isMap,
  isSeq,
  isScalar,
  type Document,
  type Node,
  type Pair,
} from "yaml";

/** A `# --- SECTION NAME ---` banner, used to group services in the compose file. */
const SECTION_RE = /^\s*-{2,}\s*(.+?)\s*-{2,}\s*$/;

/** `${VAR}`, `${VAR:-default}`, `${VAR-default}`. */
const VAR_RE = /\$\{([A-Za-z_][A-Za-z0-9_]*)(?::?-([^}]*))?\}/;

/**
 * An explicit display-name override, written as its own comment line: `# group: Edge
 * Proxy` anywhere after a banner names the group it belongs to, `# name: Cook Book`
 * above a service key names that service. Both are stripped from the prose they sit
 * in. The derivation below covers every banner in the file today; this is the escape
 * hatch for the one it gets wrong tomorrow, and it lives in the compose file because
 * that is the one place the estate already edits — a regex over prose would otherwise
 * keep growing exceptions here, in a file nobody opens to name a section (SERV-186).
 */
const ANNOTATION_RE = /^\s*(name|group):\s*(.+?)\s*$/;

/** A Switchyard ticket key, `SERV-186` or `IDEA-22`. */
const TICKET_KEY = "[A-Z]{3,4}-\\d+";
const TICKET_LIST_RE = new RegExp(`${TICKET_KEY}(\\s*/\\s*${TICKET_KEY})*`);

export interface EnvEntry {
  name: string;
  /** Literal value, when the tracked file spells one out. Null for `${VAR}` refs. */
  value: string | null;
  /** Variable the value is interpolated from, when it is a reference. */
  ref: string | null;
  /** Default supplied by `${VAR:-default}`, if any. */
  fallback: string | null;
  doc: string;
}

export interface PortMapping {
  raw: string;
  published: string | null;
  target: string;
  /** True when the port has no host binding — reachable only on a docker network. */
  internalOnly: boolean;
  /** Variable the host binding comes from, for `${AMBER_PORT:-4008}:4008`. */
  publishedVar: string | null;
  /**
   * The port actually bound when the variable is unset — i.e. what is bound in
   * practice, since these rarely get overridden. Null when the reference carries no
   * default, which is worth noticing: an unset variable there interpolates to an
   * empty string, not to a port.
   */
  publishedDefault: string | null;
}

export interface VolumeMount {
  raw: string;
  source: string;
  target: string;
  mode: string | null;
  kind: "bind" | "named" | "anonymous";
}

export interface ImageRef {
  raw: string;
  repo: string;
  tag: string | null;
  /** `SWITCHYARD_TAG` for `image: …/backend:${SWITCHYARD_TAG:-latest}`. */
  tagVar: string | null;
  tagFallback: string | null;
  /** `sha256:44c4…` for a digest-pinned third-party image (SERV-102, SERV-105). */
  digest: string | null;
  firstParty: boolean;
}

export interface ComposeService {
  /** The compose key — what `docker compose` and the Makefile targets take. */
  name: string;
  /**
   * What to call it on a page. Equal to `name` for every service today except
   * `cook_book`, the one snake_case key, which reads as a typo beside the rest; a
   * `# name:` line above the key overrides it (SERV-186). Never a URL or a command
   * argument — those keep using `name`.
   */
  displayName: string;
  /**
   * The nav label for the section this service sits in: the banner with its ticket
   * keys, parentheticals and trailing description stripped, in Title Case. Null when
   * no banner precedes it, which the model reports as a finding rather than hiding.
   */
  group: string | null;
  /** The `# --- … ---` banner verbatim, ticket keys and all, for the page body. */
  sectionDoc: string | null;
  doc: string;
  image: ImageRef | null;
  build: string | null;
  containerName: string | null;
  restart: string | null;
  user: string | null;
  profiles: string[];
  ports: PortMapping[];
  networks: string[];
  volumes: VolumeMount[];
  dependsOn: string[];
  env: EnvEntry[];
  labels: string[];
  command: string | null;
  healthcheck: boolean;
  extraHosts: string[];
  devices: string[];
}

export interface ComposeFile {
  /** Absolute path this was read from. */
  path: string;
  /** How to name the file on a generated page — repo-relative, never the build machine's layout. */
  label: string;
  services: ComposeService[];
  networks: { name: string; external: boolean; doc: string }[];
  volumes: { name: string; doc: string }[];
}

/** Images published under this org are ours; everything else is a third-party leaf. */
const FIRST_PARTY_PREFIX = "ghcr.io/einlanzerous/";

export function parseCompose(path: string): ComposeFile {
  const doc = parseDocument(readFileSync(path, "utf8"), { keepSourceTokens: false });

  return {
    path,
    // Both compose files sit at the repo root, so the basename is exactly the
    // repo-relative path. Emitting the absolute one would leak the build machine's
    // directory layout onto every page.
    label: basename(path),
    services: parseServices(doc),
    networks: parseTopLevel(doc, "networks").map(({ name, doc: d, node }) => ({
      name,
      doc: d,
      external: isMap(node) && node.get("external") === true,
    })),
    volumes: parseTopLevel(doc, "volumes").map(({ name, doc: d }) => ({ name, doc: d })),
  };
}

function parseServices(doc: Document): ComposeService[] {
  const services = doc.get("services");
  if (!isMap(services)) return [];

  const out: ComposeService[] = [];
  // Section banners cascade: a `# --- ARGOSY ---` header applies to every service
  // after it until the next banner, not just the one it sits above.
  let section: Section = { banner: null, group: null };

  // The FIRST banner does not sit on the first service. `yaml` hangs a comment that
  // precedes the first entry of a map on the map itself, not on that entry's key —
  // so `# --- AI & LLM STACK ---` is on `services`, and `ollama`'s key carries
  // nothing. Reading only the keys lost that banner on every build and emitted
  // ollama under an "Ungrouped" heading that named a bug rather than a section
  // (SERV-186). Seed from the map's own comment, and hand any prose that shares the
  // block to the first service, whose documentation it is.
  const lead = splitSectionComment(commentOf(services));
  section = advance(section, lead);
  let leadProse: string | null = lead.prose || null;
  let leadName: string | null = lead.name;

  for (const item of services.items as Pair<unknown, unknown>[]) {
    const name = scalarString(item.key);
    if (!name) continue;

    const split = splitSectionComment(commentOf(item.key));
    section = advance(section, split);
    const prose = [leadProse, split.prose].filter(Boolean).join("\n\n");
    const displayName = split.name ?? leadName ?? humanise(name);
    leadProse = null;
    leadName = null;

    const body = item.value;
    if (!isMap(body)) continue;

    out.push({
      name,
      displayName,
      group: section.group,
      sectionDoc: section.banner,
      doc: prose,
      image: parseImage(str(body, "image")),
      build: parseBuild(body.get("build", true)),
      containerName: str(body, "container_name"),
      restart: str(body, "restart"),
      user: str(body, "user"),
      profiles: stringList(body.get("profiles", true)),
      ports: stringList(body.get("ports", true)).map(parsePort),
      networks: parseNetworks(body.get("networks", true)),
      volumes: stringList(body.get("volumes", true)).map(parseVolume),
      dependsOn: parseDependsOn(body.get("depends_on", true)),
      env: parseEnvironment(body.get("environment", true)),
      labels: stringList(body.get("labels", true)),
      command: parseCommand(body.get("command", true)),
      healthcheck: body.has("healthcheck"),
      extraHosts: stringList(body.get("extra_hosts", true)),
      devices: stringList(body.get("devices", true)),
    });
  }
  return out;
}

function parseTopLevel(
  doc: Document,
  key: string,
): { name: string; doc: string; node: unknown }[] {
  const map = doc.get(key);
  if (!isMap(map)) return [];
  return (map.items as Pair<unknown, unknown>[]).flatMap((item) => {
    const name = scalarString(item.key);
    if (!name) return [];
    return [{ name, doc: splitSectionComment(commentOf(item.key)).prose, node: item.value }];
  });
}

// --- field parsers ---------------------------------------------------------

function parseImage(raw: string | null): ImageRef | null {
  if (!raw) return null;

  // Finding the tag separator is fiddlier than it looks, in three ways that all
  // bite here. A registry port (`localhost:5000/x`) puts a colon before the last
  // `/` and is not a tag — hence the `colon > slash` test. Every first-party
  // image in this stack is tagged `${SERVICE_TAG:-latest}`, whose *default*
  // syntax contains a colon of its own: a naive lastIndexOf splits
  // `…/amber:${AMBER_TAG:-latest}` into repo `…/amber:${AMBER_TAG` and tag
  // `-latest}`. So mask the `${…}` spans before searching.
  //
  // And a digest pin (`repo:tag@sha256:44c4…`, SERV-102/SERV-105) carries a THIRD
  // colon, the last one in the string — so the same lastIndexOf produced repo
  // `postgres:16.15-alpine@sha256` and tag `44c4ee98…`, which is how the wiki has
  // been describing postgres since it was pinned. An OCI reference is
  // `[registry/]name[:tag][@digest]`, so split the digest off first and let the
  // existing tag logic see the shape it was written for.
  const at = raw.lastIndexOf("@");
  const digest = at >= 0 ? raw.slice(at + 1) : null;
  const ref = at >= 0 ? raw.slice(0, at) : raw;

  const masked = ref.replace(/\$\{[^}]*\}/g, (m) => " ".repeat(m.length));
  const slash = masked.lastIndexOf("/");
  const colon = masked.lastIndexOf(":");
  const hasTag = colon > slash;
  const repo = hasTag ? ref.slice(0, colon) : ref;
  const tag = hasTag ? ref.slice(colon + 1) : null;

  const m = tag ? VAR_RE.exec(tag) : null;
  return {
    raw,
    repo,
    tag,
    tagVar: m?.[1] ?? null,
    tagFallback: m?.[2] ?? null,
    digest,
    firstParty: repo.startsWith(FIRST_PARTY_PREFIX),
  };
}

function parsePort(raw: string): PortMapping {
  // "8080:80", "127.0.0.1:8080:80", "${PORT:-4002}:4002", "9080". Mask the `${…}`
  // spans first for the same reason parseImage does: `${PORT:-4002}` contains a
  // colon that is not a field separator.
  const masked = raw.replace(/\$\{[^}]*\}/g, (m) => " ".repeat(m.length));
  const bounds: number[] = [];
  for (let i = 0; i < masked.length; i++) if (masked[i] === ":") bounds.push(i);

  const lastColon = bounds[bounds.length - 1];
  const target = lastColon === undefined ? raw : raw.slice(lastColon + 1);
  const published = lastColon === undefined ? null : raw.slice(0, lastColon);

  const m = published ? VAR_RE.exec(published) : null;
  return {
    raw,
    published,
    target,
    internalOnly: published === null,
    publishedVar: m?.[1] ?? null,
    publishedDefault: m ? (m[2] ?? null) || null : published,
  };
}

function parseVolume(raw: string): VolumeMount {
  const parts = raw.split(":");
  const source = parts[0] ?? raw;
  const target = parts[1] ?? "";
  const mode = parts[2] ?? null;
  const kind = target === "" ? "anonymous" : source.startsWith(".") || source.startsWith("/") ? "bind" : "named";
  return { raw, source, target, mode, kind };
}

// `networks:` has the same two forms as `depends_on:` — a plain list of names, or a map
// keyed by network with per-network settings under it. Only the names matter here.
//
// The map form is not hypothetical: SERV-107 gave traefik
// `construct_net: {}` / `construct_edge_net: {ipv4_address: …}` so the internal
// entrypoint could bind one address. Under the list-only reader that parsed as `[]`,
// silently — no throw — and the wiki then claimed traefik declared no networks at all
// and put it on the project default, on the one service where the answer *is* the
// security control. A wrong topology page is worse than a missing one.
function parseNetworks(node: unknown): string[] {
  if (isSeq(node)) return stringList(node);
  if (isMap(node)) {
    return (node.items as Pair<unknown, unknown>[])
      .map((item) => scalarString(item.key))
      .filter((n): n is string => n !== null);
  }
  return [];
}

function parseDependsOn(node: unknown): string[] {
  // Both forms appear in the wild: a plain list, and a map keyed by service with a
  // `condition:`. Only the names matter here.
  if (isSeq(node)) return stringList(node);
  if (isMap(node)) {
    return (node.items as Pair<unknown, unknown>[])
      .map((item) => scalarString(item.key))
      .filter((n): n is string => n !== null);
  }
  return [];
}

function parseEnvironment(node: unknown): EnvEntry[] {
  if (isSeq(node)) {
    return node.items.flatMap((item) => {
      const text = scalarString(item);
      if (!text) return [];
      return [{ ...splitEnvAssignment(text), doc: commentOf(item) }];
    });
  }
  if (isMap(node)) {
    return (node.items as Pair<unknown, unknown>[]).flatMap((item) => {
      const name = scalarString(item.key);
      if (!name) return [];
      const value = scalarString(item.value) ?? "";
      return [{ ...splitEnvAssignment(`${name}=${value}`), doc: commentOf(item.key) }];
    });
  }
  return [];
}

function splitEnvAssignment(text: string): Omit<EnvEntry, "doc"> {
  const eq = text.indexOf("=");
  if (eq === -1) {
    // `- SOME_VAR` with no `=` passes the host's value through. There is no value
    // here to read, and that is the safe direction.
    return { name: text.trim(), value: null, ref: text.trim(), fallback: null };
  }
  const name = text.slice(0, eq).trim();
  const rhs = text.slice(eq + 1);
  const m = VAR_RE.exec(rhs);
  if (m) return { name, value: null, ref: m[1] ?? null, fallback: m[2] ?? null };
  return { name, value: rhs, ref: null, fallback: null };
}

function parseCommand(node: unknown): string | null {
  if (isScalar(node)) return scalarString(node);
  if (isSeq(node)) return stringList(node).join(" ");
  return null;
}

function parseBuild(node: unknown): string | null {
  if (isScalar(node)) return scalarString(node);
  if (isMap(node)) return scalarString(node.get("context", true)) ?? ".";
  return null;
}

// --- comment plumbing ------------------------------------------------------

/**
 * `yaml` hangs comments that precede a node on `commentBefore`, with the leading
 * `#` stripped and lines joined by `\n`. A blank line between two comment blocks
 * survives as an empty line, which is what lets a section banner be told apart
 * from the prose belonging to the service under it.
 */
function commentOf(node: unknown): string {
  const raw = (node as Node | undefined)?.commentBefore;
  if (!raw) return "";
  return raw
    .split("\n")
    .map((line) => line.replace(/^ /, ""))
    .join("\n")
    .trim();
}

/** The section a service falls under: the banner as written, and the label derived from it. */
interface Section {
  banner: string | null;
  group: string | null;
}

/**
 * Fold one comment block into the running section. A new banner replaces both the
 * banner and the label; a `# group:` line replaces the label only, whether it sits
 * under a fresh banner or three services later — it is an override on whatever
 * section is current.
 */
function advance(current: Section, found: SplitComment): Section {
  const banner = found.banner ?? current.banner;
  const group = found.group ?? (found.banner ? groupLabel(found.banner) : current.group);
  return { banner, group };
}

interface SplitComment {
  banner: string | null;
  /** `# group:` override, when the block carries one. */
  group: string | null;
  /** `# name:` override, when the block carries one. */
  name: string | null;
  prose: string;
}

/**
 * Pull a `--- SECTION ---` banner out of a comment block, returning it separately
 * from the prose. Banners are matched anywhere in the block because a service is
 * routinely preceded by both its section header and its own explanation; the last
 * banner wins, and only the lines after it are that service's documentation.
 * Annotation lines (`name:`, `group:`) are lifted out of the prose wherever they sit.
 */
function splitSectionComment(comment: string): SplitComment {
  if (!comment) return { banner: null, group: null, name: null, prose: "" };
  const lines = comment.split("\n");

  let banner: string | null = null;
  let lastBanner = -1;
  lines.forEach((line, i) => {
    const m = SECTION_RE.exec(line);
    if (m?.[1]) {
      banner = m[1];
      lastBanner = i;
    }
  });

  let group: string | null = null;
  let name: string | null = null;
  const prose: string[] = [];
  for (const line of lines.slice(lastBanner + 1)) {
    const m = ANNOTATION_RE.exec(line);
    if (m?.[1] === "group") group = m[2] ?? null;
    else if (m?.[1] === "name") name = m[2] ?? null;
    else prose.push(line);
  }

  return { banner, group, name, prose: prose.join("\n").trim() };
}

/**
 * Words whose Title Case is wrong. Acronyms, and one brand: no rule can tell `ASR`
 * from `AMBER` in an all-caps banner, so the ones that must stay upper are listed.
 * Keep this to casing — a section that needs a different *name* gets a `# group:`
 * line in the compose file, not an entry here.
 */
const WORD_CASE: Record<string, string> = {
  ai: "AI",
  llm: "LLM",
  ui: "UI",
  asr: "ASR",
  crowdsec: "CrowdSec",
};

/**
 * The nav label for a banner. Banners were written as headings in the old sections
 * and as sentences with ticket suffixes in the new ones, and printed verbatim they
 * make the sidebar read as a changelog — 16 of 28 carried a key, one ran to 68
 * characters (SERV-186). So: drop the ticket keys, whether trailing (`— SERV-33`,
 * `— PCAD-1 / IDEA-22`) or parenthesised mid-name (`CROWDSEC (SERV-27) — …`); drop
 * any remaining parenthetical, which is always the product behind a role
 * (`DASHBOARD (Aperture)`); keep what precedes the first ` — `, which is always a
 * description; then Title Case what is left. The full banner survives as
 * `sectionDoc`, so the keys move to the page body rather than disappearing.
 */
export function groupLabel(banner: string): string {
  const stripped = banner
    .replace(new RegExp(`\\s*\\(\\s*${TICKET_LIST_RE.source}\\s*\\)`, "g"), "")
    .replace(new RegExp(`\\s+[—–-]\\s*${TICKET_LIST_RE.source}\\s*$`), "")
    .replace(/\s*\([^)]*\)/g, "")
    .split(/\s+[—–]\s+/)[0] ?? "";
  return titleCase(stripped.replace(/\s+/g, " ").trim());
}

function titleCase(text: string): string {
  return text
    .split(" ")
    .map((word) =>
      word
        .split("-")
        .map((part) => {
          const lower = part.toLowerCase();
          return WORD_CASE[lower] ?? (lower ? lower[0]!.toUpperCase() + lower.slice(1) : part);
        })
        .join("-"),
    )
    .join(" ");
}

/**
 * A snake_case compose key is a product name written to satisfy a filesystem —
 * `cook_book` is Cook Book. Every other key in the file is a bare lowercase word or
 * a hyphenated one, and those are left exactly as written: `cf-access-guard` is its
 * name, and capitalising it would make it read as three words.
 */
export function humanise(name: string): string {
  if (!name.includes("_")) return name;
  return titleCase(name.replace(/_/g, " "));
}

// --- small helpers ---------------------------------------------------------

function scalarString(node: unknown): string | null {
  if (typeof node === "string") return node;
  if (typeof node === "number" || typeof node === "boolean") return String(node);
  if (isScalar(node)) {
    const v = node.value;
    return v === null || v === undefined ? null : String(v);
  }
  return null;
}

function str(map: { get(key: string, keepScalar?: boolean): unknown }, key: string): string | null {
  return scalarString(map.get(key, true));
}

function stringList(node: unknown): string[] {
  if (!isSeq(node)) return [];
  return node.items.map(scalarString).filter((s): s is string => s !== null);
}
