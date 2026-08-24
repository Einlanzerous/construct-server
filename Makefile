.PHONY: network up down recreate force-recreate drift-check health-check edge-auth-check versions assert-tokens deploy-scope probe-delivery probe-status db-up db-shell db-check db-init deploy-root \
        dev-root dev-network dev-bootstrap dev-up dev-down dev-recreate dev-force-recreate dev-pull dev-ps dev-logs \
        dev-db-init dev-db-shell dev-parity dev-verify-isolation dev-health-check dev-versions dev-assert-tokens \
        dev-edge-status dev-edge-on dev-edge-down dev-build-guard dev-edge-auth-check \
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

# The same shape check against PROD's rendered environment (SERV-118). Since SERV-124 it
# is also a GATE in deploy.yml, run after the render and before anything pulls, builds or
# recreates — so this target is the local rehearsal of a check the deploy now enforces,
# not a diagnostic prod is exempt from.
#
# This comment previously said the opposite, and justified it with "prod's copy is
# Signet-managed, so the hand-written-secret failure mode that hit dev is not reachable
# the same way". That argument is retired, not merely outvoted: `signet render --check`
# compares key SETS, not values, so a vault seeded from a stale file renders the stale
# value and reports success — which is precisely how the bad dev token was installed.
# Vault management protects against a hand-EDITED value and does nothing about a WRONG
# one. Run this after touching PROD_ENV_FILE, and after any `signet sync`.
# Usage: make assert-tokens
assert-tokens:
	DEPLOY_ROOT=$(DEPLOY_ROOT) ./scripts/assert-token-shapes.sh

# Run the delivery prober once, right now, exactly as the timer does (SERV-111). Reads
# the same /etc/delivery-prober/prober.env the unit does, so it proves the deployed
# credential rather than one you exported by hand. This is the fast way to answer "is the
# dev column stale because the prober is broken, or because dev has not moved?".
# Usage: make probe-delivery
probe-delivery:
	@test -r /etc/delivery-prober/prober.env || { \
	  echo "No readable /etc/delivery-prober/prober.env."; \
	  echo "Provision it:  ansible-playbook ansible/site.yml --tags delivery_prober"; \
	  echo "Mint its token: ./scripts/mint-prober-token.sh"; \
	  exit 1; \
	}
	@set -a; . /etc/delivery-prober/prober.env; set +a; \
	  $(DEPLOY_ROOT)/scripts/probe-delivery.sh

# Is the prober alive, and when did it last actually run? (SERV-111) `systemctl status`
# on the TIMER says only that the schedule exists; the failure that matters is the oneshot
# landing in `failed` while the timer keeps cheerfully firing it. Both are shown here.
probe-status:
	@systemctl list-timers delivery-prober.timer --all --no-pager || true
	@echo
	@systemctl status delivery-prober.service --no-pager --lines=20 || true

# What would deploying this commit range actually pull and recreate? (SERV-109) A promote
# or rollback commit touches versions.env and nothing else, and deploy.yml scopes that case
# to the services behind the pins that moved; every other deploy pulls the whole stack.
# Reads git and docker-compose.yml only — it touches neither the box nor the deploy root,
# so it answers "what will this do" BEFORE the merge rather than after.
# Usage: make deploy-scope                          (HEAD^..HEAD)
#        make deploy-scope base=main head=my-branch
deploy-scope:
	@./scripts/deploy-scope.sh $(or $(base),HEAD^) $(or $(head),HEAD) \
	  || echo "=> the whole stack would be pulled, for the reason above"

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

# THE DEV EDGE IS GATED ON ITS OWN CREDENTIAL (SERV-93).
#
# traefik-dev, cf-access-guard-dev and cloudflared-dev carry `profiles: [edge]`, so
# they are not started unless that profile is on. This is what turns it on, and the
# switch is deliberately the tunnel token itself rather than a flag someone has to
# remember: half of SERV-93 lives in the Cloudflare Zero Trust dashboard (a second
# tunnel, one Access application per dev hostname) and no file in this repo can
# create it. Until that half is done there is no token, so the edge does not start —
# rather than starting and crash-looping, which is what an empty TUNNEL_TOKEN does.
# Once DEV_ENV_FILE carries the token there is no second change to make.
#
# Tests PRESENCE, never the value, and prints neither. `..` rather than `.` so a
# `DEV_CLOUDFLARE_TUNNEL_TOKEN=` line reads as absent, which it is — an empty
# environment variable is not a value (CLAUDE.md).
#
# COMPOSE_PROFILES rather than `--profile`, because it reaches the scripts that build
# their own `docker compose` invocation. Specifically report-versions.sh and
# assert-token-shapes.sh, which read `compose config` — that IS profile-filtered, so
# without this they would silently under-report the edge. assert-healthy.sh is NOT
# affected: it enumerates with `compose ps -a`, which lists profile-disabled
# containers regardless (measured on compose v5.0.0, not assumed). Said precisely
# because an earlier draft of this comment claimed the health check had a coverage
# gap, and it does not — which would have sent the next reader hunting for one.
DEV_EDGE := $(shell grep -qsE '^DEV_CLOUDFLARE_TUNNEL_TOKEN=..' $(DEV_ROOT)/.env && echo 1)

# WHAT IS ACTUALLY RUNNING, which is a different question from the one above and the
# reason both exist. `DEV_EDGE` is INTENT — what the credential says should happen.
# This is REALITY.
#
# They come apart in one direction that matters: `docker compose up -d` with a profile
# OFF does not stop the containers that profile created. Measured on compose v5.0.0 —
# a profile-gated container stays `Up` and is not treated as an orphan. So removing the
# token turns the edge on-switch off and leaves the running edge exactly where it was:
# the tunnel still connected, the hostnames still served, and every check that keyed
# off intent alone quietly reporting "not deployed, nothing to assert" about a live
# origin. The auth assertion going silent over a serving edge is strictly worse than it
# never having existed.
#
# So: `dev-up` RECONCILES (see dev-edge-down), and `dev-edge-auth-check` keys off this
# rather than off the token — if something is serving, it gets probed.
DEV_EDGE_LIVE := $(shell docker ps --format '{{.Names}}' 2>/dev/null | grep -qxE 'traefik-dev|cf-access-guard-dev|cloudflared-dev' && echo 1)

DEV_PROFILES = COMPOSE_PROFILES=$(if $(DEV_EDGE),edge,)

DEV_COMPOSE = $(DEV_PROFILES) docker compose -p $(DEV_PROJECT) -f $(DEV_ROOT)/docker-compose.dev.yml \
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
	@# rsync creates only the LAST component of a destination path, so the two
	@# nested syncs below need their parent directories to exist first (SERV-93).
	mkdir -p "$(DEV_ROOT)/config" "$(DEV_ROOT)/services" "$(DEV_ROOT)/pkg"
	rsync -a --delete ./db/ "$(DEV_ROOT)/db/"
	rsync -a --delete ./scripts/ "$(DEV_ROOT)/scripts/"
	rsync -a --delete ./config/traefik-dev/ "$(DEV_ROOT)/config/traefik-dev/"
	rsync -a --delete ./services/cf-access-guard/ "$(DEV_ROOT)/services/cf-access-guard/"
	@# The guard's build reads pkg/cfaccess as a named build context (SERV-131), and
	@# DEV_COMPOSE runs with --project-directory $(DEV_ROOT), so the context path is
	@# resolved against the dev root rather than this checkout. Without this sync it
	@# resolves to a directory that does not exist.
	rsync -a --delete ./pkg/cfaccess/ "$(DEV_ROOT)/pkg/cfaccess/"
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
	@$(MAKE) --no-print-directory dev-edge-status DEV_ROOT=$(DEV_ROOT)
	$(if $(DEV_EDGE),@$(MAKE) --no-print-directory dev-build-guard DEV_ROOT=$(DEV_ROOT))
	$(if $(DEV_EDGE),,$(if $(DEV_EDGE_LIVE),@$(MAKE) --no-print-directory dev-edge-down DEV_ROOT=$(DEV_ROOT)))
	$(DEV_COMPOSE) up -d --wait postgres-dev
	@$(MAKE) --no-print-directory dev-db-init DEV_ROOT=$(DEV_ROOT)
	$(DEV_COMPOSE) up -d

# The dev edge state as a machine-readable answer: `1` when on, empty when off.
# deploy-dev.yml asks this rather than re-implementing the test, so there is exactly
# one place that decides what "the dev edge is deployed" means.
dev-edge-on:
	@echo "$(DEV_EDGE)"

# Which mode is this dev root in? Printed by dev-up rather than left to be inferred:
# "dev has no hostnames" and "dev's edge failed to start" look identical from outside,
# and only one of them is a problem.
dev-edge-status:
	@if [ -n "$(DEV_EDGE)" ] && [ -n "$(DEV_EDGE_LIVE)" ]; then \
	  echo "Dev edge: ON — token present, containers running."; \
	elif [ -n "$(DEV_EDGE)" ]; then \
	  echo "Dev edge: ON (token present) — containers not up yet; 'make dev-up' starts them."; \
	elif [ -n "$(DEV_EDGE_LIVE)" ]; then \
	  echo "Dev edge: HALF-ON — no DEV_CLOUDFLARE_TUNNEL_TOKEN, but edge containers ARE running."; \
	  echo "          The token is the switch, and compose does not stop a profile-gated"; \
	  echo "          container when its profile goes off — so a live edge is still serving"; \
	  echo "          while every intent-based check calls it 'not deployed'. 'make dev-up'"; \
	  echo "          reconciles this; 'make dev-edge-down' does it now."; \
	else \
	  echo "Dev edge: OFF — no DEV_CLOUDFLARE_TUNNEL_TOKEN in $(DEV_ROOT)/.env,"; \
	  echo "          and nothing running. Dev is on its loopback ports only. See"; \
	  echo "          docs/dev-environment.md for the Zero Trust steps (SERV-93)."; \
	fi

# Take the dev edge down. The other half of "the credential is the switch": without
# this, removing the token stops the edge being STARTED without stopping it RUNNING.
#
# COMPOSE_PROFILES=edge unconditionally, not $(DEV_PROFILES) — this target runs
# precisely when the profile is off, and compose cannot address a service whose profile
# is disabled. Naming the three explicitly rather than `down`, which would take the
# whole dev project with it.
dev-edge-down: dev-root
	@echo "Stopping the dev edge — the tunnel token is gone, so it must not keep serving."
	COMPOSE_PROFILES=edge docker compose -p $(DEV_PROJECT) -f $(DEV_ROOT)/docker-compose.dev.yml \
	  --project-directory $(DEV_ROOT) --env-file $(DEV_ROOT)/.env \
	  rm -sf traefik-dev cf-access-guard-dev cloudflared-dev

# Build cf-access-guard for the DEV project. Explicit, because `up -d` builds only
# when the image is MISSING — it does not notice that the source changed, and for the
# container that decides whether dev requests are authenticated that is the worst
# possible silent no-op (the same reasoning as deploy.yml's prod build step).
#
# GUARD_REVISION stamps the commit the binary came from (SERV-109); it is the image's
# only identity, since BuildKit re-exports the config on every build and the image ID
# therefore changes even on a full cache hit. Resolved from THIS checkout's git
# history — the dev root is an rsync target with none — and `unknown` when that fails,
# which is the loud direction: it will not match a real commit.
dev-build-guard: dev-root
	@rev="$$(git -C . log -1 --format=%H -- services/cf-access-guard pkg/cfaccess 2>/dev/null || true)"; \
	  echo "cf-access-guard source revision: $${rev:-<could not resolve>}"; \
	  GUARD_REVISION="$${rev:-unknown}" $(DEV_COMPOSE) build cf-access-guard-dev

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
	$(DEV_PROFILES) DEPLOY_ROOT=$(DEV_ROOT) COMPOSE_FILE=docker-compose.dev.yml COMPOSE_PROJECT=$(DEV_PROJECT) \
	  ./scripts/assert-healthy.sh --timeout 180 $(svc)

# What is dev ACTUALLY running? Dev floats on `latest`, so the compose file answers
# nothing and `dev-ps` answers with the same word every time. This resolves it to the
# commit each image was built from (SERV-97).
# Usage: make dev-versions
dev-versions:
	$(DEV_PROFILES) DEPLOY_ROOT=$(DEV_ROOT) COMPOSE_FILE=docker-compose.dev.yml COMPOSE_PROJECT=$(DEV_PROJECT) \
	  ./scripts/report-versions.sh $(svc)

# Does dev's RENDERED environment hold tokens switchyard will actually accept (SERV-118)?
# The dev tier sat dark for two days on a bootstrap token of the wrong shape, and the
# deploy that rendered it went green. deploy-dev.yml runs this as a render-time gate;
# this is the local copy. Prints no credential — only which variable, its length, and
# whether it carries the `sw_` prefix.
# Usage: make dev-assert-tokens
dev-assert-tokens:
	$(DEV_PROFILES) DEPLOY_ROOT=$(DEV_ROOT) COMPOSE_FILE=docker-compose.dev.yml COMPOSE_PROJECT=$(DEV_PROJECT) \
	  ./scripts/assert-token-shapes.sh

# Report env keys prod declares that dev does not (see the script header for why
# dev is written out explicitly instead of using compose `extends`).
dev-parity:
	COMPOSE_PROFILES=edge ./scripts/check-dev-parity.sh

# Prove dev is not reachable from the WAN edge. SERV-77's stated check is that the
# PUBLIC path fails; internal-only routing plus loopback-bound ports is what makes
# it fail, and this asserts it rather than assuming it.
dev-verify-isolation:
	@./scripts/check-dev-isolation.sh

# Does the DEV origin reject a request with no valid Cloudflare Access assertion
# (SERV-93)? The dev half of `make edge-auth-check`, against traefik-dev,
# cf-access-guard-dev and the dev routers.
#
# Skips with a notice when the dev edge is not deployed, and that is not a check
# quietly passing: with no tunnel token there is no traefik-dev, no dev hostname and
# nothing serving anything, so there is no origin to interrogate. What still runs in
# that state is `make dev-verify-isolation`, which asserts the property that actually
# matters while dev has no edge — that dev cannot reach prod.
#
# `config_only=1` runs the config half against the files alone, which is the form to
# use from a checkout with no stack — and the form that tells you which dev Access
# applications still have no AUD recorded.
# Usage: make dev-edge-auth-check
#        make dev-edge-auth-check config_only=1
dev-edge-auth-check:
	@if [ -z "$(DEV_EDGE_LIVE)" ] && [ -z "$(config_only)" ]; then \
	  echo "No dev edge container is running, so there is no origin to interrogate."; \
	  echo "Run 'make dev-edge-auth-check config_only=1' to check the committed config,"; \
	  echo "and see docs/dev-environment.md for the Zero Trust steps (SERV-93)."; \
	else \
	  ./scripts/check-edge-auth.sh --dev $(if $(config_only),--config-only); \
	fi
