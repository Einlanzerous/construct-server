import type { ComposeService } from "../sources/compose.ts";
import { repoFromImage } from "../sources/repos.ts";
import { pinBehaviour } from "../sources/versions.ts";
import {
  cell,
  code,
  fence,
  frontmatter,
  provenance,
  prose,
  quote,
  section,
  slug,
  table,
} from "../lib/md.ts";
import { dependents, groupBySection, pinFor, type Estate } from "../model.ts";
import type { Page } from "./page.ts";

export function emitServices(estate: Estate): Page[] {
  return [servicesIndex(estate), ...estate.prod.services.map((svc) => servicePage(estate, svc))];
}

export function servicePath(name: string): string {
  return `services/${slug(name)}`;
}

function servicesIndex(estate: Estate): Page {
  const parts: string[] = [
    frontmatter({ title: "Services" }),
    provenance([estate.prod.label]),
    `The prod stack runs **${estate.prod.services.length} services** from a single compose file, grouped here the way that file groups them.\n\n`,
  ];

  for (const group of groupBySection(estate.prod.services)) {
    parts.push(`## ${group.section}\n\n`);
    parts.push(
      table(
        ["Service", "Image", "Published ports", "Depends on"],
        group.services.map((svc) => [
          `[${svc.name}](/${servicePath(svc.name)})`,
          svc.image ? code(svc.image.repo) : svc.build ? `built from ${code(svc.build)}` : "—",
          cell(svc.ports.filter((p) => !p.internalOnly).map((p) => p.raw).join(", ")),
          cell(svc.dependsOn.join(", ")),
        ]),
      ),
    );
  }

  return { path: "services/index", body: parts.join("") };
}

function servicePage(estate: Estate, svc: ComposeService): Page {
  const parts: string[] = [
    frontmatter({ title: svc.name }),
    provenance([estate.prod.label]),
  ];

  if (svc.doc) parts.push(quote(svc.doc) + "\n");

  parts.push(section("At a glance", table(["", ""], glanceRows(estate, svc))));

  // Ports. The distinction that matters is whether a port is published to the host
  // at all: an unpublished one is reachable only from a docker network, which is
  // the entire security argument behind the internal Traefik entrypoint.
  if (svc.ports.length > 0) {
    parts.push(
      section(
        "Ports",
        table(
          ["Mapping", "Bound on the host", "Container", "Reachable from"],
          svc.ports.map((p) => [
            code(p.raw),
            p.internalOnly
              ? "not published"
              : p.publishedDefault
                ? code(p.publishedDefault)
                : "**unset unless the variable is**",
            code(p.target),
            p.internalOnly ? "docker networks only" : "the host",
          ]),
        ),
      ),
    );
  }

  if (svc.networks.length > 0) {
    parts.push(section("Networks", svc.networks.map((n) => `- ${code(n)}`).join("\n") + "\n"));
  }

  if (svc.volumes.length > 0) {
    parts.push(
      section(
        "Volumes",
        table(
          ["Source", "Mounted at", "Kind", "Mode"],
          svc.volumes.map((v) => [code(v.source), code(v.target), v.kind, v.mode ? code(v.mode) : "rw"]),
        ),
      ),
    );
  }

  parts.push(section("Dependencies", dependencyBody(estate, svc)));

  if (svc.env.length > 0) {
    parts.push(
      section(
        "Environment",
        [
          "Variable *names* only where the value is interpolated. This page is generated from the tracked compose file, which holds no secrets — the values behind these references live in the deployed `.env` and are never read here.\n",
          table(
            ["Variable", "Value", "Notes"],
            svc.env.map((e) => [
              code(e.name),
              envValue(e.value, e.ref, e.fallback),
              cell(prose(e.doc).split("\n").join(" ")),
            ]),
          ),
        ].join("\n"),
      ),
    );
  }

  if (svc.labels.length > 0) {
    parts.push(section("Labels", svc.labels.map((l) => `- ${code(l)}`).join("\n") + "\n"));
  }

  const extras: string[] = [];
  if (svc.command) extras.push(`**Command** — ${code(svc.command)}`);
  if (svc.extraHosts.length > 0) extras.push(`**Extra hosts** — ${svc.extraHosts.map(code).join(", ")}`);
  if (svc.devices.length > 0) extras.push(`**Devices** — ${svc.devices.map(code).join(", ")}`);
  if (svc.user) extras.push(`**Runs as** — ${code(svc.user)}`);
  if (extras.length > 0) parts.push(section("Runtime", extras.join("\n\n") + "\n"));

  parts.push(section("Operating on it", operatingBody(svc)));

  return { path: servicePath(svc.name), body: parts.join("") };
}

function glanceRows(estate: Estate, svc: ComposeService): (string | null)[][] {
  const rows: (string | null)[][] = [];
  const pin = pinFor(estate, svc);

  if (svc.image) {
    rows.push(["Image", code(svc.image.repo)]);
    if (svc.image.tagVar) {
      const resolved = pin ? code(pin.value) : "**unpinned**";
      rows.push([
        "Tag",
        `${code(svc.image.tag)} → ${resolved}${pin ? ` (${pin.style})` : ""}`,
      ]);
    } else if (svc.image.tag) {
      rows.push(["Tag", code(svc.image.tag)]);
    }
    rows.push(["Origin", svc.image.firstParty ? "first-party" : "third-party"]);
  }
  if (svc.build) rows.push(["Built from", code(svc.build)]);

  const repo = svc.image?.firstParty ? repoFromImage(svc.image.repo) : null;
  if (repo) rows.push(["Source repo", `[${repo}](/repos/${slug(repo)})`]);

  rows.push(["Container name", code(svc.containerName ?? svc.name)]);
  rows.push(["Restart policy", svc.restart ? code(svc.restart) : "none — not restarted automatically"]);
  rows.push(["Healthcheck", svc.healthcheck ? "yes" : "no"]);

  if (svc.profiles.length > 0) {
    rows.push([
      "Compose profile",
      `${svc.profiles.map(code).join(", ")} — **not started** by a plain \`docker compose up -d\`; you must opt in`,
    ]);
  }

  if (pin) rows.push(["Pin behaviour", pinBehaviour(pin.style)]);

  return rows;
}

function dependencyBody(estate: Estate, svc: ComposeService): string {
  const upstream = svc.dependsOn;
  const downstream = dependents(estate.prod.services, svc.name);
  if (upstream.length === 0 && downstream.length === 0) return "";

  const lines: string[] = [];
  if (upstream.length > 0) {
    lines.push(
      `**Waits for** ${upstream.map((d) => `[${d}](/${servicePath(d)})`).join(", ")}.`,
    );
  }
  if (downstream.length > 0) {
    lines.push(
      `**Waited on by** ${downstream.map((d) => `[${d}](/${servicePath(d)})`).join(", ")}.`,
    );
    lines.push(
      "",
      "Compose follows `depends_on`, so an unscoped action aimed at this service reaches all of them. Use the `make` targets below, which pass `--no-deps` (SERV-63).",
    );
  }
  return lines.join("\n") + "\n";
}

function operatingBody(svc: ComposeService): string {
  return [
    "Never `docker restart` this — a restart keeps the container's **old** spec, so",
    "an image, mount or env change in compose silently does not take effect (SERV-8).",
    "Recreate it instead:",
    "",
    fence("bash", [
      `make recreate svc=${svc.name}         # picks up compose changes`,
      `make drift-check svc=${svc.name}      # confirm it matches the deployed file`,
    ].join("\n")),
  ].join("\n");
}

function envValue(value: string | null, ref: string | null, fallback: string | null): string {
  if (value !== null) return code(value);
  if (ref === null) return "—";
  const base = `from ${code(ref)}`;
  return fallback === null || fallback === "" ? base : `${base}, default ${code(fallback)}`;
}
