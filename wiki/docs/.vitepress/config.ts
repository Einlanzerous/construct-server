// VitePress config. This is the ONLY hand-maintained file under docs/ — everything
// else in this directory is generated and wiped on each run (see wiki/generate).
//
// The sidebar is generated alongside the pages so navigation cannot go stale
// relative to what exists; this file just imports it.

import { defineConfig } from "vitepress";
import { withMermaid } from "vitepress-plugin-mermaid";

import sidebar from "./sidebar.json" with { type: "json" };

/**
 * Element names a reproduced document may legitimately use. Anything outside this
 * set is treated as prose and escaped — see the html_inline rule below. Erring
 * toward escaping is the safe direction: a mis-escaped tag renders as visible text,
 * while a mis-passed one fails the whole build.
 */
const KNOWN_TAGS = new Set([
  // HTML
  "a", "abbr", "address", "area", "article", "aside", "audio", "b", "base", "bdi",
  "bdo", "blockquote", "body", "br", "button", "canvas", "caption", "cite", "code",
  "col", "colgroup", "data", "datalist", "dd", "del", "details", "dfn", "dialog",
  "div", "dl", "dt", "em", "embed", "fieldset", "figcaption", "figure", "footer",
  "form", "h1", "h2", "h3", "h4", "h5", "h6", "head", "header", "hgroup", "hr",
  "html", "i", "iframe", "img", "input", "ins", "kbd", "label", "legend", "li",
  "link", "main", "map", "mark", "menu", "meta", "meter", "nav", "noscript",
  "object", "ol", "optgroup", "option", "output", "p", "param", "picture", "pre",
  "progress", "q", "rp", "rt", "ruby", "s", "samp", "script", "section", "select",
  "slot", "small", "source", "span", "strong", "style", "sub", "summary", "sup",
  "table", "tbody", "td", "template", "textarea", "tfoot", "th", "thead", "time",
  "title", "tr", "track", "u", "ul", "var", "video", "wbr",
  // SVG, which READMEs use for badges and light/dark artwork
  "svg", "path", "circle", "rect", "line", "polyline", "polygon", "ellipse", "g",
  "defs", "use", "symbol", "text", "tspan", "lineargradient", "radialgradient",
  "stop", "clippath", "mask", "pattern", "filter", "image", "marker", "desc",
]);

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

        // Placeholders written in angle brackets. `<your-token>` and `<NUM>` are
        // ordinary prose in a README and valid custom-element syntax to Vue, which
        // then fails the build demanding a close tag. markdown-it hands them over as
        // raw HTML, so this is where they can be told apart from the HTML a README
        // genuinely means — `<picture>`, `<img>`, `<details>` — which must keep
        // working, and which the link rewriter in the generator depends on.
        //
        // Escaping cannot happen in the generator: an ingested document is Markdown,
        // where real HTML is legitimate. Only here is the tag name known.
        const escapeUnknownTags = (html: string): string =>
          html.replace(/<\/?([A-Za-z][A-Za-z0-9-]*)(\s[^>]*?)?\/?>/g, (match, name: string) =>
            KNOWN_TAGS.has(name.toLowerCase())
              ? match
              : match.replace(/</g, "&lt;").replace(/>/g, "&gt;"),
          );

        for (const rule of ["html_inline", "html_block"] as const) {
          const inner = md.renderer.rules[rule];
          md.renderer.rules[rule] = (tokens, idx, options, env, self) => {
            const html = inner
              ? inner(tokens, idx, options, env, self)
              : self.renderToken(tokens, idx, options);
            return escapeUnknownTags(html);
          };
        }
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
