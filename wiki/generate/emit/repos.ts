import { GITHUB_OWNER, repoUrl, type Repo } from "../sources/repos.ts";
import { absolutizeLinks, code, demoteHeadings, frontmatter, provenance, section, slug, table } from "../lib/md.ts";
import type { Estate } from "../model.ts";
import type { Page } from "./page.ts";
import { servicePath } from "./services.ts";

export function emitRepos(estate: Estate): Page[] {
  return [repoIndex(estate), ...estate.repos.map((repo) => repoPage(estate, repo))];
}

export function repoPath(name: string): string {
  return `repos/${slug(name)}`;
}

function repoIndex(estate: Estate): Page {
  const missing = estate.repos.filter((r) => r.missing);

  return {
    path: "repos/index",
    body: [
      frontmatter({ title: "Repositories" }),
      provenance([estate.prod.label, "versions.env", "per-repo CLAUDE.md"]),
      [
        `**${estate.repos.length} repos** feed this estate. The list is derived from the first-party`,
        "images in compose, so a service added to the stack appears here without a second edit.\n\n",
        "Each repo's own `CLAUDE.md` is reproduced on its page. That file is the best writing about",
        "the service and it stays true because it sits in git next to the code — this wiki assembles",
        "those, it does not replace them. **Fix anything wrong on a repo page in that repo.**\n\n",
      ].join("\n"),

      section(
        "Repos",
        table(
          ["Repo", "Pinned by", "Services", "Docs"],
          estate.repos.map((r) => [
            `[${r.name}](/${repoPath(r.name)})`,
            r.tagVariable ? code(r.tagVariable) : "—",
            r.services.length > 0 ? r.services.map((s) => `[${s}](/${servicePath(s)})`).join(", ") : "—",
            r.docs.length > 0 ? r.docs.map((d) => d.file).join(", ") : "**none cached**",
          ]),
        ),
      ),

      missing.length === 0
        ? ""
        : section(
            "Repos with no cached docs",
            [
              "The generator found no documentation for these. Either the repo has no `CLAUDE.md`",
              "or `README.md`, or the fetch step could not reach it — a fetch failure is reported",
              "as a warning rather than failing the build, so a GitHub outage degrades the wiki",
              "instead of blocking a deploy.\n",
              missing.map((r) => `- [${r.name}](${repoUrl(r.name)})`).join("\n"),
              "\n",
            ].join("\n"),
          ),
    ].join(""),
  };
}

function repoPage(estate: Estate, repo: Repo): Page {
  const pin = estate.pins.find((p) => p.variable === repo.tagVariable);

  const parts: string[] = [
    frontmatter({ title: repo.name }),
    provenance([`${repo.slug} — ${repo.docs.map((d) => d.file).join(", ") || "no docs cached"}`]),
    section(
      "At a glance",
      table(
        ["", ""],
        [
          ["Source", `[${repo.slug}](${repoUrl(repo.name)})`],
          ["Pinned by", repo.tagVariable ? `${code(repo.tagVariable)} = ${code(pin?.value)}` : "— (ships no image)"],
          [
            "Services",
            repo.services.length > 0
              ? repo.services.map((s) => `[${s}](/${servicePath(s)})`).join(", ")
              : "— (not a compose service)",
          ],
          ["Images", repo.images.length > 0 ? repo.images.map(code).join(", ") : "—"],
        ],
      ),
    ),
  ];

  if (repo.docs.length === 0) {
    parts.push(
      [
        "::: warning NO DOCS CACHED",
        `Nothing was fetched for this repo. Read it at [${repo.slug}](${repoUrl(repo.name)}).`,
        ":::",
        "",
      ].join("\n"),
    );
  }

  for (const doc of repo.docs) {
    parts.push(
      [
        `## ${doc.file}`,
        "",
        `*Reproduced from [${repo.slug}/${doc.file}](${repoUrl(repo.name)}/blob/main/${doc.file}). Edit it there.*`,
        "",
        // The ingested file owns h1; demote so it nests under this page's h2 instead
        // of competing with the page title. Links are resolved against the repo the
        // document came from, not against this site.
        demoteHeadings(absolutizeLinks(doc.body, GITHUB_OWNER, repo.name), 2),
        "",
      ].join("\n"),
    );
  }

  return { path: repoPath(repo.name), body: parts.join("") };
}
