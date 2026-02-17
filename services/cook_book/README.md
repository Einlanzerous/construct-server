# cook_book

TypeScript service with its own `cook_book` database on the shared PostgreSQL instance. The application code lives in its own repo — this directory is a reference for how it connects to the construct-server stack.

## Database

- **Database:** `cook_book`
- **User:** `cook_book_user`
- **Connection:** `DATABASE_URL` is injected by docker-compose

## Migration Strategy

Run `prisma migrate deploy` as a container entrypoint step before the app starts. Since cook_book has its own isolated database, there are no cross-service migration conflicts.

## Local Development

Point `DATABASE_URL` at the shared postgres started via docker compose:

```bash
export DATABASE_URL="postgres://cook_book_user:<password>@localhost:5432/cook_book?sslmode=disable"
```

> Note: To expose postgres locally, temporarily add a `ports: ["5432:5432"]` mapping to the postgres service in `docker-compose.yml`. The default configuration keeps postgres internal-only on `construct_net`.
