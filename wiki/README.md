# wiki/ — the generated estate wiki (SERV-101)

Reads the stack definition and the estate's repo docs, emits Markdown, renders it
with VitePress. Served at `wiki.zerogravity.industries` behind Cloudflare Access.

**The design of record is [`docs/estate-wiki.md`](../docs/estate-wiki.md).** Read it
before changing anything here — it holds the reasoning this file only summarises.

## Three things to know before you edit

1. **`docs/` is generated and wiped on every run.** A file you put there by hand is
   gone at the next build. `docs/.vitepress/config.ts` is the sole exception.
2. **Never make the generator read a resolved compose model or a `.env`.** It parses
   raw YAML precisely so that no secret is ever in scope. Env tables show variable
   names, not values.
3. **Comments are content.** The compose file's prose is the best documentation in
   it; the parser lifts comments onto the service and env-var they precede. A
   change that drops them makes the wiki much worse.

## Commands

Run these from the repo root:

```bash
make wiki-fetch-local   # cache repo docs from ~/projects (fast, no token)
make wiki-fetch         # cache them from GitHub (needs WIKI_DOCS_TOKEN)
make wiki-generate      # emit the Markdown corpus only — the fast inner loop
make wiki-serve         # hot-reloading preview on http://localhost:5173
make wiki-build         # full static build, exactly as deploy.yml does it
```

Or directly, from this directory: `npm run fetch:local`, `npm run generate`,
`npm run dev`, `npm run build`, `npm run typecheck`.

## Where things live

| Path | What it does |
|---|---|
| `generate/index.ts` | entry point: wipes `docs/`, writes the corpus and the sidebar |
| `generate/fetch.ts` | fills `.repo-docs/` from the GitHub API, or `~/projects` with `--local` |
| `generate/model.ts` | assembles the sources into one model; nothing downstream reads a file |
| `generate/sources/` | `compose.ts`, `versions.ts`, `repos.ts` — parsing |
| `generate/emit/` | one module per page family — rendering |
| `generate/lib/md.ts` | Markdown helpers, including the escaping the renderer needs |
| `docs/.vitepress/config.ts` | VitePress config; imports the generated sidebar |

## Adding a page family

Write an emitter in `emit/` returning `Page[]`, add it to the list in
`generate/index.ts`, and add its entry to `emit/sidebar.ts`. Prefer deriving the
page set from the model over hardcoding it — the reason a new service already
appears everywhere without an edit.

## Ingesting Markdown you did not write is hostile

Three failure modes cost a build each while this was built, and all three are
handled now. If you add a new ingestion path, you inherit them:

- **`{{ … }}` is a Vue interpolation.** VitePress compiles every page as a Vue
  template, and `${{ secrets.* }}` is ordinary prose in a GitHub-facing README.
  Handled globally in `config.ts` by adding `v-pre` to inline code and escaping
  braces in text nodes.
- **Relative links resolve against the wrong repo.** `![logo](assets/x.svg)` in
  another repo's README means that file *there*; left alone Vite tries to bundle it
  and fails the build. `absolutizeLinks()` rewrites them to GitHub, covering
  `src`, `href`, `srcset` and `poster`.
- **`<KEY>-<NUM>` in a comment is an unclosed HTML tag.** `prose()` escapes angle
  brackets outside backtick spans.
