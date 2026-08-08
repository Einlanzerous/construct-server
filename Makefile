.PHONY: network up down recreate force-recreate drift-check db-up db-shell db-check db-init

# Scope a single-service action to that service (SERV-63). Compose otherwise reaches
# into `depends_on`, so an action aimed at one container can recreate the shared
# postgres and bounce every service on the box. Only applies when svc= is named;
# pass deps=1 for a genuine cold start, where the dependencies do need to come up.
# 0/no/false are treated as "keep it scoped" — Make's $(if) is a non-empty test, so
# without filtering them out `deps=0` would read as "yes, bring dependencies up".
NO_DEPS = $(if $(svc),$(if $(filter-out 0 no false,$(deps)),,--no-deps))

# Create the construct_net Docker bridge network (required before starting the stack)
network:
	docker network create construct_net 2>/dev/null || echo "construct_net already exists"

# Start the full stack
up: network
	docker compose up -d

# Stop the full stack
down:
	docker compose down

# Recreate service(s) so docker-compose.yml edits (mounts/env/image) take effect.
# ALWAYS use this after editing the compose — NEVER `docker restart`, which silently
# keeps the old container spec (see SERV-8 / the /media-ssd drift incident).
# Usage: make recreate                   (recreate any drifted service across the stack)
#        make recreate svc=argosy        (recreate a single service, and only that one)
#        make recreate svc=argosy deps=1 (cold start: bring its dependencies up too)
recreate: network
	docker compose up -d $(NO_DEPS) $(svc)

# Recreate a container whose spec did NOT change — e.g. to re-read an env_file whose
# contents changed but whose path didn't, which compose does not always see as drift.
# Always scoped: --force-recreate is the flag that propagates into depends_on, so this
# target hardcodes --no-deps and accepts neither an empty svc= nor deps=. Both would
# reconstruct the SERV-63 command, which force-recreated the shared postgres.
# Usage: make force-recreate svc=purser
force-recreate: network
	@test -n "$(svc)" || { \
	  echo "force-recreate requires svc=<name> — unscoped, it would recreate every container in the stack."; \
	  echo "To rebuild the whole stack deliberately: docker compose up -d --force-recreate"; \
	  exit 1; \
	}
	@test -z "$(deps)" || { \
	  echo "force-recreate does not accept deps= — it would force-recreate every dependency of"; \
	  echo "$(svc), including the shared postgres. That is the SERV-63 command verbatim."; \
	  echo "For a cold start, bring dependencies up unforced: make recreate svc=$(svc) deps=1"; \
	  exit 1; \
	}
	docker compose up -d --no-deps --force-recreate $(svc)

# Detect containers running a stale spec vs docker-compose.yml (SERV-8 guardrail).
# Usage: make drift-check            (check every service)
#        make drift-check svc=argosy (check a single service)
drift-check:
	./scripts/check-compose-drift.sh $(svc)

# Start only the postgres service
db-up: network
	docker compose up -d postgres

# Open a psql shell to the running postgres container
db-shell:
	docker compose exec postgres psql -U postgres

# Run init-db.sh against a running postgres (idempotent — safe to re-run)
db-init:
	docker compose exec postgres bash /docker-entrypoint-initdb.d/init-db.sh

# Verify databases and users were created correctly
db-check:
	@echo "=== Databases ==="
	@docker compose exec postgres psql -U postgres -c "\l" | grep -E "cook_book|switchyard"
	@echo ""
	@echo "=== User access: cook_book ==="
	@docker compose exec postgres psql -U cook_book_user -d cook_book -c "SELECT 1 AS connected;"
	@echo "=== User access: switchyard ==="
	@docker compose exec postgres psql -U switchyard_user -d switchyard -c "SELECT 1 AS connected;"
