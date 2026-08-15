// VitePress config. This is the ONLY hand-maintained file under docs/ — everything
// else in this directory is generated and wiped on each run (see wiki/generate).
//
// The sidebar is generated alongside the pages so navigation cannot go stale
// relative to what exists; this file just imports it.

import { defineConfig } from "vitepress";
import { withMermaid } from "vitepress-plugin-mermaid";

import sidebar from "./sidebar.json" with { type: "json" };

export default withMermaid(
  defineConfig({
    title: "The Imperial Construct",
    description: "Generated operations wiki for the Construct estate",
    lang: "en-GB",

    // The site is served from the root of its own hostname behind the tunnel.
    base: "/",

    // A broken internal link means the generator emitted a path it did not write —
    // a bug worth failing the build over, not something to route around at render
    // time. `localhostLinks` narrows the exemption to exactly one case: an ingested
    // README that mentions its own dev server (`http://localhost:5173`). That is
    // correct content, and it is not the wiki's business to police it.
    ignoreDeadLinks: "localhostLinks",

    // Off deliberately. VitePress derives "last updated" from each page's git
    // history, and these pages have none — they are generated into a gitignored
    // directory, so every timestamp would be empty. It also shells out to git,
    // which the build container does not have. The build stamp on the home page is
    // the honest answer to "how current is this": it names the commit the wiki was
    // generated from.
    lastUpdated: false,
    cleanUrls: true,

    markdown: {
      // VitePress compiles every Markdown page as a Vue template, so `{{ … }}`
      // anywhere on a page is a Vue interpolation — and this wiki ingests documents
      // written for GitHub, where `${{ secrets.* }}` is ordinary prose. Left alone,
      // any repo whose README mentions Actions syntax fails the build with an
      // "Error parsing JavaScript expression" pointing at a line the generator
      // faithfully copied.
      //
      // Fixed here rather than by escaping in the generator, because the generator
      // has no business rewriting the text of a document it is reproducing verbatim,
      // and because the hazard is a property of the renderer: any content added later
      // gets the same protection for free. Fenced code blocks are already wrapped in
      // v-pre by VitePress itself; these two rules close the remaining paths.
      config(md) {
        const inlineCode = md.renderer.rules.code_inline;
        md.renderer.rules.code_inline = (tokens, idx, options, env, self) => {
          const html = inlineCode
            ? inlineCode(tokens, idx, options, env, self)
            : self.renderToken(tokens, idx, options);
          return html.replace(/^<code(\s|>)/, "<code v-pre$1");
        };

        // Prose. `text` tokens are plain content by construction — code spans and
        // fences arrive as their own token types — so escaping braces here cannot
        // touch a code sample. The entities render as the literal characters.
        const text = md.renderer.rules.text;
        md.renderer.rules.text = (tokens, idx, options, env, self) => {
          const html = text
            ? text(tokens, idx, options, env, self)
            : self.renderToken(tokens, idx, options);
          return html.replace(/\{\{/g, "&#123;&#123;").replace(/\}\}/g, "&#125;&#125;");
        };
      },
    },

    themeConfig: {
      sidebar,
      outline: [2, 3],

      nav: [
        { text: "Services", link: "/services/" },
        { text: "Versions", link: "/versions" },
        { text: "Repos", link: "/repos/" },
        { text: "Reference", link: "/reference/" },
      ],

      search: {
        // Local search is a build-time index with no external service — which is the
        // whole reason a static site was preferred over a wiki app here. If this
        // proves inadequate the answer is a better index, not a stateful wiki.
        provider: "local",
      },

      socialLinks: [{ icon: "github", link: "https://github.com/Einlanzerous/construct-server" }],

      footer: {
        message: "Generated from the stack definition. Edits here are overwritten on the next deploy.",
        copyright: "Zero Gravity Industries",
      },
    },
  }),
);
