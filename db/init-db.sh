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
# chronicle_tier1 — Chronicle's SECOND role — is provisioned BELOW, in its own
# block, and deliberately not through ensure_db. See there (SERV-182 / CHRN-52).
ensure_db chronicle "$CHRONICLE_DB_PASSWORD" chronicle
ensure_db chronicle "$CHRONICLE_DB_PASSWORD" chronicle_test
ensure_db asr "$ASR_DB_PASSWORD" asr
ensure_db asr "$ASR_DB_PASSWORD" asr_test

revoke_public chronicle
revoke_public chronicle_test
revoke_public asr
revoke_public asr_test

# --- chronicle_tier1 (CHRN-52 / SERV-182) ---
#
# Chronicle's SECOND role: the one derived work (the Scribe today, tier-1 reads
# next) connects as. Its whole point is to hold LESS than `chronicle` — here,
# CONNECT on the database and nothing else. Its schema and table grants come
# from Chronicle's own migrations (0001 for tier1, 0007 for two tier-2 reads),
# where the tier doctrine is tested; this script gives it a way in and no more.
#
# NEVER ensure_db FOR THIS ROLE. ensure_db ends in an unconditional
# `GRANT ALL PRIVILEGES ON DATABASE`, re-applied every deploy, which would turn
# the deliberate `c` into `CTc` — CREATE on the tier-2 database for the very role
# the tier split exists to keep out. Chronicle's boot audit (CHRN-52) would then
# refuse to serve, correctly, and the deploy gate that runs `chronicle
# tier1-audit` would go red. This block is what keeps that from being how
# anyone finds out.
#
# These statements MIRROR chronicle/deploy/tier1-role.sql — the single
# definition Chronicle's provision-db.sh and its CI apply. Change them together.
# The audit running under chronicle/verify.sh against chronicle_test, which THIS
# script provisions, is what catches the two drifting.
#
# Same empty-password guard as ensure_db, for the same reason: an unset
# CHRONICLE_TIER1_DB_PASSWORD must skip loudly, never blank the role.
#
# WHAT A RE-RUN PUTS BACK, exactly: the five privilege attributes (superuser,
# createdb, createrole, replication, bypassrls — each stated NO rather than left
# to the default), LOGIN, the password, and the database-level ACL. NOT role
# memberships: a hand-issued `GRANT chronicle TO chronicle_tier1` survives this
# block. Chronicle's boot audit checks pg_auth_members and refuses to serve on
# any membership, so that escalation is caught at the next boot and by the
# deploy gate; it is not silently undone here.
#
# SEQUENCING, stated so a rebuild's log reads as expected rather than broken:
# deploy.yml runs this script AFTER `up -d`, and chronicle/migrations/0001 grants
# to chronicle_tier1 unconditionally. So on a rebuilt data directory Chronicle
# boots once against a cluster without the role, fails migration 0001 with
# `role "chronicle_tier1" does not exist`, this block then creates it, and
# `restart: unless-stopped` brings Chronicle up clean on the next cycle. One
# crash cycle, by construction — not a fault to chase.
ensure_chronicle_tier1() {
    local pass=$1; shift
    local psql_cmd="psql --username ${POSTGRES_USER:-postgres} --dbname ${POSTGRES_DB:-postgres}"

    if [ -z "$pass" ]; then
        echo "ensure_chronicle_tier1: SKIPPING — CHRONICLE_TIER1_DB_PASSWORD is empty/unset; refusing to blank the role" >&2
        return 0
    fi

    local attrs="LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS"
    if $psql_cmd -tAc "SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'chronicle_tier1'" | grep -q 1; then
        $psql_cmd -c "ALTER ROLE chronicle_tier1 WITH $attrs PASSWORD '$pass';"
    else
        $psql_cmd -c "CREATE ROLE chronicle_tier1 WITH $attrs PASSWORD '$pass';"
    fi

    # Per database: CONNECT and nothing else, and no way into schema public
    # (PUBLIC keeps USAGE there by default; Postgres 15 dropped only CREATE).
    # Skipped when the database does not exist, so an ensure_db that bailed on
    # an empty password does not become a hard failure under `set -e`.
    local db
    for db in "$@"; do
        if ! $psql_cmd -tAc "SELECT 1 FROM pg_database WHERE datname = '$db'" | grep -q 1; then
            echo "ensure_chronicle_tier1: SKIPPING '$db' — database does not exist" >&2
            continue
        fi
        $psql_cmd -c "REVOKE ALL ON DATABASE $db FROM chronicle_tier1;"
        $psql_cmd -c "GRANT CONNECT ON DATABASE $db TO chronicle_tier1;"
        # -v ON_ERROR_STOP=1 because this is the one call in the file with two -c
        # flags: without it psql runs on past a failed first statement and exits
        # with the LAST statement's status, so `set -e` would not fire and a
        # deploy could go green having left PUBLIC with USAGE on the schema.
        psql --username "${POSTGRES_USER:-postgres}" --dbname "$db" -v ON_ERROR_STOP=1 \
            -c "REVOKE ALL ON SCHEMA public FROM PUBLIC;" \
            -c "REVOKE ALL ON SCHEMA public FROM chronicle_tier1;"
    done
}

ensure_chronicle_tier1 "$CHRONICLE_TIER1_DB_PASSWORD" chronicle chronicle_test
