#!/usr/bin/env bash
#
# Stand up a backup destination for the construct-server estate (SERV-43 / SERV-167).
#
#   ./install.sh          preflight, install, and verify
#   ./install.sh verify   re-run the checks against a receiver that already exists
#   ./install.sh status   show what is running and the address to back up to
#
# Run this ON THE DESTINATION HOST (the desktop's WSL2 distro, Arin's server, a
# NAS), not on the construct server. It needs Docker and nothing else from this
# repo — this directory is deliberately self-contained so it can be handed to
# someone who has no access to the estate's infrastructure.

set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BOLD=$'\033[1m'; OFF=$'\033[0m'
ok()   { printf '  %sok%s   %s\n'   "$GREEN"  "$OFF" "$1"; }
warn() { printf '  %swarn%s %s\n'   "$YELLOW" "$OFF" "$1"; }
bad()  { printf '  %sFAIL%s %s\n'   "$RED"    "$OFF" "$1"; }
head_() { printf '\n%s%s%s\n' "$BOLD" "$1" "$OFF"; }
die()  { printf '\n%sAborting:%s %s\n' "$RED" "$OFF" "$1" >&2; exit 1; }

PROBE_REPO="install-probe"

# The helper container that writes the htpasswd file must be the SAME image the
# server runs, so read it out of the compose file rather than restating it. A
# second copy of the pin here would drift from the one that matters, and the
# helper would quietly be a different build of htpasswd than the server reading
# its output.
rest_image() {
  grep -oE 'restic/rest-server:[^[:space:]]+' docker-compose.yml | head -1
}

# ─── preflight ───────────────────────────────────────────────────────────────
# Every check here fails LOUDLY with the fix, rather than letting the install
# proceed to a confusing failure three layers down.
preflight() {
  head_ "Preflight"

  command -v docker >/dev/null 2>&1 \
    || die "docker is not on PATH. On WSL2, enable Docker Desktop's integration for this distro (Settings > Resources > WSL Integration)."
  ok "docker present"

  docker compose version >/dev/null 2>&1 \
    || die "'docker compose' (v2) is not available. The legacy 'docker-compose' script will not work — this file uses v2 syntax."
  ok "docker compose v2 present"

  docker info >/dev/null 2>&1 \
    || die "the docker daemon is not reachable. On WSL2 this usually means Docker Desktop is not running on the Windows side."
  ok "docker daemon reachable"

  command -v curl >/dev/null 2>&1 \
    || die "curl is not installed, and the verification step needs it. Install it: sudo apt-get install -y curl"
  ok "curl present"

  # The sidecar uses kernel networking, which needs a tun device. Checked
  # explicitly so a missing one reads as "no /dev/net/tun" rather than as an
  # opaque tailscale crash loop. Deliberately NOT falling back to userspace
  # mode: an untested fallback that half-works is worse than a clear stop.
  if [ ! -c /dev/net/tun ]; then
    printf '\n'
    bad "/dev/net/tun is missing — tailscale cannot create its interface."
    printf '     Try:  sudo modprobe tun\n'
    printf '     If that fails on WSL2, your kernel lacks TUN support; update WSL:\n'
    printf '       (in Windows PowerShell)  wsl --update\n'
    die "no tun device"
  fi
  ok "/dev/net/tun present"
}

# ─── config ──────────────────────────────────────────────────────────────────
load_config() {
  [ -f .env ] || die ".env not found. Copy .env.example to .env and fill it in first."
  # shellcheck disable=SC1091
  set -a; . ./.env; set +a

  : "${TS_HOSTNAME:?TS_HOSTNAME is not set in .env — this is the name the receiver takes on the tailnet}"
  : "${REST_USER:?REST_USER is not set in .env}"

  if [ -z "${REST_PASSWORD:-}" ]; then
    die "REST_PASSWORD is empty in .env. Generate one with:  openssl rand -base64 24"
  fi
}

compose() { docker compose "$@"; }

# ─── credentials ─────────────────────────────────────────────────────────────
# Written in ONE SHOT from a throwaway container, before the server ever starts.
#
# The image's own documented flow — start the server, then `docker exec
# create_user` — has two traps that cost real time to find:
#   1. create_user fails on a fresh volume ("cannot modify file ... use '-c'"),
#      because it relies on the entrypoint having touched the file first.
#   2. the htpasswd file is read at STARTUP, not per request, so a user created
#      against a running server returns 401 until it is restarted.
# Doing it here, first, sidesteps both.
ensure_credentials() {
  head_ "Credentials"

  docker volume inspect backup_receiver_repo >/dev/null 2>&1 || docker volume create backup_receiver_repo >/dev/null

  # -c truncates, so only use it when there is no file yet. Re-running this
  # script updates the password in place instead of wiping other users.
  local existing flag="-Bb" img
  img=$(rest_image)
  [ -n "$img" ] || die "could not read the rest-server image out of docker-compose.yml"

  existing=$(docker run --rm -v backup_receiver_repo:/data --entrypoint sh \
    "$img" -c 'test -s /data/.htpasswd && echo yes || echo no' 2>/dev/null || echo no)
  [ "$existing" = "yes" ] || flag="-Bbc"

  docker run --rm -v backup_receiver_repo:/data --entrypoint sh \
    "$img" -c \
    "umask 027 && htpasswd $flag /data/.htpasswd \"\$1\" \"\$2\"" _ "$REST_USER" "$REST_PASSWORD" >/dev/null 2>&1 \
    || die "could not write the htpasswd file into the repo volume"

  ok "htpasswd entry for '$REST_USER' (bcrypt)"
}

# ─── bring up ────────────────────────────────────────────────────────────────
bring_up() {
  head_ "Starting the receiver"
  compose up -d
  ok "containers started"

  printf '  waiting for the tailnet address'
  local i ip=""
  for i in $(seq 1 30); do
    ip=$(docker exec backup-tailscale tailscale ip -4 2>/dev/null | head -1 || true)
    [ -n "$ip" ] && break
    printf '.'; sleep 2
  done
  printf '\n'

  if [ -z "$ip" ]; then
    bad "tailscale did not come up with an address."
    printf '     Logs:  docker logs backup-tailscale\n'
    printf '     If it is asking to authenticate, put a fresh key in .env as TS_AUTHKEY\n'
    printf '     (generate at https://login.tailscale.com/admin/settings/keys) and re-run.\n'
    die "no tailnet address"
  fi
  ok "tailnet address: $ip"
}

# The address to probe from THIS host. rest-server lives in tailscale's network
# namespace and binds no host port, so localhost will not reach it — but the
# tailscale container's bridge address will, and that is reachable from here
# without this machine itself being on the tailnet.
local_addr() {
  docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$v.IPAddress}}{{end}}' \
    backup-tailscale 2>/dev/null | head -1
}

probe() { # method url [user:pass] -> prints HTTP status
  local method="$1" url="$2" auth="${3:-}"
  if [ -n "$auth" ]; then
    curl -s -o /dev/null -w '%{http_code}' --max-time 10 -u "$auth" -X "$method" "$url" 2>/dev/null || echo "000"
  else
    curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X "$method" "$url" 2>/dev/null || echo "000"
  fi
}

# ─── verify ──────────────────────────────────────────────────────────────────
# The point of this section is that it can FAIL. A receiver that is merely
# running proves nothing: the two properties worth having are that it demands
# credentials and that append-only is genuinely in force, and both are asserted
# here against the live server rather than inferred from the compose file.
verify() {
  head_ "Verifying"
  local addr base code failed=0
  addr=$(local_addr)
  [ -n "$addr" ] || die "could not find the receiver's address — is it running? (./install.sh status)"
  base="http://${addr}:8000"

  code=$(probe GET "$base/" "$REST_USER:$REST_PASSWORD")
  if [ "$code" = "000" ]; then
    bad "no response from the receiver at $base"
    printf '     Logs:  docker logs backup-rest-server\n'
    return 1
  fi
  ok "receiver responding at $base"

  # Authentication is required.
  code=$(probe POST "$base/anon-check/?create=true")
  if [ "$code" = "401" ]; then ok "unauthenticated request rejected (401)"
  else bad "unauthenticated request returned $code, expected 401 — THE REPOSITORY IS OPEN"; failed=1; fi

  code=$(probe GET "$base/$PROBE_REPO/config" "$REST_USER:definitely-not-the-password")
  if [ "$code" = "401" ]; then ok "wrong password rejected (401)"
  else bad "wrong password returned $code, expected 401"; failed=1; fi

  # Credentials work.
  code=$(probe POST "$base/$PROBE_REPO/?create=true" "$REST_USER:$REST_PASSWORD")
  if [ "$code" = "200" ]; then ok "authenticated write accepted (200)"
  else bad "authenticated repo create returned $code, expected 200 — check REST_USER/REST_PASSWORD in .env"; failed=1; fi

  # ── the append-only proof ──
  #
  # Read this before "simplifying" it. The obvious probe is DELETE on the repo
  # itself, and it is WORTHLESS: deleting a whole repository is not a supported
  # operation, so it answers 405 whether or not append-only is on. A check
  # written that way passes identically on a server with the flag missing, and
  # would certify a repository that anything holding the password could erase.
  #
  # Measured against a control server with the flag off:
  #
  #     DELETE /<repo>/          405 with it on   405 with it off   (useless)
  #     DELETE /<repo>/config    403 with it on   200 with it off   (discriminates)
  #
  # So this asserts 403 on the config object. It holds on an empty repository
  # too — the object need not exist for the refusal to be the answer.
  code=$(probe DELETE "$base/$PROBE_REPO/config" "$REST_USER:$REST_PASSWORD")
  case "$code" in
    403) ok "append-only IS in force (delete refused with 403)" ;;
    200) bad "append-only is NOT in force — a delete was ACCEPTED (200)."
         printf '     The box would be able to erase its own backup history.\n'
         printf '     Check that OPTIONS still contains --append-only in docker-compose.yml.\n'
         failed=1 ;;
    405) bad "got 405 — the probe hit the repo root rather than the config object, so this run proved nothing."
         failed=1 ;;
    *)   bad "delete probe returned $code; expected 403. Treat append-only as unproven."
         failed=1 ;;
  esac

  # The probe repo cannot be removed through the API — that is the whole point —
  # so clean it up on the filesystem, which is reachable from the host.
  docker exec backup-rest-server sh -c "rm -rf /data/$PROBE_REPO /data/anon-check" 2>/dev/null || true

  if [ "$failed" -ne 0 ]; then
    printf '\n%sVerification failed.%s Do not point the construct server at this receiver yet.\n' "$RED" "$OFF"
    return 1
  fi
  printf '\n%sVerification passed.%s\n' "$GREEN" "$OFF"
}

status() {
  head_ "Status"
  compose ps
  local ip
  ip=$(docker exec backup-tailscale tailscale ip -4 2>/dev/null | head -1 || echo "unknown")
  printf '\n  tailnet address : %s\n' "$ip"
  printf '  tailnet name    : %s\n' "${TS_HOSTNAME:-unknown}"
}

next_steps() {
  local ip
  ip=$(docker exec backup-tailscale tailscale ip -4 2>/dev/null | head -1 || echo "<tailnet-ip>")
  cat <<EOF

${BOLD}Receiver is up.${OFF}

  Address on the tailnet : ${ip}  (${TS_HOSTNAME})
  Repository URL         : rest:http://${REST_USER}:<password>@${TS_HOSTNAME}:8000/construct/

${BOLD}Next, on the construct server${OFF} — not here:

  1. Confirm this host is reachable by name:
       tailscale ping ${TS_HOSTNAME}

  2. Create the repository. It MUST be created with the hub's chunker
     parameters, or 'restic copy' re-chunks everything and cross-repo
     dedup collapses. This cannot be corrected later without starting
     the repository over:

       restic -r rest:http://${REST_USER}:<password>@${TS_HOSTNAME}:8000/construct/ \\
         init --copy-chunker-params --from-repo <the local hub repo>

  3. Wire it into the nightly job as a 'restic copy' target (SERV-43).

${BOLD}Re-check this receiver at any time${OFF} with:  ./install.sh verify
EOF
}

case "${1:-install}" in
  install)
    preflight
    load_config
    ensure_credentials
    bring_up
    verify
    next_steps
    ;;
  verify)
    load_config
    verify
    ;;
  status)
    load_config
    status
    ;;
  *)
    die "unknown command '${1}'. Use: install | verify | status"
    ;;
esac
