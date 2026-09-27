#!/usr/bin/env bash
# render-backup-env.sh — render /etc/construct-backup/backup.env from the
# `construct-backup` Signet project, and enforce its permissions (SERV-214).
#
# `signet render` does NOT set a restrictive mode on the file it writes —
# measured directly against the real binary (2026-09-26): a fresh render into
# an empty directory came out 0664, driven by the calling process's ambient
# umask, not anything signet itself enforces. That is the one thing standing
# between this and a credential file that is briefly group/world-readable, so
# this wrapper is the only supported way to render it — never call
# `signet render -project construct-backup` directly.
#
# There is deliberately no timer for this. These credentials (the hub's
# password, and each destination's) change rarely, and a render should
# follow a deliberate `signet set`/`generate`/`rotate`, not run on a
# schedule against whatever the vault happens to hold.
#
# Usage: ./render-backup-env.sh   (run on the box, as the user backup-nightly
#                                   runs as — matching {{ construct_backup_user
#                                   }} in ansible/roles/construct_backup)
set -euo pipefail

TARGET=/etc/construct-backup/backup.env

command -v signet >/dev/null 2>&1 \
  || { echo "render-backup-env: signet is not on PATH" >&2; exit 1; }

[ -d "$(dirname "$TARGET")" ] \
  || { echo "render-backup-env: $(dirname "$TARGET") does not exist — apply the construct_backup ansible role first (ansible-playbook ansible/site.yml --tags construct_backup -K)" >&2; exit 1; }

signet render -project construct-backup
chmod 0600 "$TARGET"

echo "rendered and secured $TARGET:"
ls -l "$TARGET"
