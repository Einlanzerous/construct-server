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

# Helper: take a database off the PUBLIC grant.
# Usage: revoke_public <database>
#
# ensure_db never revokes PUBLIC, and a database created from template1 inherits
# PUBLIC's TEMP + CONNECT. That is why switchyard, switchyard_test and lyceum all
# carry `=Tc/owner` today. Chronicle and ASR were provisioned by hand and made
# deliberately tighter than the helper: owner only, PUBLIC revoked.
#
# So this is not a hardening pass — it is what keeps porting them into this script
# from silently LOOSENING them on the next rebuild. Without it, the first rebuilt
# data directory hands PUBLIC connect rights on the database holding the estate's
# authored corpus, and nothing that currently runs would notice: database-level
# ACLs never appear in a schema dump, so chronicle/schema.sql and its migration
# staleness guard cannot see them.
#
# Deliberately NOT applied to the ten databases above. Their PUBLIC grant is the
# state they are in today; changing it is a separate decision with its own blast
# radius, and this ticket is about recreating what exists, not re-grading it.
#
# Skipped when the database does not exist, so an ensure_db that bailed on an
# empty password does not become a hard failure under `set -e`.
revoke_public() {
    local db=$1
    local psql_cmd="psql --username ${POSTGRES_USER:-postgres} --dbname ${POSTGRES_DB:-postgres}"

    if ! $psql_cmd -tAc "SELECT 1 FROM pg_database WHERE datname = '$db'" | grep -q 1; then
        echo "revoke_public: SKIPPING '$db' — database does not exist" >&2
        return 0
    fi

    $psql_cmd -c "REVOKE ALL ON DATABASE $db FROM PUBLIC;"
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
ensure_db interlock_user "$INTERLOCK_DB_PASSWORD" interlock
ensure_db amber_user "$AMBER_DB_PASSWORD" amber
ensure_db placard_user "$PLACARD_DB_PASSWORD" placard
ensure_db placard_user "$PLACARD_DB_PASSWORD" placard_test

# --- Chronicle and ASR (SERV-169) ---
#
# These four lines are RECREATION, not first-boot convenience. Both services were
# provisioned by hand and appeared nowhere in this file, so every other service on
# the box came back from a rebuilt data directory and these two silently did not.
#
# THE ROLE NAMES ARE BARE ON PURPOSE — `chronicle` and `asr`, not `<service>_user`
# like every role above. Do not "fix" them. The names are load-bearing in
# CHRONICLE_DATABASE_URL and ASR_DATABASE_URL in docker-compose.yml and in the
# Signet targets behind them; renaming the role without rewriting all of those
# locks both services out of their own data.
#
# asr_test has never existed. chronicle/verify.sh assembles ASR_TEST_DATABASE_URL
# from ASR_DB_PASSWORD, so supplying that secret today turns a clean skip into
# ~10 failures reading `FATAL: database "asr_test" does not exist`. One line ends
# that permanently.
#
# NOTHING HERE MAY TOUCH chronicle_tier1, AND THIS SCRIPT MUST NOT CREATE IT.
# That role is CHRN-52's — one of Chronicle's five full-diff tickets — and it needs
# a shape ensure_db cannot express: LOGIN with CONNECT and nothing else, its schema
# and table grants coming from Chronicle's own migrations, where the tier doctrine
# is tested. Running it through ensure_db would reach the unconditional
# `GRANT ALL PRIVILEGES ON DATABASE` above, re-applied on EVERY deploy, turning the
# deliberate `c` into `CTc` — CREATE on the tier-2 database for the very role the
# tier split exists to keep out, silently undoing any manual revoke. Chronicle's
# TestTier1RoleCannotReachCredentials asserts TABLE access and would stay green.
#
# SEQUENCING: chronicle/migrations/0001_init.up.sql:46 grants to chronicle_tier1
# unconditionally. On a rebuilt data directory with this landed and CHRN-52 not,
# Chronicle's first migration raises `role "chronicle_tier1" does not exist` and the
# service does not boot. That is not worse than today — nothing recreates anything
# today — but it is partial provisioning that LOOKS complete. See SERV-169.
ensure_db chronicle "$CHRONICLE_DB_PASSWORD" chronicle
ensure_db chronicle "$CHRONICLE_DB_PASSWORD" chronicle_test
ensure_db asr "$ASR_DB_PASSWORD" asr
ensure_db asr "$ASR_DB_PASSWORD" asr_test

revoke_public chronicle
revoke_public chronicle_test
revoke_public asr
revoke_public asr_test
