import type { ComposeService } from "../sources/compose.ts";
import { cell, code, fence, frontmatter, provenance, quote, section, table } from "../lib/md.ts";
import type { Estate } from "../model.ts";
import type { Page } from "./page.ts";
import { servicePath } from "./services.ts";

export function emitTopology(estate: Estate): Page[] {
  return [networksPage(estate), exposurePage(estate), dependencyPage(estate)];
}

function networksPage(estate: Estate): Page {
  const services = estate.prod.services;

  const parts = [
    frontmatter({ title: "Networks" }),
    provenance([estate.prod.label]),
    section(
      "Declared networks",
      table(
        ["Network", "External", "Members"],
        estate.prod.networks.map((n) => [
          code(n.name),
          n.external ? "yes — created outside this file" : "no",
          String(services.filter((s) => s.networks.includes(n.name)).length),
        ]),
      ),
    ),
  ];

  for (const net of estate.prod.networks) {
    const members = services.filter((s) => s.networks.includes(net.name));
    if (members.length === 0) continue;
    const body = [
      net.doc ? quote(net.doc) + "\n" : "",
      members.map((s) => `- [${s.name}](/${servicePath(s.name)})`).join("\n"),
      "\n",
    ].join("");
    parts.push(section(`On \`${net.name}\``, body));
  }

  // Services that name no network sit on compose's implicit `default` bridge, which
  // is per-project and therefore NOT construct_net. Worth stating outright: it is a
  // common source of "why can't this container reach postgres".
  const implicit = services.filter((s) => s.networks.length === 0);
  if (implicit.length > 0) {
    parts.push(
      section(
        "On the implicit default bridge",
        [
          "These declare no `networks:` key, so compose puts them on the project's own",
          "`default` bridge. That is not `construct_net` — a service here cannot resolve",
          "one that is only on `construct_net`, and vice versa.\n",
          implicit.map((s) => `- [${s.name}](/${servicePath(s.name)})`).join("\n"),
          "\n",
        ].join("\n"),
      ),
    );
  }

  return { path: "topology/networks", body: parts.join("") };
}

function exposurePage(estate: Estate): Page {
  const published = estate.prod.services
    .flatMap((svc) => svc.ports.filter((p) => !p.internalOnly).map((port) => ({ svc, port })))
    // Sort on the port actually bound, not on the raw text — otherwise every
    // `${VAR:-4008}` sorts under `$` and the table stops being scannable.
    .sort((a, b) =>
      (a.port.publishedDefault ?? a.port.published ?? "").localeCompare(
        b.port.publishedDefault ?? b.port.published ?? "",
        undefined,
        { numeric: true },
      ),
    );

  // A host binding whose variable has no default is the empty-environment-variable
  // invariant waiting to happen: unset, it interpolates to nothing rather than to a
  // port, and compose does not treat that as an error.
  const noDefault = published.filter(({ port }) => port.publishedVar !== null && port.publishedDefault === null);

  const unpublished = estate.prod.services.filter((s) => s.ports.length > 0 && s.ports.every((p) => p.internalOnly));

  return {
    path: "topology/exposure",
    body: [
      frontmatter({ title: "Host exposure" }),
      provenance([estate.prod.label]),
      "Every port this stack binds on the host, assembled in one place. A port here is reachable from the LAN unless something in front of it says otherwise; a port that is *absent* here is reachable only from a docker network.\n\n",
      section(
        "Published to the host",
        table(
          ["Host binding", "Set by", "Service", "Container port", "Section"],
          published.map(({ svc, port }) => [
            port.publishedDefault ? code(port.publishedDefault) : "**unset**",
            port.publishedVar ? code(port.publishedVar) : "fixed in compose",
            `[${svc.name}](/${servicePath(svc.name)})`,
            code(port.target),
            cell(svc.section),
          ]),
        ),
      ),
      noDefault.length === 0
        ? ""
        : section(
            "Host bindings with no default",
            [
              "::: warning AN EMPTY VARIABLE IS NOT A VALUE",
              "These read a variable that supplies no fallback. If it is unset, the mapping",
              "interpolates to an empty string rather than to a port — which compose does not",
              "treat as an error. The deployed `.env` sets them today; this is what breaks if one",
              "is ever dropped.",
              ":::\n",
              noDefault
                .map(({ svc, port }) => `- [${svc.name}](/${servicePath(svc.name)}) — ${code(port.raw)}`)
                .join("\n"),
              "\n",
            ].join("\n"),
          ),
      section(
        "Declared but not published",
        unpublished.length === 0
          ? ""
          : [
              "Reachable only from the docker networks they sit on. This is what makes the",
              "Traefik `internal` entrypoint work: a tunneled router exists only there, and",
              "there is no host binding to bypass it with.\n",
              unpublished.map((s) => `- [${s.name}](/${servicePath(s.name)}) — ${s.ports.map((p) => code(p.target)).join(", ")}`).join("\n"),
              "\n",
            ].join("\n"),
      ),
    ].join(""),
  };
}

function dependencyPage(estate: Estate): Page {
  const services = estate.prod.services;
  const withDeps = services.filter((s) => s.dependsOn.length > 0);

  return {
    path: "topology/dependencies",
    body: [
      frontmatter({ title: "Startup dependencies" }),
      provenance([estate.prod.label]),
      [
        "`depends_on` is also the blast radius of an unscoped compose command: an action",
        "aimed at one service walks these edges and reaches everything it points at. Every",
        "service with a database points at `postgres`, which is why a bare",
        "`docker compose up -d --force-recreate <svc>` bounces the whole box (SERV-63) and why",
        "`make recreate` passes `--no-deps`.\n\n",
      ].join("\n"),
      section("Graph", fence("mermaid", mermaidGraph(withDeps))),
      section(
        "Edges",
        table(
          ["Service", "Waits for"],
          withDeps.map((s) => [
            `[${s.name}](/${servicePath(s.name)})`,
            s.dependsOn.map((d) => `[${d}](/${servicePath(d)})`).join(", "),
          ]),
        ),
      ),
      section("Most depended on", mostDependedOn(services)),
    ].join(""),
  };
}

function mermaidGraph(services: ComposeService[]): string {
  const lines = ["graph LR"];
  for (const svc of services) {
    for (const dep of svc.dependsOn) {
      lines.push(`  ${mermaidId(svc.name)}["${svc.name}"] --> ${mermaidId(dep)}["${dep}"]`);
    }
  }
  return lines.join("\n");
}

/** Mermaid node ids may not contain `-`, which most service names do. */
function mermaidId(name: string): string {
  return name.replace(/[^A-Za-z0-9]/g, "_");
}

function mostDependedOn(services: ComposeService[]): string {
  const counts = new Map<string, number>();
  for (const svc of services) {
    for (const dep of svc.dependsOn) counts.set(dep, (counts.get(dep) ?? 0) + 1);
  }
  const ranked = [...counts.entries()].sort((a, b) => b[1] - a[1]);
  if (ranked.length === 0) return "";

  return table(
    ["Service", "Services that wait for it"],
    ranked.map(([name, count]) => [`[${name}](/${servicePath(name)})`, String(count)]),
  );
}
