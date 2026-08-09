.PHONY: network up down recreate force-recreate drift-check db-up db-shell db-check db-init deploy-root

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
