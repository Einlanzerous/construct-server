#!/usr/bin/env bash
# Add the Switchyard GitHub webhook (SERV-316) to the given Einlanzerous repos.
# Same config as the existing hooks: pull_request + push, json, SSL verified.
# The secret is read from $GITHUB_WEBHOOK_SECRET and sent to GitHub on stdin
# (never argv, never echoed). Run it under Signet so nothing is revealed:
#   signet exec -secret construct-server/GITHUB_WEBHOOK_SECRET -redact -- \
#     scripts/add-switchyard-webhook.sh argosy catenary ...
# Idempotent: a repo that already has a hook on the URL is skipped.
set -euo pipefail
OWNER=${WEBHOOK_OWNER:-Einlanzerous}
export URL=${WEBHOOK_URL:-https://switchyard.zerogravity.industries/v1/external/github}
: "${GITHUB_WEBHOOK_SECRET:?set GITHUB_WEBHOOK_SECRET (run under signet exec)}"
[ $# -gt 0 ] || { echo "usage: $0 repo [repo...]" >&2; exit 2; }
rc=0
for repo in "$@"; do
  if gh api "repos/$OWNER/$repo/hooks" --jq '.[].config.url' | grep -qxF "$URL"; then
    echo "$repo: already hooked, skipped"; continue
  fi
  id=$(python3 -c '
import json,os
print(json.dumps({"name":"web","active":True,"events":["pull_request","push"],
 "config":{"url":os.environ["URL"],"content_type":"json","insecure_ssl":"0",
 "secret":os.environ["GITHUB_WEBHOOK_SECRET"]}}))' \
    | gh api -X POST "repos/$OWNER/$repo/hooks" --input - --jq .id) || { echo "$repo: create FAILED" >&2; rc=1; continue; }
  sleep 1
  gh api -X POST "repos/$OWNER/$repo/hooks/$id/pings" >/dev/null
  sleep 3
  st=$(gh api "repos/$OWNER/$repo/hooks/$id/deliveries" --jq '.[0].status_code // "none"')
  echo "$repo: hook $id, ping delivery status $st"
  case $st in 2??) ;; *) rc=1;; esac
done
exit $rc
