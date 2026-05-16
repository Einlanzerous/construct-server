You're working on Switchyard's backend (Hono + Bun + Drizzle on Postgres). Write a complete Hono route handler for `POST /v1/tickets` in a file at `server/src/routes/tickets.ts`.

Requirements:

- Validate the JSON body with Zod:
  - `title`: string, 3-200 chars, required
  - `description`: string, optional, max 5000 chars
  - `project_id`: UUID format, required
  - `priority`: enum `"low" | "medium" | "high"`, defaults to `"medium"`
- Call an existing service function: `await createTicket(input)` — returns `Promise<Ticket>`. Both `Ticket` and `createTicket` are exported from `../services/tickets.ts`.
- On success: `201` with the created ticket as JSON.
- On validation failure: `400` with `{ error: "validation_failed", details: <flattened zod issues> }`.
- On unexpected error: let it propagate (a global error handler exists elsewhere).
- Use Hono's `zValidator` middleware from `@hono/zod-validator`.
- Use Hono's typed `c.json()` correctly so the response is type-checked.

Show the full route file as it would appear in `server/src/routes/tickets.ts`, including imports. Then briefly (1-2 sentences) describe how this route would be mounted on the main app (e.g. `app.route('/v1', ticketsRoute)`).
