#!/usr/bin/env bash
# check-dev-parity.sh — Report environment keys that prod declares and dev does not.
#
# The dev project (SERV-77) is defined explicitly in docker-compose.dev.yml rather
# than with `extends:`, because compose's extends UNIONS `networks` and inherits
# `depends_on` — a dev service extending a prod one drags in construct_net and the
# prod postgres, which is the isolation the ticket exists to create.
#
# The cost of writing dev out explicitly is drift: add an env key to a prod service
# and its dev counterpart silently does without it, so dev stops being a faithful
# rehearsal of prod without anyone noticing. This makes that visible.
#
# It compares KEY NAMES ONLY and never prints a value — both files interpolate real
# secrets, and this runs in CI.
#
# Some keys are absent from dev ON PURPOSE (Signet, Cloudflare Access, the GitHub
# poller and webhook). Those are listed in EXPECTED_ABSENT below and reported
# separately, so the deliberate gaps stay legible instead of being lost in noise.
#
# Usage:
#   ./scripts/check-dev-parity.sh
#
# Exit codes:
#   0  no unexplained drift
#   1  a prod key is missing from its dev counterpart
#   2  usage / missing dependency error

set -euo pipefail

DEPLOY_ROOT="${DEPLOY_ROOT:-/opt/construct-server}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd)"

err() { printf '%s\n' "$*" >&2; }

for dep in docker python3; do
  command -v "$dep" >/dev/null 2>&1 || { err "ERROR: required dependency '$dep' not found in PATH"; exit 2; }
done

# prod -> dev service mapping. A prod service with no dev counterpart is simply not
# part of the dev slice and is not drift.
PAIRS="switchyard:switchyard-dev
switchyard-frontend:switchyard-frontend-dev
argosy:argosy-dev
lyceum:lyceum-dev
purser:purser-dev
traefik:traefik-dev
cf-access-guard:cf-access-guard-dev
cloudflared:cloudflared-dev"

# Keys dev deliberately does without, with the reason. Anything here is reported as
# an intentional gap rather than a failure; anything NOT here is drift.
EXPECTED_ABSENT="SIGNET_API_TOKEN:no vault handle in dev
SIGNET_BASE_URL:no vault handle in dev
AMBER_BASE_URL:no amber in the dev slice
AMBER_API_TOKEN:no amber in the dev slice
CF_ACCESS_TEAM_DOMAIN:in-app SSO off in dev (cf-access-guard-dev does carry it)
CF_ACCESS_AUD:in-app SSO off in dev (the guard holds the dev AUDs instead)
CF_DNS_API_TOKEN:traefik-dev terminates no TLS, so dev holds no key to the real DNS zone
CROWDSEC_BOUNCER_KEY:no public entrypoint and no crowdsec in the dev project
GITHUB_TOKEN:dev must not act on real PRs
GITHUB_WEBHOOK_SECRET:dev must not receive real webhooks
PURSER_CF_API_TOKEN:no dev Zero Trust tenant
PURSER_CF_ACCOUNT_ID:no dev Zero Trust tenant
PURSER_CF_ACCESS_GROUP_ID:no dev Zero Trust tenant
PURSER_CF_ACCESS_GROUP_NAME:no dev Zero Trust tenant
PURSER_CF_TEAM_DOMAIN:no dev Zero Trust tenant
LYCEUM_BINDERY_API_KEY:no bindery in dev
LYCEUM_BOOKS_WATCH_DIR:folder ingest off in dev
LYCEUM_BOOKS_WATCH_INTERVAL:folder ingest off in dev
LYCEUM_OWNER_EMAIL:no seeded owner in dev
LYCEUM_OWNER_NAME:no seeded owner in dev
LYCEUM_CORS_ORIGINS:no native shells against dev
LYCEUM_SMTP_HOST:no outbound mail from dev
LYCEUM_SMTP_PORT:no outbound mail from dev
LYCEUM_SMTP_USERNAME:no outbound mail from dev
LYCEUM_SMTP_PASSWORD:no outbound mail from dev
LYCEUM_SMTP_FROM:no outbound mail from dev
LYCEUM_KINDLE_ADDR:no outbound mail from dev
LYCEUM_API_TOKENS:no delivery tokens in dev
LYCEUM_BINDERY_BASE_URL:no bindery in dev
OPEN_SUBTITLES_API_KEY:no subtitle fetch in dev
OPEN_SUBTITLES_USERNAME:no subtitle fetch in dev
OPEN_SUBTITLES_PASSWORD:no subtitle fetch in dev"

prod_json="$(cd "$DEPLOY_ROOT" && docker compose config --format json 2>/dev/null)" || {
  err "ERROR: could not resolve the prod compose config at $DEPLOY_ROOT"
  exit 2
}
# The dev file is resolved from the repo with a throwaway env so interpolation
# succeeds without needing the real dev secrets on hand — only key names matter.
dev_json="$(cd "$REPO_ROOT" && docker compose -f docker-compose.dev.yml --env-file /dev/null config --format json 2>/dev/null)" || {
  err "ERROR: could not resolve docker-compose.dev.yml"
  exit 2
}

PAIRS="$PAIRS" EXPECTED_ABSENT="$EXPECTED_ABSENT" \
PROD_JSON="$prod_json" DEV_JSON="$dev_json" python3 <<'PY'
import json, os, sys

prod = json.loads(os.environ["PROD_JSON"])["services"]
dev  = json.loads(os.environ["DEV_JSON"])["services"]
expected = dict(
    line.split(":", 1) for line in os.environ["EXPECTED_ABSENT"].strip().split("\n") if line
)

def keys(svc_map, name):
    env = (svc_map.get(name) or {}).get("environment") or {}
    if isinstance(env, list):
        env = {e.split("=", 1)[0]: None for e in env}
    return set(env)

drift = 0
for line in os.environ["PAIRS"].strip().split("\n"):
    p, d = line.split(":", 1)
    if p not in prod:
        print(f"• {p:<22} SKIP — not in the prod compose")
        continue
    if d not in dev:
        print(f"• {p:<22} SKIP — no dev counterpart")
        continue
    missing = keys(prod, p) - keys(dev, d)
    unexplained = sorted(k for k in missing if k not in expected)
    intentional = sorted(k for k in missing if k in expected)
    if unexplained:
        drift = 1
        print(f"• {p:<22} {len(unexplained)} unexplained")
        for k in unexplained:
            print(f"    DRIFT  {d} is missing {k}")
    else:
        print(f"• {p:<22} OK" + (f" ({len(intentional)} intentional gaps)" if intentional else ""))

print()
if drift:
    print("DEV PARITY DRIFT — a prod service declares env the dev one does not.", file=sys.stderr)
    print("Either mirror the key in docker-compose.dev.yml, or add it to", file=sys.stderr)
    print("EXPECTED_ABSENT in this script with the reason dev does without it.", file=sys.stderr)
    sys.exit(1)
print("Dev mirrors prod's environment, apart from the documented intentional gaps.")
PY
