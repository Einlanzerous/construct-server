You are writing Go for a small internal HTTP service (similar to servo-signal — an MCP tool server backed by net/http).

Implement a POST `/v1/tickets` handler that:

- Accepts a JSON body: `{"title": string, "project_id": string, "priority": "low"|"medium"|"high"}`
- Validates: all three fields present and non-empty; `priority` must be one of the three values
- Inserts the ticket into a `tickets` table via a `*pgxpool.Pool` named `db` (assume it's available via a closure)
- The `tickets` table has columns: `id uuid default gen_random_uuid()`, `title text not null`, `project_id text not null`, `priority text not null`, `created_at timestamptz default now()`
- Returns:
  - `400` with `{"error": "..."}` on validation failure
  - `500` with `{"error": "..."}` on DB error
  - `201` with the full inserted row as JSON on success

Use only the standard library plus `github.com/jackc/pgx/v5` and `github.com/jackc/pgx/v5/pgxpool`. No third-party validation libraries.

Show the full handler function, the request/response types, and any helper functions. Include imports.
