// The VitePress sidebar, generated alongside the pages so navigation cannot go
// stale relative to what exists. `.vitepress/config.ts` imports the JSON this
// produces and stays static.

import type { Estate } from "../model.ts";
import { referencePath } from "./reference.ts";
import { repoPath } from "./repos.ts";
import { servicePath } from "./services.ts";
import { groupBySection } from "../model.ts";
import { humanise } from "../sources/compose.ts";

export interface SidebarItem {
  text: string;
  link?: string;
  items?: SidebarItem[];
  collapsed?: boolean;
}

export function buildSidebar(estate: Estate): SidebarItem[] {
  const items: SidebarItem[] = [
    { text: "Overview", link: "/" },
    { text: "Deployed versions", link: "/versions" },
    {
      text: "Topology",
      items: [
        { text: "Host exposure", link: "/topology/exposure" },
        { text: "Networks", link: "/topology/networks" },
        { text: "Startup dependencies", link: "/topology/dependencies" },
      ],
    },
    {
      text: "Services",
      link: "/services/",
      collapsed: false,
      // Labels, not banners: the label is the banner with its ticket keys and
      // description stripped (SERV-186). Those stay on /services/, under the heading.
      items: groupBySection(estate.prod.services).map((group) => ({
        text: group.label,
        collapsed: true,
        items: group.services.map((svc) => ({ text: svc.displayName, link: `/${servicePath(svc.name)}` })),
      })),
    },
    {
      text: "Repositories",
      link: "/repos/",
      collapsed: true,
      items: estate.repos.map((repo) => ({ text: humanise(repo.name), link: `/${repoPath(repo.name)}` })),
    },
    {
      text: "Reference",
      link: "/reference/",
      collapsed: true,
      items: estate.reference.map((doc) => ({ text: doc.title, link: `/${referencePath(doc.path)}` })),
    },
  ];

  if (estate.dev) items.splice(2, 0, { text: "Dev tier", link: "/dev" });

  return items;
}
