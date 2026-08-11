.PHONY: network up down recreate force-recreate drift-check db-up db-shell db-check db-init deploy-root \
        dev-root dev-network dev-bootstrap dev-up dev-down dev-recreate dev-pull dev-ps dev-logs \
        dev-db-init dev-db-shell dev-parity dev-verify-isolation

# The live stack is deployed from a fixed path, not from whatever checkout you
# happen to be standing in (SERV-76). Every target below targets that path
# explicitly, so `make recreate svc=x` acts on the running stack from anywhere —
# including from a working copy whose docker-compose.yml you have edited but not
# yet deployed. That is deliberate: the deploy root is what is live, and pushing
# to main is what changes it.
#
# Override for a non-standard host: make recreate svc=argosy DEPLOY_ROOT=/srv/cs
DEPLOY_ROOT ?= /opt/construct-server
COMPOSE = docker compose -f $(DEPLOY_ROOT)/docker-compose.yml --project-directory $(DEPLOY_ROOT)

# Fail with a useful message rather than compose's "no configuration file provided".
deploy-root:
	@test -f "$(DEPLOY_ROOT)/docker-compose.yml" || { \
	  echo "No docker-compose.yml at DEPLOY_ROOT=$(DEPLOY_ROOT)."; \
	  echo "The stack deploys from a fixed path (SERV-76). Bootstrap the host with"; \
	  echo "  ansible-playbook ansible/site.yml"; \
	  echo "or point this at another root: make <target> DEPLOY_ROOT=/path/to/root"; \
	  exit 1; \
	}

# Scope a single-service action to that service (SERV-63). Compose otherwise reaches
# into `depends_on`, so an action aimed at one container can recreate the shared
# postgres and bounce every service on the box. Only applies when svc= is named;
# pass deps=1 for a genuine cold start, where the dependencies do need to come up.
# 0/no/false are treated as "keep it scoped" — Make's $(if) is a non-empty test, so
# without filtering them out `deps=0` would read as "yes, bring dependencies up".
# DEPS_ON is the single truthiness test, so every target agrees on what deps= means.
DEPS_ON = $(filter-out 0 no false,$(deps))
NO_DEPS = $(if $(svc),$(if $(DEPS_ON),,--no-deps))

# Create the construct_net Docker bridge network (required before starting the stack)
network:
	docker network create construct_net 2>/dev/null || echo "construct_net already exists"

# Start the full stack
up: deploy-root network
	$(COMPOSE) up -d

# Stop the full stack
down: deploy-root
	$(COMPOSE) down

# Recreate service(s) so docker-compose.yml edits (mounts/env/image) take effect.
# ALWAYS use this after editing the compose — NEVER `docker restart`, which silently
# keeps the old container spec (see SERV-8 / the /media-ssd drift incident).
# Usage: make recreate                   (recreate any drifted service across the stack)
#        make recreate svc=argosy        (recreate a single service, and only that one)
#        make recreate svc=argosy deps=1 (cold start: bring its dependencies up too)
recreate: deploy-root network
	$(COMPOSE) up -d $(NO_DEPS) $(svc)

# Recreate a container whose spec did NOT change — e.g. to re-read an env_file whose
# contents changed but whose path didn't, which compose does not always see as drift.
# Always scoped: --force-recreate is the flag that propagates into depends_on, so this
# target hardcodes --no-deps and accepts neither an empty svc= nor deps=. Both would
# reconstruct the SERV-63 command, which force-recreated the shared postgres.
# Usage: make force-recreate svc=purser
force-recreate: deploy-root network
	@test -n "$(svc)" || { \
	  echo "force-recreate requires svc=<name> — unscoped, it would recreate every container in the stack."; \
	  echo "To rebuild the whole stack deliberately: docker compose up -d --force-recreate"; \
	  exit 1; \
	}
	@test -z "$(DEPS_ON)" || { \
	  echo "force-recreate does not accept deps= — it would force-recreate every dependency of"; \
	  echo "$(svc), including the shared postgres. That is the SERV-63 command verbatim."; \
	  echo "For a cold start, bring dependencies up unforced: make recreate svc=$(svc) deps=1"; \
	  exit 1; \
	}
	$(COMPOSE) up -d --no-deps --force-recreate $(svc)

# Detect containers running a stale spec vs docker-compose.yml (SERV-8 guardrail).
# Usage: make drift-check            (check every service)
#        make drift-check svc=argosy (check a single service)
drift-check:
	DEPLOY_ROOT=$(DEPLOY_ROOT) ./scripts/check-compose-drift.sh $(svc)

# Start only the postgres service
db-up: deploy-root network
	$(COMPOSE) up -d postgres

# Open a psql shell to the running postgres container
db-shell: deploy-root
	$(COMPOSE) exec postgres psql -U postgres

# Run init-db.sh against a running postgres (idempotent — safe to re-run)
db-init: deploy-root
	$(COMPOSE) exec postgres bash /docker-entrypoint-initdb.d/init-db.sh

# Verify databases and users were created correctly
db-check: deploy-root
	@echo "=== Databases ==="
	@$(COMPOSE) exec postgres psql -U postgres -c "\l" | grep -E "cook_book|switchyard"
	@echo ""
	@echo "=== User access: cook_book ==="
	@$(COMPOSE) exec postgres psql -U cook_book_user -d cook_book -c "SELECT 1 AS connected;"
	@echo "=== User access: switchyard ==="
	@$(COMPOSE) exec postgres psql -U switchyard_user -d switchyard -c "SELECT 1 AS connected;"

# ============================================================================
# DEV ENVIRONMENT (SERV-77) — the `construct-server-dev` compose project
# ============================================================================
# Dev is a SEPARATE compose project with its own network, its own Postgres and
# its own deploy root. Every target below pins the project name, the compose file
# and the env file together, because getting any one of them wrong is precisely
# how dev and prod get confused for each other — and a bare `docker compose` in
# this repo resolves to the PROD file. Prefer these targets; do not hand-roll it.
#
# The dev secrets come from DEV_ENV_FILE (GitHub Environment `home-server-dev`),
# materialised at $(DEV_ROOT)/.env. Never point dev at the prod .env: SERV-77 is
# explicit about that, and a dev Purser holding prod credentials would provision
# real accounts in real services.
DEV_ROOT ?= /opt/construct-server-dev
DEV_PROJECT = construct-server-dev
DEV_COMPOSE = docker compose -p $(DEV_PROJECT) -f $(DEV_ROOT)/docker-compose.dev.yml \
              --project-directory $(DEV_ROOT) --env-file $(DEV_ROOT)/.env

dev-root:
	@test -f "$(DEV_ROOT)/docker-compose.dev.yml" || { \
	  echo "No docker-compose.dev.yml at DEV_ROOT=$(DEV_ROOT)."; \
	  echo "Bootstrap the dev root first:  make dev-bootstrap"; \
	  exit 1; \
	}
	@test -f "$(DEV_ROOT)/.env" || { \
	  echo "No .env at DEV_ROOT=$(DEV_ROOT) — dev has no secrets to start with."; \
	  echo "Materialise it from the DEV_ENV_FILE environment secret, or for a"; \
	  echo "local-only dev run copy .env.dev.example there and fill it in."; \
	  echo "Do NOT copy the prod .env (SERV-77)."; \
	  exit 1; \
	}

# The dev network is external and shared with Traefik, which joins it as a second
# attachment so it can route the dev. hostnames. Nothing else crosses.
dev-network:
	docker network create construct_dev_net 2>/dev/null || echo "construct_dev_net already exists"

# Copy the dev stack files into the dev deploy root. Mirrors what deploy.yml does
# for prod (SERV-76) — the running project is bound to a fixed path, not to a
# checkout that CI or a human may move underneath it.
dev-bootstrap: dev-network
	@mkdir -p "$(DEV_ROOT)" 2>/dev/null || { echo "Cannot create $(DEV_ROOT) — run: sudo install -d -o $$(id -un) -g $$(id -gn) $(DEV_ROOT)"; exit 1; }
	rsync -a docker-compose.dev.yml "$(DEV_ROOT)/"
	rsync -a --delete ./db/ "$(DEV_ROOT)/db/"
	@echo "Dev root ready at $(DEV_ROOT). Put the dev .env there, then: make dev-up"

# Bring the dev stack up. Safe to re-run; recreates only what drifted.
#
# Deliberately three steps rather than one `up -d`. `depends_on: service_healthy`
# only waits for Postgres to accept connections — it says nothing about whether
# the per-service DATABASES exist, and they are created by init-db.sh afterwards.
# A single `up -d` on a cold dev root therefore starts every service against a
# server with no database for it, and they crash-loop until something runs the
# init: measured at 10 restarts each before this ordering was added.
#
# Prod has the same shape (deploy.yml runs init-db.sh after `up -d`) and gets away
# with it because its databases already exist. A dev root is cold every time it is
# rebuilt, so it is worth ordering properly here.
dev-up: dev-root dev-network
	$(DEV_COMPOSE) up -d --wait postgres-dev
	@$(MAKE) --no-print-directory dev-db-init DEV_ROOT=$(DEV_ROOT)
	$(DEV_COMPOSE) up -d

dev-down: dev-root
	$(DEV_COMPOSE) down

# Recreate dev service(s). --no-deps for the same reason as prod (SERV-63): dev's
# services depend on postgres-dev, and an unscoped recreate bounces the dev
# database out from under every other dev service.
# Usage: make dev-recreate svc=switchyard-dev
dev-recreate: dev-root dev-network
	$(DEV_COMPOSE) up -d $(if $(svc),$(if $(DEPS_ON),,--no-deps)) $(svc)

dev-pull: dev-root
	$(DEV_COMPOSE) pull

dev-ps: dev-root
	$(DEV_COMPOSE) ps

dev-logs: dev-root
	$(DEV_COMPOSE) logs -f --tail=100 $(svc)

# Provision the dev databases. Same db/init-db.sh as prod, unmodified — the roles
# it creates live in a DIFFERENT Postgres server, so `switchyard_user` here is not
# `switchyard_user` there. Idempotent, so re-running is safe (CLAUDE.md invariant).
dev-db-init: dev-root
	$(DEV_COMPOSE) exec -T -e POSTGRES_USER=postgres -e POSTGRES_DB=postgres postgres-dev bash < $(DEV_ROOT)/db/init-db.sh

dev-db-shell: dev-root
	$(DEV_COMPOSE) exec postgres-dev psql -U postgres

# Report env keys prod declares that dev does not (see the script header for why
# dev is written out explicitly instead of using compose `extends`).
dev-parity:
	./scripts/check-dev-parity.sh

# Prove dev is not reachable from the WAN edge. SERV-77's stated check is that the
# PUBLIC path fails; internal-only routing plus loopback-bound ports is what makes
# it fail, and this asserts it rather than assuming it.
dev-verify-isolation:
	@./scripts/check-dev-isolation.sh
