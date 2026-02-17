# cook_book

TypeScript recipe service with its own `cook_book` database on the shared PostgreSQL instance. The application code lives in its [own repo](https://github.com/Einlanzerous/cook_book) — this directory is a reference for how it connects to the construct-server stack.

## Database

- **Database:** `cook_book`
- **User:** `cook_book_user`
- **Connection:** `DATABASE_URL` is injected by docker-compose

## Environment Variables

| Variable | Description |
|----------|-------------|
| `COOK_BOOK_PORT` | Host port for the service (default: 4001) |
| `COOK_BOOK_DB_PASSWORD` | Password for `cook_book_user` |

## Migration Strategy

Run `prisma migrate deploy` as a container entrypoint step before the app starts. Since cook_book has its own isolated database, there are no cross-service migration conflicts.

## Local Development

Point `DATABASE_URL` at the shared postgres started via docker compose:

```bash
export DATABASE_URL="postgres://cook_book_user:<password>@localhost:5432/cook_book?sslmode=disable"
```

> Note: To expose postgres locally, temporarily add a `ports: ["5432:5432"]` mapping to the postgres service in `docker-compose.yml`. The default configuration keeps postgres internal-only on `construct_net`.
