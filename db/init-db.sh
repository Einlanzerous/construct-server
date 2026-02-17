#!/bin/bash
set -e

# Helper: create user and database if they don't already exist.
# Usage: ensure_db <user> <password> <database>
ensure_db() {
    local user=$1 pass=$2 db=$3

    psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
        DO \$\$
        BEGIN
            IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '$user') THEN
                CREATE ROLE $user WITH LOGIN PASSWORD '$pass';
            ELSE
                ALTER ROLE $user WITH PASSWORD '$pass';
            END IF;
        END
        \$\$;
EOSQL

    # CREATE DATABASE cannot run inside a DO block, so check separately
    local db_exists
    db_exists=$(psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" -tAc "SELECT 1 FROM pg_database WHERE datname = '$db'")
    if [ "$db_exists" != "1" ]; then
        psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" -c "CREATE DATABASE $db OWNER $user;"
    fi

    psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" -c "GRANT ALL PRIVILEGES ON DATABASE $db TO $user;"
}

ensure_db vox_loop_user "$VOX_LOOP_DB_PASSWORD" vox_loop
ensure_db cook_book_user "$COOK_BOOK_DB_PASSWORD" cook_book
ensure_db syncv3_user "$SYNCV3_DB_PASSWORD" syncv3
