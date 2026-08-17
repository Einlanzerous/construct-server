.PHONY: network up down recreate force-recreate drift-check health-check edge-auth-check versions db-up db-shell db-check db-init deploy-root \
        dev-root dev-network dev-bootstrap dev-up dev-down dev-recreate dev-force-recreate dev-pull dev-ps dev-logs \
        dev-db-init dev-db-shell dev-parity dev-verify-isolation dev-health-check dev-versions \
        wiki-fetch wiki-fetch-local wiki-generate wiki-build wiki-serve

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

# Fail if any container is unhealthy, and list the ones with no healthcheck at all
# (SERV-102). deploy.yml runs the same script as a post-deploy gate; this is the local
# way to ask "is the stack actually up", which `docker compose ps` does not answer.
# Usage: make health-check                (whole stack)
#        make health-check svc=switchyard (one service)
health-check:
	DEPLOY_ROOT=$(DEPLOY_ROOT) ./scripts/assert-healthy.sh $(svc)

# Assert the ORIGIN rejects a spoofed Host (SERV-106), rather than merely being hard to
# reach (SERV-107). Two halves: a config check that every router on the `internal`
# entrypoint carries the cf-access-jwt middleware and that the AUD map matches, and a live
# probe from the host — which reaches container ports whether or not they are published.
# deploy.yml runs the same script as a post-deploy gate.
# Usage: make edge-auth-check                  (config + live; needs the stack up)
#        make edge-auth-check config_only=1    (config only, e.g. from a laptop)
edge-auth-check:
	./scripts/check-edge-auth.sh $(if $(config_only),--config-only)

# Report what the stack is actually running: image ref, resolved digest, and the COMMIT
# each image was built from (SERV-97). Read the revision column, not the digest — the
# publish workflow builds the same source twice seconds apart, so two digests from one
# commit is normal and comparing them invents drift that is not there (SERV-88).
# Usage: make versions            (whole stack)
#        make versions svc=purser (one service)
versions:
	DEPLOY_ROOT=$(DEPLOY_ROOT) ./scripts/report-versions.sh $(svc)

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
# ESTATE WIKI (SERV-101) — generated docs
# ============================================================================
# These act on this CHECKOUT, not on the deploy root: the wiki is built from
# source and published by deploy.yml, so there is nothing here to point at the
# live stack. `make wiki-serve` is the loop you want while working on the
# generator — it regenerates, then serves with hot reload.
#
# The build runs in a container for the same reason deploy.yml does: it pins the
# toolchain, so a host node upgrade cannot change what gets built, and it works on
# a box with no node at all.
WIKI_NODE_IMAGE ?= node:22-alpine
# Every flag has to precede the image name — docker treats the first argument after
# it as the container command, so a trailing `-e FOO` becomes an attempt to exec a
# binary called `-e`. WIKI_DOCS_TOKEN is passed here rather than at the call site
# for that reason; forwarding an unset variable is harmless.
WIKI_RUN = docker run --rm --user "$$(id -u):$$(id -g)" \
           -e HOME=/tmp -e npm_config_cache=/tmp/.npm -e WIKI_DOCS_TOKEN \
           -v "$(CURDIR):/repo" -w /repo/wiki $(WIKI_NODE_IMAGE)

# Cache each repo's CLAUDE.md/README.md from GitHub. Needs a token with contents
# read across the estate's repos — set WIKI_DOCS_TOKEN. Without one, use
# `make wiki-fetch-local`, which reads ~/projects instead.
wiki-fetch:
	$(WIKI_RUN) sh -c 'npm ci --no-audit --no-fund && npm run fetch'

# Same cache, filled from sibling checkouts. Faster, and picks up uncommitted
# edits — but it describes whatever is in those working copies, not what shipped.
wiki-fetch-local:
	cd wiki && npm run fetch:local

# Emit the Markdown corpus without building the site. The fast inner loop when
# changing an emitter: it is the corpus that matters, the site is a view of it.
wiki-generate:
	cd wiki && npm run generate

# Full static build, exactly as deploy.yml does it.
wiki-build:
	$(WIKI_RUN) sh -c 'npm ci --no-audit --no-fund && npm run build'

# Local preview with hot reload on http://localhost:5173.
wiki-serve:
	cd wiki && npm run dev

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
#
# `deploy-dev.yml` is what drives these in steady state (SERV-97) — it renders the .env
# from DEV_ENV_FILE + dev-versions.env, pulls, and calls dev-up. These targets remain the
# way a human does it locally, and the workflow calls them rather than restating the flags,
# which is the point of pinning the project/file/env-file triple in one place.
#
# Setting up a dev root BY HAND, without the workflow: after `make dev-bootstrap`, put your
# own .env at $(DEV_ROOT)/.env. It needs no DEV_*_TAG entries — the `:-latest` fallback in
# the compose file applies and dev floats, which is dev's normal state. To also apply the
# tracked pins, render it the way the workflow does:
#   ./scripts/render-env.sh $(DEV_ROOT)/.env dev-versions.env $(DEV_ROOT)/.env
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

# The dev network is external and belongs to the dev project alone. NOTHING from
# the prod project should ever be attached to it — an earlier revision of SERV-77
# put Traefik on both so it could route dev. hostnames, and that handed every dev
# container an unauthenticated route into prod Switchyard and Lyceum: back then the
# internal entrypoint had no source restriction and those routers had no auth
# middleware. Both have since been fixed (SERV-107, SERV-106), so a dev container on
# a shared Traefik would now be refused rather than served — but the network stays
# separate regardless. `make dev-verify-isolation` fails if anything foreign joins.
# Giving dev its own edge, with its own Access applications, is SERV-93.
dev-network:
	docker network create construct_dev_net 2>/dev/null || echo "construct_dev_net already exists"

# Copy the dev stack files into the dev deploy root. Mirrors what deploy.yml does
# for prod (SERV-76) — the running project is bound to a fixed path, not to a
# checkout that CI or a human may move underneath it.
dev-bootstrap: dev-network
	@mkdir -p "$(DEV_ROOT)" 2>/dev/null || { echo "Cannot create $(DEV_ROOT) — run: sudo install -d -o $$(id -un) -g $$(id -gn) $(DEV_ROOT)"; exit 1; }
	rsync -a docker-compose.dev.yml dev-versions.env Makefile "$(DEV_ROOT)/"
	rsync -a --delete ./db/ "$(DEV_ROOT)/db/"
	rsync -a --delete ./scripts/ "$(DEV_ROOT)/scripts/"
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
	$(DEV_COMPOSE) up -d $(NO_DEPS) $(svc)

# Dev's counterpart to force-recreate: rebuild a container whose spec did NOT
# change, e.g. to re-read a changed dev .env. Same guards as the prod target for
# the same reason (SERV-63) — unscoped or with deps=, --force-recreate propagates
# into depends_on and takes postgres-dev down under every other dev service.
# Usage: make dev-force-recreate svc=purser-dev
dev-force-recreate: dev-root dev-network
	@test -n "$(svc)" || { \
	  echo "dev-force-recreate requires svc=<name> — unscoped it recreates the whole dev stack,"; \
	  echo "including postgres-dev, which every other dev service depends on."; \
	  exit 1; \
	}
	@test -z "$(DEPS_ON)" || { \
	  echo "dev-force-recreate does not accept deps= — it would force-recreate postgres-dev too."; \
	  echo "For a cold start: make dev-up"; \
	  exit 1; \
	}
	$(DEV_COMPOSE) up -d --no-deps --force-recreate $(svc)

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

# Dev's counterpart to health-check (SERV-97). Most dev services declare no healthcheck,
# so what this mainly catches is a service that crash-looped or exited — which is the dev
# failure that matters, since a cold dev root is exactly where that happens. It also names
# the containers that cannot be seen to fail.
# Usage: make dev-health-check                    (whole dev project)
#        make dev-health-check svc=switchyard-dev (one service)
dev-health-check:
	DEPLOY_ROOT=$(DEV_ROOT) COMPOSE_FILE=docker-compose.dev.yml COMPOSE_PROJECT=$(DEV_PROJECT) \
	  ./scripts/assert-healthy.sh --timeout 180 $(svc)

# What is dev ACTUALLY running? Dev floats on `latest`, so the compose file answers
# nothing and `dev-ps` answers with the same word every time. This resolves it to the
# commit each image was built from (SERV-97).
# Usage: make dev-versions
dev-versions:
	DEPLOY_ROOT=$(DEV_ROOT) COMPOSE_FILE=docker-compose.dev.yml COMPOSE_PROJECT=$(DEV_PROJECT) \
	  ./scripts/report-versions.sh $(svc)

# Report env keys prod declares that dev does not (see the script header for why
# dev is written out explicitly instead of using compose `extends`).
dev-parity:
	./scripts/check-dev-parity.sh

# Prove dev is not reachable from the WAN edge. SERV-77's stated check is that the
# PUBLIC path fails; internal-only routing plus loopback-bound ports is what makes
# it fail, and this asserts it rather than assuming it.
dev-verify-isolation:
	@./scripts/check-dev-isolation.sh
