import { ARCHITECTURE_IR_PATH } from "../sources/architecture.ts";
import { GITHUB_OWNER, repoUrl, type Repo } from "../sources/repos.ts";
import { absolutizeLinks, code, demoteHeadings, fence, frontmatter, provenance, section, slug, table } from "../lib/md.ts";
import type { Estate } from "../model.ts";
import type { Diagram } from "./architecture.ts";
import type { Page } from "./page.ts";
import { servicePath } from "./services.ts";

export function emitRepos(estate: Estate, diagrams: Map<string, Diagram>): Page[] {
  return [repoIndex(estate), ...estate.repos.map((repo) => repoPage(estate, repo, diagrams.get(repo.name)))];
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

function repoPage(estate: Estate, repo: Repo, diagram: Diagram | undefined): Page {
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

  const architecture = architectureSection(repo, diagram);
  if (architecture) parts.push(architecture);

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

/**
 * The repo's own system map (SERV-159), rendered from the IR it commits. The
 * `<repo>_TAG` pin above says WHAT is running; this says how it is put together,
 * and each component's `SRC` chips say where that claim comes from — at the commit
 * the IR pins, so the links stay true as the code moves, and visibly go stale.
 *
 * Deliberately raw HTML rather than Markdown. The map is a page asset under
 * `public/`, not a page, so a Markdown link to it is a link VitePress cannot resolve
 * against the corpus and `ignoreDeadLinks` would fail the build over — which is the
 * right behaviour for every other internal link on the site and wrong only here.
 * An `<a>` is not a Markdown link token, so it is never checked. `iframe` and `a`
 * are both in `config.ts`'s KNOWN_TAGS, so neither gets escaped as prose.
 */
function architectureSection(repo: Repo, diagram: Diagram | undefined): string {
  const ir = repo.architecture;
  if (!ir || !diagram) return "";

  const source = `[${repo.slug}/${ARCHITECTURE_IR_PATH}](${repoUrl(repo.name)}/blob/main/${ARCHITECTURE_IR_PATH})`;

  if (!diagram.ok) {
    return section(
      "Architecture",
      [
        "::: warning MAP NOT RENDERED",
        `${repo.name} commits an architecture map, but archify refused it. Everything else on`,
        `this page is unaffected — fix the IR at ${source}.`,
        "",
        fence("text", diagram.message),
        ":::",
        "",
      ].join("\n"),
    );
  }

  const pinned = ir.repository
    ? ` Every \`SRC\` chip resolves at [\`${ir.repository.revision.slice(0, 7)}\`](${repoUrl(repo.name)}/commit/${ir.repository.revision}), the commit the map is pinned to.`
    : "";

  return section(
    "Architecture",
    [
      `*Rendered from ${source}. Edit it there.*${pinned}`,
      "",
      `<iframe src="${diagram.href}" title="${repo.name} architecture" loading="lazy" style="width:100%;height:70vh;min-height:520px;border:1px solid var(--vp-c-divider);border-radius:8px"></iframe>`,
      "",
      `<a href="${diagram.href}" target="_blank" rel="noreferrer">Open the map full screen &#8599;</a>`,
      "",
    ].join("\n"),
  );
}
