// The dev tier, as a diff against prod.
//
// Dev is a separate compose project that must never point at prod (SERV-77), and
// the interesting content is precisely where the two files disagree — a shared
// value is how isolation breaks. So this page renders differences, not a second
// copy of the service catalogue.

import type { ComposeFile, ComposeService } from "../sources/compose.ts";
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
          [
            table(
              ["Service", "Image", "Tracks", "Also in prod?", "Networks"],
              dev.services.map((svc) => [
                code(svc.name),
                svc.image ? code(svc.image.repo) : "—",
                tracks(estate, svc.image),
                prodByName.has(svc.name)
                  ? `yes — [${svc.name}](/${servicePath(svc.name)})`
                  : "dev only",
                cell(svc.networks.join(", ")),
              ]),
            ),
            "\n**Tracks** comes from `dev-versions.env`, dev's own pin file (SERV-97), and every",
            "value in it is `latest` on purpose — dev exists to run what just merged. The file is",
            "separate from prod's `versions.env`, with a `DEV_` prefix on every variable, so a",
            "misplaced prod `.env` cannot quietly pin dev to prod's versions.\n\n",
            "A floating tag is not a floating container. The image string never changes, so",
            "compose sees no drift and `up -d` alone moves nothing — dev advances only when",
            "something pulls, which is `deploy-dev.yml` on merge, on dispatch, and hourly.\n\n",
          ].join("\n"),
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
                "Do not attach Traefik to the dev network casually — but the reason has changed and",
                "shrunk. Its `internal` entrypoint binds a single address on `construct_edge_net`, which",
                "only cloudflared shares (SERV-107), *and* every router on it now validates the",
                "Cloudflare Access JWT at the origin (SERV-106). A dev hostname routed through the prod",
                "Traefik would be **refused**, not served: a host with no entry in the guard's",
                "`CF_ACCESS_AUD_MAP` fails closed. So SERV-93's open question is whether dev gets its own",
                "Access applications on this Traefik or its own Traefik entirely — not how to avoid an",
                "unauthenticated route into prod, which no longer exists.\n",
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
            "make dev-health-check          # fail if anything in dev is unhealthy or dead",
            "make dev-versions              # what dev is running, by the commit each image was built from",
            "```\n",
          ].join("\n"),
        ),
      ].join(""),
    },
  ];
}

/**
 * What tag a dev service resolves to: the pin if `dev-versions.env` sets one, otherwise
 * the compose fallback. Says which of the two it is, because "latest because that is the
 * pin" and "latest because nothing is pinned" are different states with the same word.
 */
function tracks(estate: Estate, image: ComposeService["image"]): string {
  if (!image) return "—";
  if (!image.tagVar) return image.digest ? "pinned by digest" : code(image.tag);

  const pin = estate.devPins.find((p) => p.variable === image.tagVar);
  return pin
    ? `${code(pin.value)} — ${code(image.tagVar)}`
    : `${code(image.tagFallback)} — ${code(image.tagVar)} unset, compose fallback`;
}

/** Networks named by both files — the concrete way isolation would break. */
function sharedResources(prod: ComposeFile, dev: ComposeFile): string[] {
  const prodNets = new Set(prod.networks.map((n) => n.name));
  return dev.networks.map((n) => n.name).filter((n) => prodNets.has(n) && n !== "default");
}
