#!/bin/bash
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE USER vox_loop_user WITH PASSWORD '$VOX_LOOP_DB_PASSWORD';
    CREATE DATABASE vox_loop OWNER vox_loop_user;
    GRANT ALL PRIVILEGES ON DATABASE vox_loop TO vox_loop_user;

    CREATE USER cook_book_user WITH PASSWORD '$COOK_BOOK_DB_PASSWORD';
    CREATE DATABASE cook_book OWNER cook_book_user;
    GRANT ALL PRIVILEGES ON DATABASE cook_book TO cook_book_user;
EOSQL
