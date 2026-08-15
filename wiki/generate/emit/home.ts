import { code, frontmatter, table } from "../lib/md.ts";
import { groupBySection, type Estate } from "../model.ts";
import type { Page } from "./page.ts";
import { servicePath } from "./services.ts";

export function emitHome(estate: Estate): Page {
  const services = estate.prod.services;
  const firstParty = services.filter((s) => s.image?.firstParty);
  const published = services.flatMap((s) => s.ports.filter((p) => !p.internalOnly));
  const profiled = services.filter((s) => s.profiles.length > 0);

  return {
    path: "index",
    body: [
      frontmatter({ title: "The Imperial Construct" }),
      "# The Imperial Construct\n\n",
      "A self-hosted home operations center. This wiki is **generated** from the stack definition on every deploy, so it describes what is actually running rather than what someone once wrote down.\n\n",

      "::: warning NOTHING HERE IS HAND-WRITTEN\n",
      "Every page is assembled by `wiki/generate` from `docker-compose.yml`, `versions.env` and each repo's own docs. An edit made here is gone at the next deploy. To change what a page says, change the file it was generated from — the banner at the top of each page names it.\n",
      ":::\n\n",

      "## What is running\n\n",
      table(
        ["", ""],
        [
          ["Prod services", String(services.length)],
          ["First-party images", String(firstParty.length)],
          ["Source repos", String(estate.repos.length)],
          ["Version pins", String(estate.pins.length)],
          ["Ports published to the host", String(published.length)],
          ["Dev services", String(estate.dev?.services.length ?? 0)],
          ["Behind a compose profile", profiled.length > 0 ? profiled.map((s) => code(s.name)).join(", ") : "—"],
          ["Built from", code(estate.buildRef)],
        ],
      ),
      "\n",

      "## Start here\n\n",
      [
        "- **[Services](/services/)** — every container, its image, ports, mounts and environment, with the compose file's own reasoning attached.",
        "- **[Deployed versions](/versions)** — what version of what is live, and what each pin does on the next pull.",
        "- **[Host exposure](/topology/exposure)** — every port bound on the host, in one table.",
        "- **[Networks](/topology/networks)** — who can reach whom.",
        "- **[Startup dependencies](/topology/dependencies)** — `depends_on`, which is also the blast radius of an unscoped compose command.",
        // Computed, not written down. The stats table eight lines up renders the
        // same number, and a hardcoded one contradicts it the day a repo is added —
        // which is exactly the drift this tier exists to prevent.
        `- **[Repositories](/repos/)** — the ${estate.repos.length} repos behind the stack, each with its own \`CLAUDE.md\` reproduced.`,
        "- **[Reference](/reference/)** — the design documents: delivery pipeline, edge, dev environment, estate principles.",
        "",
      ].join("\n"),

      "## The stack, by section\n\n",
      groupBySection(services)
        .map(({ section, services: group }) => {
          // servicePath, not the bare name: `cook_book` slugs to `cook-book`, and a
          // hand-built link would 404 on exactly the services whose names are unusual.
          const names = group.map((s) => `[${s.name}](/${servicePath(s.name)})`).join(" · ");
          return `**${section}**  \n${names}\n`;
        })
        .join("\n"),
      "\n",

      "## Three rules this wiki cannot tell you often enough\n\n",
      [
        "1. **Recreate containers, never restart them.** `docker restart` keeps the container's old spec, so an image, mount or env change never takes effect. Use `make recreate svc=<svc>`.",
        "2. **Scope a single-service action with `--no-deps`.** Compose follows `depends_on`, and everything with a database points at `postgres` — so an action aimed at one container bounces the box. The `make` targets bake the flag in.",
        "3. **An empty environment variable is not a value.** Never let an unset or empty env propagate into compose or SQL as if it were set. Skip loudly instead of substituting a default.",
        "",
      ].join("\n"),
    ].join(""),
  };
}
