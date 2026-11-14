#!/usr/bin/env bash
# Create the data-root directories genzo and trestle-genzo bind (GENZO-8).
# Both binds use create_host_path: false, so `up -d` fails until these exist.
# Idempotent: re-running fixes owner and mode and never touches the contents.
#
#   sudo ./scripts/genzo-data-dirs.sh            # /srv/genzo
#   sudo ./scripts/genzo-data-dirs.sh /mnt/x     # another root (then set GENZO_DATA_DIR_HOST)
#   ./scripts/genzo-data-dirs.sh --check         # no sudo: report only, exit 1 if anything is off
set -euo pipefail

CHECK=0
if [[ "${1:-}" == "--check" ]]; then CHECK=1; shift; fi
ROOT="${1:-${GENZO_DATA_DIR_HOST:-/srv/genzo}}"
SVC_UID=10001          # the uid both images run as
INBOX_OWNER="${SUDO_USER:-magos}"

[[ "$ROOT" == /* && "$ROOT" != "/" ]] || { echo "refusing root '$ROOT': need an absolute path that is not /" >&2; exit 2; }
id "$INBOX_OWNER" >/dev/null 2>&1 || { echo "no such user: $INBOX_OWNER" >&2; exit 2; }

# path  owner  group  mode
want() {
  cat <<EOF
$ROOT root root 755
$ROOT/trestle $SVC_UID $SVC_UID 700
$ROOT/derive-tmp $SVC_UID $SVC_UID 700
$ROOT/inbox $INBOX_OWNER $SVC_UID 2750
EOF
}

uidof() { [[ "$1" =~ ^[0-9]+$ ]] && echo "$1" || id -u "$1"; }
gidof() { [[ "$1" =~ ^[0-9]+$ ]] && echo "$1" || getent group "$1" | cut -d: -f3; }

bad=0
report() {
  while read -r p o g m; do
    if [[ ! -d "$p" ]]; then echo "MISSING  $p"; bad=1; continue; fi
    have="$(stat -c '%u %g %a' "$p")"; need="$(uidof "$o") $(gidof "$g") $m"
    if [[ "$have" == "$need" ]]; then echo "ok       $p ($have)"; else echo "WRONG    $p has '$have', want '$need'"; bad=1; fi
  done < <(want)
}

if (( CHECK )); then report; exit "$bad"; fi

(( EUID == 0 )) || { echo "run with sudo (or --check to only look)" >&2; exit 2; }
while read -r p o g m; do
  [[ -e "$p" && ! -d "$p" ]] && { echo "$p exists and is not a directory" >&2; exit 1; }
  install -d -o "$o" -g "$g" -m "$m" "$p"
done < <(want)
report
(( bad == 0 )) || exit 1
echo "free on $(df -P "$ROOT" | awk 'NR==2{print $6": "int($4/1048576)" GiB"}') (the quota arithmetic in docker-compose.yml assumed ~193 GiB)"
