#!/usr/bin/env bash
# render-backup-env.sh — render /etc/construct-backup/backup.env from the
# `construct-backup` Signet project, and enforce its permissions (SERV-214).
#
# `signet render` does NOT enforce a restrictive mode on an EXISTING file —
# corrected after PR #228's review measured the real mechanism, which this
# comment first misdiagnosed as the calling process's umask. Signet's own
# atomic-write path sets 0600 on a file it creates fresh, but on a file that
# already exists at the target path it keeps that file's current mode. A
# 0664 result means something already-existing at that path (most likely a
# hand-written seed file created with a plain shell redirect) was 0664 to
# begin with. The chmod below is what actually closes that, every time,
# regardless of how the file got to whatever mode it was in — this wrapper
# is the only supported way to render it; never call
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
