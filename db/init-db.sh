#!/bin/bash
set -e

# Helper: create user and database if they don't already exist.
# Usage: ensure_db <user> <password> <database>
ensure_db() {
    local user=$1 pass=$2 db=$3
    local psql_cmd="psql --username $POSTGRES_USER --dbname $POSTGRES_DB"

    # Create or update role
    if $psql_cmd -tAc "SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = '$user'" | grep -q 1; then
        $psql_cmd -c "ALTER ROLE $user WITH PASSWORD '$pass';"
    else
        $psql_cmd -c "CREATE ROLE $user WITH LOGIN PASSWORD '$pass';"
    fi

    # Create database if missing
    if ! $psql_cmd -tAc "SELECT 1 FROM pg_database WHERE datname = '$db'" | grep -q 1; then
        $psql_cmd -c "CREATE DATABASE $db OWNER $user;"
    fi

    $psql_cmd -c "GRANT ALL PRIVILEGES ON DATABASE $db TO $user;"
}

ensure_db vox_loop_user "$VOX_LOOP_DB_PASSWORD" vox_loop
ensure_db cook_book_user "$COOK_BOOK_DB_PASSWORD" cook_book
ensure_db syncv3_user "$SYNCV3_DB_PASSWORD" syncv3
