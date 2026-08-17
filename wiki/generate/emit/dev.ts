// The dev tier, as a diff against prod.
//
// Dev is a separate compose project that must never point at prod (SERV-77), and
// the interesting content is precisely where the two files disagree — a shared
// value is how isolation breaks. So this page renders differences, not a second
// copy of the service catalogue.

import type { ComposeFile } from "../sources/compose.ts";
import { cell, code, frontmatter, provenance, section, table } from "../lib/md.ts";
import type { Estate } from "../model.ts";
import type { Page } from "./page.ts";
import { servicePath } from "./services.ts";

export function emitDev(estate: Estate): Page[] {
  if (!estate.dev) return [];
  const dev = estate.dev;
  const prodByName = new Map(estate.prod.services.map((s) => [s.name, s]));

  const shared = sharedResources(estate.prod, dev);

  return [
    {
      path: "dev",
      body: [
        frontmatter({ title: "Dev tier" }),
        provenance([dev.label, estate.prod.label]),
        [
          `The \`construct-server-dev\` project runs **${dev.services.length} services** from its own compose file,`,
          "its own Postgres, its own network and its own secrets. A bare `docker compose` in this repo",
          "resolves to the **prod** file, so drive dev with the `make dev-*` targets, which pin the",
          "project name, compose file and env file together.\n\n",
          "Never copy the prod `.env` into dev: purser provisions real accounts across four services, so",
          "a dev purser holding prod credentials does not fail safely — it succeeds, against production.\n\n",
        ].join("\n"),

        section(
          "Services",
          table(
            ["Service", "Image", "Also in prod?", "Networks"],
            dev.services.map((svc) => [
              code(svc.name),
              svc.image ? code(svc.image.repo) : "—",
              prodByName.has(svc.name)
                ? `yes — [${svc.name}](/${servicePath(svc.name)})`
                : "dev only",
              cell(svc.networks.join(", ")),
            ]),
          ),
        ),

        section(
          "Networks",
          table(
            ["Network", "External", "Members"],
            dev.networks.map((n) => [
              code(n.name),
              n.external ? "yes" : "no",
              String(dev.services.filter((s) => s.networks.includes(n.name)).length),
            ]),
          ),
        ),

        section(
          "Isolation",
          shared.length === 0
            ? [
                "::: tip NO SHARED NETWORK",
                "No network is named by both compose files, which is what makes *dev cannot reach prod*",
                "true rather than merely intended. Assert it for real with `make dev-verify-isolation`.",
                ":::\n",
                "Do not attach Traefik to the dev network to route dev hostnames. Its `internal`",
                "entrypoint now binds a single address on `construct_edge_net`, which only cloudflared",
                "shares (SERV-107) — but the prod routers on it still have **no auth middleware**, so",
                "anything that can reach that address gets prod Switchyard and Lyceum by setting a Host",
                "header. Cloudflare Access is enforced at Cloudflare's edge, not here. Attaching Traefik",
                "to a second network makes the entrypoint reachable from that network too, which is",
                "exactly what the bind stopped — so the address restriction does **not** make this safe.",
                "Origin-side JWT validation (SERV-106) is what would. Giving dev an edge is SERV-93.\n",
              ].join("\n")
            : [
                "::: danger SHARED NETWORK",
                "These networks are named by **both** compose files. Anything on a shared network can",
                "reach prod, which is exactly what SERV-77 exists to prevent.",
                ":::\n",
                shared.map((n) => `- ${code(n)}`).join("\n"),
                "\n",
              ].join("\n"),
        ),

        section(
          "Working on it",
          [
            "```bash",
            "make dev-up                    # bring the dev project up",
            "make dev-recreate svc=purser   # pick up a compose change, scoped",
            "make dev-verify-isolation      # assert dev cannot reach prod",
            "make dev-parity                # report dev-vs-prod config drift",
            "```\n",
          ].join("\n"),
        ),
      ].join(""),
    },
  ];
}

/** Networks named by both files — the concrete way isolation would break. */
function sharedResources(prod: ComposeFile, dev: ComposeFile): string[] {
  const prodNets = new Set(prod.networks.map((n) => n.name));
  return dev.networks.map((n) => n.name).filter((n) => prodNets.has(n) && n !== "default");
}
