# wiki/

The generated estate wiki (SERV-101): a TypeScript generator plus a VitePress renderer.
Design of record: `docs/estate-wiki.md`. Rationale for the rules below is in its
"Generator rules" section.

- `wiki/docs/` is generated and wiped on every run. Never hand-write a page there; a
  repo's system map is authored in that repo as `docs/architecture.archify.json`.
- **The generator must never read a resolved environment.** It parses the raw
  `docker-compose.yml`, never `docker compose config` or a `.env`, so no secret from
  `PROD_ENV_FILE` can reach a Markdown page. Env tables show names only.
- Build in a container (`make wiki-build`), not on host node. The build image is `node:22`,
  not `node:22-alpine` (archify needs git).
- A map can never fail the build: failures become a warning block on that repo's page.
- The corpus is also a deployed artefact (`wiki.yml` publishes it; chronicle mounts it
  read-only), so a generator change is a production change.
