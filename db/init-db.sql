-- init-db.sql
-- Runs once when the postgres data volume is first initialized.
-- Passwords are passed in as environment variables by Docker Compose.

-- vox_loop
CREATE USER vox_loop_user WITH PASSWORD :'VOX_LOOP_DB_PASSWORD';
CREATE DATABASE vox_loop OWNER vox_loop_user;
GRANT ALL PRIVILEGES ON DATABASE vox_loop TO vox_loop_user;

-- cook_book
CREATE USER cook_book_user WITH PASSWORD :'COOK_BOOK_DB_PASSWORD';
CREATE DATABASE cook_book OWNER cook_book_user;
GRANT ALL PRIVILEGES ON DATABASE cook_book TO cook_book_user;
