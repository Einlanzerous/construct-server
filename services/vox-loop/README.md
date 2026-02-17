# vox-loop

Go service with its own `vox_loop` database on the shared PostgreSQL instance. The application code lives in its own repo — this directory is a reference for how it connects to the construct-server stack.

## Database

- **Database:** `vox_loop`
- **User:** `vox_loop_user`
- **Connection:** `DATABASE_URL` is injected by docker-compose

## Migration Strategy

Use [golang-migrate/migrate](https://github.com/golang-migrate/migrate) with SQL file-based migrations. Call `migrate.Up()` on startup before serving traffic. Since vox-loop has its own isolated database, there are no cross-service migration conflicts.

## Local Development

Point `DATABASE_URL` at the shared postgres started via docker compose:

```bash
export DATABASE_URL="postgres://vox_loop_user:<password>@localhost:5432/vox_loop?sslmode=disable"
```

> Note: To expose postgres locally, temporarily add a `ports: ["5432:5432"]` mapping to the postgres service in `docker-compose.yml`. The default configuration keeps postgres internal-only on `construct_net`.
