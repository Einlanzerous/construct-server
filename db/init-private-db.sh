#!/bin/bash
# Bootstraps the private cluster (postgres-private, PLIM-8). Runs through
# docker-entrypoint-initdb.d, so only when the data directory is first created.
# Unlike db/init-db.sh, no deploy step runs it. It is safe to re-run by hand,
# which is also how a password rotation is applied:
#
#   docker exec -i postgres-private bash < db/init-private-db.sh
#
# Rotate in this order: `signet sync`, then a deploy that takes the full path, then
# the command above. `docker exec` sees the environment the container was created
# with, so running it before the recreate re-applies the OLD password and exits 0.
# A pin-only scoped deploy does not recreate this container.
#
# The password reaches psql through \getenv, never a command-line argument, so
# it cannot show up in `ps`.
set -euo pipefail

# Postgres stores an empty password as NULL, which silently blanks the role. On
# first init, failing here stops the cluster from coming up half-provisioned.
if [ -z "${PLIMSOLL_DB_PASSWORD:-}" ]; then
    echo "init-private-db: PLIMSOLL_DB_PASSWORD is empty; refusing to provision" >&2
    exit 1
fi

psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER:-private_admin}" --dbname postgres <<'SQL'
\getenv plimsoll_password PLIMSOLL_DB_PASSWORD

SELECT 'CREATE ROLE plimsoll'
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'plimsoll')
\gexec

ALTER ROLE plimsoll WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD :'plimsoll_password';

SELECT 'CREATE DATABASE plimsoll OWNER plimsoll'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'plimsoll')
\gexec

REVOKE ALL ON DATABASE plimsoll FROM PUBLIC;
SQL
