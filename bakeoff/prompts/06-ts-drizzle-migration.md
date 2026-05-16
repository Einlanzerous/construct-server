You're extending Switchyard's `tickets` table (Drizzle ORM on Postgres). Add a `priority` column.

Requirements:

1. **Schema update** — `server/src/db/schema/tickets.ts`: add a `priority` column to the existing `tickets` table:
   - Backed by a Postgres enum type called `ticket_priority` with values: `low`, `medium`, `high`
   - NOT NULL, DEFAULT `medium`
   - Use `pgEnum` from `drizzle-orm/pg-core`

2. **Migration SQL** — generate the SQL file Drizzle would produce under `server/src/db/migrations/0007_add_ticket_priority.sql`:
   - Create the enum type
   - Add the column with the default
   - Idempotent if possible (no harm running it twice)
   - Backfill is not needed (the default covers existing rows)

3. **Updated TypeScript type** — show the resulting `Ticket` type that other code imports from this schema file (the type Drizzle infers from `tickets.$inferSelect`).

4. **Production concerns** — 2-3 sentences on what could go wrong applying this migration to a table with millions of existing rows under live write load. Be specific about Postgres locking behavior.

Show the existing `tickets` table schema as you imagine it (id, title, description, project_id, created_at — pick reasonable types) plus the additions; don't just hand back a diff fragment.
