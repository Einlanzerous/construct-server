#!/bin/bash
set -e

# Helper: create user and database if they don't already exist.
# Usage: ensure_db <user> <password> <database>
ensure_db() {
    local user=$1 pass=$2 db=$3
    local psql_cmd="psql --username ${POSTGRES_USER:-postgres} --dbname ${POSTGRES_DB:-postgres}"

    # Refuse to touch a role when the password env var is empty/unset. Postgres
    # stores an empty password as NULL, so `ALTER ROLE ... PASSWORD ''` silently
    # BLANKS the role — every SCRAM login then fails with 28P01. This bit Purser
    # three times when db-init ran against a Postgres whose <SERVICE>_DB_PASSWORD
    # wasn't populated (e.g. a compose that predated the env line). Skipping is
    # strictly safer: an existing role keeps working; a missing one surfaces as a
    # loud "service can't connect" instead of a silently-broken auth.
    if [ -z "$pass" ]; then
        echo "ensure_db: SKIPPING '$user' — password env is empty/unset; refusing to blank the role" >&2
        return 0
    fi

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

ensure_db cook_book_user "$COOK_BOOK_DB_PASSWORD" cook_book
ensure_db switchyard_user "$SWITCHYARD_DB_PASSWORD" switchyard
ensure_db switchyard_user "$SWITCHYARD_DB_PASSWORD" switchyard_test
ensure_db centrifuge_user "$CENTRIFUGE_DB_PASSWORD" centrifuge
ensure_db argosy_user "$ARGOSY_DB_PASSWORD" argosy
ensure_db authentik_user "$AUTHENTIK_DB_PASSWORD" authentik
ensure_db lyceum_user "$LYCEUM_DB_PASSWORD" lyceum
ensure_db lyceum_user "$LYCEUM_DB_PASSWORD" lyceum_test
ensure_db purser_user "$PURSER_DB_PASSWORD" purser
