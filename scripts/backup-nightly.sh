#!/usr/bin/env bash
# backup-nightly.sh — Nightly Postgres backup producer (SERV-43).
#
# Dumps every configured cluster's non-template databases plus globals, snapshots
# them into a local restic hub on /data, retains and integrity-checks the hub, and
# fans out to append-only destinations via `restic copy`. Design of record and the
# reasoning behind every choice below: docs/backups.md.
#
# Usage:
#   ./backup-nightly.sh                       run the nightly job
#   ./backup-nightly.sh init-hub               one-time: create the hub repository
#   ./backup-nightly.sh verify-destination N   occasional: prove append-only
#                                               still holds for destination N
#
# Env overrides (mainly for testing — see scripts/backup-test.sh):
#   BACKUP_CONF        path to backup.conf              (default: ../config/backup/backup.conf)
#   BACKUP_ENV_FILE     path to the credential file       (default: /etc/construct-backup/backup.env)
#   BACKUP_STATE_DIR    host state directory              (default: /var/lib/construct-backup)
#   BACKUP_DATA_DIR     where the hub and staging live     (default: /data/backups)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BACKUP_CONF="${BACKUP_CONF:-$SCRIPT_DIR/../config/backup/backup.conf}"
BACKUP_ENV_FILE="${BACKUP_ENV_FILE:-/etc/construct-backup/backup.env}"
BACKUP_STATE_DIR="${BACKUP_STATE_DIR:-/var/lib/construct-backup}"
BACKUP_DATA_DIR="${BACKUP_DATA_DIR:-/data/backups}"

STATE_FILE="$BACKUP_STATE_DIR/state.json"
LOCK_FILE="$BACKUP_STATE_DIR/backup.lock"
HUB_REPO="$BACKUP_DATA_DIR/restic-hub"
STAGING_DIR="$BACKUP_DATA_DIR/staging"

err()  { printf '%s\n' "$*" >&2; }

# print_lines <arg...> — like `printf '%s\n'`, except a call with ZERO
# arguments prints nothing. `printf '%s\n'` alone still runs its format once
# against an empty string, so a genuinely empty array (`printf '%s\n'
# "${empty_arr[@]}"`) prints one phantom blank line — measured, not assumed —
# which is exactly the kind of spurious "difference" the reconciliation check
# below exists to catch, so it must not produce one of its own.
print_lines() { [ "$#" -eq 0 ] && return 0; printf '%s\n' "$@"; }
die()  { err "backup-nightly: $*"; exit 1; }

# ─── config + credentials ───────────────────────────────────────────────────

[ -f "$BACKUP_CONF" ] || die "no config at $BACKUP_CONF"
# shellcheck disable=SC1090
. "$BACKUP_CONF"

[[ "$RESTIC_IMAGE" == *@sha256:* ]] \
  || die "RESTIC_IMAGE ($RESTIC_IMAGE) has no @sha256: digest — a tag alone is not a pin (SERV-105)"

# An empty or unset credential is not a value (the estate's own db/init-db.sh
# invariant) — read it as absent, never proceed with a blank one silently.
if [ -f "$BACKUP_ENV_FILE" ]; then
  # `signet render` does NOT enforce a restrictive mode on an EXISTING file
  # — it sets 0600 only when creating one fresh, and otherwise keeps
  # whatever mode was already there (measured directly against the real
  # binary; PR #228's review corrected this comment's first, wrong guess
  # that it was the calling process's umask). Whatever the actual cause on
  # a given box, this would otherwise be the one place a wrong assumption
  # from the plan (that Signet delivers this file at 0600) turns into a real
  # credential exposure rather than a config mismatch — so it's checked
  # here rather than trusted. scripts/render-backup-env.sh is the wrapper
  # that chmods after every render; this is the backstop if that step is
  # ever skipped or a future render silently reverts it.
  actual_mode="$(stat -c %a "$BACKUP_ENV_FILE")"
  [ "$actual_mode" = "600" ] \
    || die "$BACKUP_ENV_FILE is mode $actual_mode, not 600 — refusing to source a credential file that isn't private. Run scripts/render-backup-env.sh, which renders AND chmods."
  set -a
  # shellcheck disable=SC1090
  . "$BACKUP_ENV_FILE"
  set +a
fi

# ─── state.json — read/write helpers ────────────────────────────────────────
#
# Written atomically (tmp file + mv) so a killed run never leaves a half-written
# file behind for the next run to choke on. jq owns both the default shape and
# every read/update, so there is exactly one place that knows the schema.

state_init_if_missing() {
  mkdir -p "$BACKUP_STATE_DIR"
  [ -f "$STATE_FILE" ] && return 0
  cat >"$STATE_FILE" <<'JSON'
{
  "hub": {"read_data_cursor": 1, "last_check_at": null, "last_readdata_at": null},
  "preflight_failed_count": 0,
  "destinations": {}
}
JSON
}

# state_get <jq filter>
state_get() { jq -r "$1" "$STATE_FILE"; }

# state_update <jq filter> — filter receives "." as the current state and must
# emit the new state. Written to a tmp file in the same directory, then
# renamed, so a crash mid-write cannot leave a torn state.json.
#
# Fails closed on jq itself failing, for any reason — not just the specific
# missing-STATE_FILE case that motivated it (PR review round 2). The
# unconditional `mv` this replaces moved jq's tmp file into place whether jq
# succeeded or not, and a failed jq run's tmp file is a 0-byte file (jq wrote
# nothing to it before exiting), so ANY future jq failure — a bad filter, a
# permissions problem, a full disk mid-write — would have corrupted a working
# state.json into an empty one with no error surfaced anywhere.
state_update() {
  local tmp
  tmp="$(mktemp "$BACKUP_STATE_DIR/state.json.XXXXXX")"
  if ! jq "$1" "$STATE_FILE" >"$tmp"; then
    rm -f "$tmp"
    die "state_update failed (jq filter: $1) — state.json left untouched"
  fi
  mv -f "$tmp" "$STATE_FILE"
}

# ─── preflight ───────────────────────────────────────────────────────────────
#
# Two kinds of check, deliberately not mixed: static misconfiguration (wrong
# device, bad digest) fails immediately — retrying a config file for 20 minutes
# helps nobody. Transient unreadiness (docker/tailscale/postgres not up yet,
# relevant mainly right after boot) gets one bounded retry loop, counted inside
# the unit's own TimeoutStartSec (SERV-214), not a systemd-level restart — see
# docs/backups.md for why: RestartForceExitStatus= is refused outright on a
# Type=oneshot unit, and any restart mechanism that DOES work re-executes the
# whole script, which would double-count consecutive_misses.

preflight_static() {
  mkdir -p "$BACKUP_DATA_DIR"
  local hub_dev root_dev
  hub_dev="$(stat -c %d "$BACKUP_DATA_DIR")"
  root_dev="$(stat -c %d "$(docker info --format '{{.DockerRootDir}}')")"
  [ "$hub_dev" != "$root_dev" ] \
    || die "$BACKUP_DATA_DIR is on the same block device as Docker's root ($root_dev) — the hub must survive losing the disk the database lives on"
}

# admin_user_for_label <label> — the superuser role to connect as for this
# cluster. Found the hard way, against the real box (2026-09-26): the official
# postgres image creates whatever role POSTGRES_USER names, not necessarily
# one literally called "postgres" — argosy-db-1 runs POSTGRES_USER=argosy, so
# `-U postgres` against it fails with "role \"postgres\" does not exist" even
# though the connection itself works fine. Defaults to "postgres" (true for
# the shared cluster) so only a cluster that actually differs needs an entry.
admin_user_for_label() {
  local label="$1" upper var
  upper="$(printf '%s' "$label" | tr '[:lower:]' '[:upper:]')"
  var="BACKUP_ADMIN_USER_${upper}"
  printf '%s' "${!var:-postgres}"
}

# One readiness probe. Echoes a reason on failure, prints nothing on success.
preflight_probe() {
  docker info >/dev/null 2>&1 || { echo "docker not reachable"; return 1; }
  tailscale status >/dev/null 2>&1 || { echo "tailscale not reachable"; return 1; }
  local entry container label admin_user
  for entry in "${BACKUP_CLUSTERS[@]}"; do
    container="${entry%%:*}"; label="${entry#*:}"
    admin_user="$(admin_user_for_label "$label")"
    docker exec "$container" pg_isready -U "$admin_user" >/dev/null 2>&1 \
      || { echo "$container: pg_isready failing"; return 1; }
  done
  return 0
}

preflight_retry_loop() {
  local deadline reason
  deadline=$(( $(date +%s) + BACKUP_PREFLIGHT_MAX_SEC ))
  while true; do
    if reason="$(preflight_probe)"; then
      return 0
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      err "preflight: exhausted ${BACKUP_PREFLIGHT_MAX_SEC}s waiting on: $reason"
      state_update '.preflight_failed_count += 1'
      return 1
    fi
    sleep 10
  done
}

# ─── staging ─────────────────────────────────────────────────────────────────
#
# Plaintext dumps of purser, authentik and chronicle live here briefly. Cleaned
# at the START of every run (a killed run's leftovers must not outlive it by a
# single extra night) and on EXIT via trap (normal completion or failure).

staging_cleanup() { rm -rf "$STAGING_DIR"; }

staging_setup() {
  staging_cleanup
  mkdir -p "$STAGING_DIR"
  chmod 0700 "$STAGING_DIR"
  trap staging_cleanup EXIT
}

# ─── docker/restic invocation helpers ───────────────────────────────────────
#
# Every restic call runs in a container THIS SCRIPT starts and is responsible
# for removing — never touching a Postgres server container, which the script
# only ever `docker exec`s into. A fixed container name plus an unconditional
# `docker rm -f` both before AND after every invocation means a `kill -9` mid
# run, or a timeout expiring, can never leave a restic container (and the repo
# lock it may be holding) behind for the next run to trip over.

RESTIC_CONTAINER_NAME="backup-nightly-restic"

# run_restic <restic args...> — env vars the caller already exported
# (RESTIC_REPOSITORY, RESTIC_PASSWORD, etc.) are inherited by `docker run`
# because they are passed BY NAME (`-e VAR`, no `=value`): the value is read
# from this script's own environment and never appears as a literal argument,
# so it cannot show up in `ps` on this host or in a container inspect either.
run_restic() {
  docker rm -f "$RESTIC_CONTAINER_NAME" >/dev/null 2>&1 || true
  local rc=0
  local -a env_flags
  readarray -t env_flags < <(restic_env_flags)
  # `--network host` shares the network namespace ONLY — the container's
  # filesystem is otherwise its own, with no view of the host's /data at all.
  # Found by the real smoke test (2026-09-26), not by make backup-test: the
  # mock never launches a real container, so nothing there could have caught
  # a missing bind mount. Both the hub repo AND the staging tree it reads
  # from live under $BACKUP_DATA_DIR, so mounting that one directory at the
  # same path covers both without any path translation elsewhere.
  #
  # `--user`, same discovery: the restic image runs as root by default, and a
  # bind mount does no UID remapping — root inside the container writes
  # root-owned files straight onto the host disk. That is unreadable by
  # whatever this script runs as on every LATER invocation (a check, a forget,
  # a second night's backup), not just an ownership nit on the first one.
  # Matching the invoking user is what makes the repo usable again afterwards.
  #
  # `HOME`, same root cause: with no passwd entry for an arbitrary --user UID,
  # restic's own HOME defaults to "/", so it tries "/.cache" and warns
  # ("unable to open cache") on every single invocation — harmless but noisy,
  # and slower than it needs to be since restic re-fetches what a cache would
  # have kept. Pointed at $BACKUP_DATA_DIR, already ours and already mounted.
  timeout "$BACKUP_RESTIC_TIMEOUT_SEC" \
    docker run --name "$RESTIC_CONTAINER_NAME" --rm --network host \
      --user "$(id -u):$(id -g)" \
      -e HOME="$BACKUP_DATA_DIR" \
      -v "$BACKUP_DATA_DIR:$BACKUP_DATA_DIR" \
      "${env_flags[@]}" \
      "$RESTIC_IMAGE" "$@" \
    || rc=$?
  docker rm -f "$RESTIC_CONTAINER_NAME" >/dev/null 2>&1 || true
  return $rc
}

# The set of `-e NAME` flags for whichever restic env vars are currently set —
# valueless, so docker reads each value from this shell's environment rather
# than from the flag itself.
restic_env_flags() {
  local var flags=()
  for var in RESTIC_REPOSITORY RESTIC_PASSWORD RESTIC_FROM_REPOSITORY \
             RESTIC_FROM_PASSWORD RESTIC_REST_USERNAME RESTIC_REST_PASSWORD; do
    [ -n "${!var:-}" ] && flags+=("-e" "$var")
  done
  print_lines "${flags[@]}"
}

# ─── enumerate, exclude, floor, dump ─────────────────────────────────────────

# matches_any_pattern <name> <pattern...>
matches_any_pattern() {
  local name="$1"; shift
  local pat
  for pat in "$@"; do
    # shellcheck disable=SC2053
    [[ "$name" == $pat ]] && return 0
  done
  return 1
}

ANY_DUMP_FAILED=0
FAILED_DATABASES=()

# dump_cluster <container> <label>
# Populates $STAGING_DIR/<label>/ and returns the list of dumped db names on
# stdout, one per line. Sets ANY_DUMP_FAILED / FAILED_DATABASES on a failure
# but never aborts — the databases that DID dump correctly still get snapshotted.
dump_cluster() {
  local container="$1" label="$2" upper floor_var admin_user
  upper="$(printf '%s' "$label" | tr '[:lower:]' '[:upper:]')"
  floor_var="BACKUP_MUST_DUMP_${upper}"
  # Nameref, not eval-with-a-constructed-string: aliases `floor` to whichever
  # BACKUP_MUST_DUMP_<LABEL> array backup.conf defined for this cluster.
  local -n floor="$floor_var"
  admin_user="$(admin_user_for_label "$label")"

  local cluster_dir="$STAGING_DIR/$label"
  mkdir -p "$cluster_dir"

  local all
  all="$(docker exec "$container" psql -U "$admin_user" -At \
    -c "select datname from pg_database where not datistemplate order by 1")"

  local -a dumped=() excluded=()
  local name
  while IFS= read -r name; do
    [ -z "$name" ] && continue
    if matches_any_pattern "$name" "${BACKUP_EXCLUDE_PATTERNS[@]}"; then
      excluded+=("$name")
    else
      dumped+=("$name")
    fi
  done <<<"$all"

  # The floor is enforced against what enumeration actually found — a floor
  # name that no longer exists in the cluster is exactly the silent-drift case
  # this check exists to catch, not something to paper over.
  local missing=() f
  for f in "${floor[@]}"; do
    if ! printf '%s\n' "${dumped[@]}" | grep -qxF "$f"; then
      missing+=("$f")
    fi
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    err "$label: must-dump floor not covered: ${missing[*]}"
    ANY_DUMP_FAILED=1
    FAILED_DATABASES+=("${missing[@]/#/$label:}")
  fi

  # Tripwire, not expected to ever fire: dumped and excluded are complementary
  # by construction (every name from enumeration lands in exactly one of the
  # two sets above). Re-derive the full set independently and diff, so a bug
  # in that construction would still be caught rather than assumed away.
  local reconciled
  reconciled="$( { print_lines "${dumped[@]}"; print_lines "${excluded[@]}"; } | sort)"
  if [ "$(printf '%s\n' "$all" | sort)" != "$(printf '%s\n' "$reconciled" | sort)" ]; then
    die "$label: dumped+excluded does not reconcile with pg_database — this is a bug in the script, not the data"
  fi

  local n
  for n in "${excluded[@]}"; do
    [ -z "$n" ] && continue
    local size
    size="$(docker exec "$container" psql -U "$admin_user" -At \
      -c "select pg_database_size('$n')" 2>/dev/null || echo unknown)"
    err "$label: excluded '$n' (${size} bytes)"
  done

  local client_ver server_ver
  client_ver="$(docker exec "$container" pg_dump --version | grep -oE '[0-9]+' | head -1)"
  server_ver="$(docker exec "$container" psql -U "$admin_user" -At -c "show server_version_num" | cut -c1-2)"
  if [ "$client_ver" != "$server_ver" ]; then
    err "$label: pg_dump major $client_ver != server major $server_ver — dumper is not the server's own binary?"
    ANY_DUMP_FAILED=1
  fi

  for n in "${dumped[@]}"; do
    [ -z "$n" ] && continue
    local out="$cluster_dir/$n.dump"
    if docker exec "$container" sh -c "timeout ${BACKUP_PG_DUMP_TIMEOUT_SEC} pg_dump -Fc -Z0 -U ${admin_user} -d '$n'" >"$out" \
       && [ -s "$out" ]; then
      err "$label: dumped '$n' ($(stat -c %s "$out") bytes)"
    else
      err "$label: FAILED to dump '$n'"
      rm -f "$out"
      ANY_DUMP_FAILED=1
      FAILED_DATABASES+=("$label:$n")
    fi
  done

  local globals_out="$cluster_dir/globals.sql"
  if ! docker exec "$container" sh -c "timeout ${BACKUP_PG_DUMP_TIMEOUT_SEC} pg_dumpall --globals-only -U ${admin_user}" >"$globals_out" \
     || [ ! -s "$globals_out" ]; then
    err "$label: FAILED to dump globals"
    rm -f "$globals_out"
    ANY_DUMP_FAILED=1
    FAILED_DATABASES+=("$label:globals")
  fi
}

# ─── hub: snapshot, retention, integrity ─────────────────────────────────────

declare -A HUB_SNAPSHOT_ID

hub_backup_cluster() {
  local label="$1"
  RESTIC_REPOSITORY="$HUB_REPO" RESTIC_PASSWORD="${RESTIC_PASSWORD_HUB:-}" \
    run_restic backup --tag "$label" "$STAGING_DIR/$label" \
    || die "hub backup failed for cluster '$label' — refusing to continue (a hub failure exits immediately)"
  # Tonight's own snapshot id for this cluster, on the hub — what fan-out
  # later checks a destination's copy actually landed, rather than accepting
  # any snapshot merely carrying the right tag (PR review finding #3).
  HUB_SNAPSHOT_ID["$label"]="$(RESTIC_REPOSITORY="$HUB_REPO" RESTIC_PASSWORD="${RESTIC_PASSWORD_HUB:-}" \
    run_restic snapshots --tag "$label" --json 2>/dev/null | jq -r 'sort_by(.time) | last | .id // empty')"
  [ -n "${HUB_SNAPSHOT_ID[$label]}" ] \
    || die "hub backup for '$label' reported success but no snapshot is findable afterward — refusing to continue"
}

hub_retain() {
  RESTIC_REPOSITORY="$HUB_REPO" RESTIC_PASSWORD="${RESTIC_PASSWORD_HUB:-}" \
    run_restic forget --prune --group-by host,tags \
      --keep-daily "$BACKUP_RETENTION_DAILY" --keep-weekly "$BACKUP_RETENTION_WEEKLY" \
    || die "hub retention (forget --prune) failed — refusing to continue"
}

# Weekly full check, monthly deterministic 1/12 read-data-subset — the cursor
# in state.json (not the calendar) is what guarantees full coverage over a
# year: a month that fails or is skipped leaves that slice due again, rather
# than permanently unread.
hub_integrity() {
  local last_check now_epoch check_epoch
  last_check="$(state_get '.hub.last_check_at')"
  now_epoch="$(date +%s)"
  if [ "$last_check" = "null" ]; then
    check_epoch=0
  else
    check_epoch="$(date -d "$last_check" +%s)"
  fi
  if [ $(( now_epoch - check_epoch )) -ge $(( 7 * 86400 )) ]; then
    RESTIC_REPOSITORY="$HUB_REPO" RESTIC_PASSWORD="${RESTIC_PASSWORD_HUB:-}" \
      run_restic check \
      || die "weekly hub check failed — refusing to continue"
    state_update ".hub.last_check_at = \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""
  fi

  local last_readdata this_month readdata_month
  last_readdata="$(state_get '.hub.last_readdata_at')"
  this_month="$(date -u +%Y-%m)"
  if [ "$last_readdata" = "null" ]; then
    readdata_month=""
  else
    readdata_month="$(date -u -d "$last_readdata" +%Y-%m)"
  fi
  if [ "$this_month" != "$readdata_month" ]; then
    local cursor
    cursor="$(state_get '.hub.read_data_cursor')"
    if RESTIC_REPOSITORY="$HUB_REPO" RESTIC_PASSWORD="${RESTIC_PASSWORD_HUB:-}" \
       run_restic check "--read-data-subset=${cursor}/12"; then
      local next=$(( cursor >= 12 ? 1 : cursor + 1 ))
      state_update ".hub.read_data_cursor = $next | .hub.last_readdata_at = \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""
    else
      die "monthly read-data-subset check (slice ${cursor}/12) failed — refusing to continue"
    fi
  fi
}

# ─── fan-out ─────────────────────────────────────────────────────────────────
#
# Report-versus-observation (PRINCIPLES §4), applied to backups: this script's
# own memory of having run `copy` is a claim. The destination's own snapshot
# list, read back from the destination, is the observation — the only thing
# actually recorded as "last success".

ANY_THRESHOLD_TRIPPED=0

# copy_one_cluster <url> <dest_pw> <dest_user> <dest_pass> <label> — one
# retry-then-give-up attempt at copying a single cluster's tag to a
# destination, verified against the HUB's OWN snapshot id for that cluster
# tonight (captured in HUB_SNAPSHOT_ID by hub_backup_cluster) — not against
# "any snapshot the destination happens to have with the right tag", which a
# stale copy from a previous night would also satisfy (PR review finding #3).
# Echoes nothing; returns 0 only once tonight's snapshot is confirmed present.
copy_one_cluster() {
  local url="$1" dest_pw="$2" dest_user="$3" dest_pass="$4" label="$5" name="$6"
  local ok=0 attempt
  for attempt in 1 2; do
    if RESTIC_REPOSITORY="$url" RESTIC_PASSWORD="$dest_pw" \
       RESTIC_FROM_REPOSITORY="$HUB_REPO" RESTIC_FROM_PASSWORD="${RESTIC_PASSWORD_HUB:-}" \
       RESTIC_REST_USERNAME="$dest_user" RESTIC_REST_PASSWORD="$dest_pass" \
       run_restic copy --tag "$label"; then
      ok=1
      break
    fi
    err "$name: copy attempt $attempt failed for cluster '$label'"
  done
  [ "$ok" -eq 1 ] || return 1

  local hub_id match_count
  hub_id="${HUB_SNAPSHOT_ID[$label]:-}"
  match_count="$(RESTIC_REPOSITORY="$url" RESTIC_PASSWORD="$dest_pw" \
    RESTIC_REST_USERNAME="$dest_user" RESTIC_REST_PASSWORD="$dest_pass" \
    run_restic snapshots --tag "$label" --json 2>/dev/null \
    | jq -r --arg hid "$hub_id" '[.[] | select(.original == $hid or .id == $hid)] | length')"
  if [ -n "$hub_id" ] && [ "${match_count:-0}" -gt 0 ] 2>/dev/null; then
    return 0
  fi
  err "$name: copy exited 0 but no snapshot at the destination matches tonight's hub snapshot for '$label' — treating as a miss"
  return 1
}

# fanout_destination <spec> <label...> — one destination, EVERY configured
# cluster, aggregated into a single per-night result. A destination that
# serves two clusters gets one attempt and one miss/success per RUN, not one
# per (cluster × destination) pair — the previous shape both tripped the miss
# threshold too early (2 clusters down all night = 2 misses on night one, not
# one) and hid a permanently failing cluster behind another that kept
# succeeding, since the second call always reset consecutive_misses to 0 and
# stamped last_success_at regardless of the first (PR review finding #2).
fanout_destination() {
  local spec="$1"; shift
  local name url upper
  name="${spec%%:*}"
  url="${spec#*:}"
  upper="$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9' '_')"

  local dest_pw dest_user dest_pass
  dest_pw="$(eval "printf '%s' \"\${RESTIC_PASSWORD_${upper}:-}\"")"
  dest_user="$(eval "printf '%s' \"\${REST_USER_${upper}:-}\"")"
  dest_pass="$(eval "printf '%s' \"\${REST_PASSWORD_${upper}:-}\"")"

  local all_ok=1 label
  for label in "$@"; do
    copy_one_cluster "$url" "$dest_pw" "$dest_user" "$dest_pass" "$label" "$name" || all_ok=0
  done

  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  state_update ".destinations[\"$name\"] //= {\"last_attempt_at\": null, \"last_success_at\": null, \"consecutive_misses\": 0}"
  state_update ".destinations[\"$name\"].last_attempt_at = \"$now\""

  if [ "$all_ok" -eq 1 ]; then
    state_update ".destinations[\"$name\"].last_success_at = \"$now\" | .destinations[\"$name\"].consecutive_misses = 0"
    return 0
  fi

  local misses
  state_update ".destinations[\"$name\"].consecutive_misses += 1"
  misses="$(state_get ".destinations[\"$name\"].consecutive_misses")"
  err "$name: attempted-and-failed overall tonight (consecutive_misses=$misses)"
  if [ "$misses" -ge "$BACKUP_CONSECUTIVE_MISS_THRESHOLD" ]; then
    ANY_THRESHOLD_TRIPPED=1
  fi
}

# ─── destination append-only proof (SERV-215) ───────────────────────────────
#
# `fanout_destination` above only ever ADDS to a destination — it has no
# reason to ever discover whether append-only has quietly been turned off.
# This proves it, from the credential path the nightly job actually uses
# (over the tailnet, with the destination's real REST credentials), which is
# NOT what backup-receiver/install.sh's own `verify` proves: that one runs ON
# the receiver host itself, against the docker bridge address, as a one-time
# setup check. This is the ongoing one — meant to be re-run occasionally by
# hand, never wired into cmd_run, and never exercised by backup-test.sh's
# mock suite (see that file's header for why).
#
# Uses a FIXED, REUSED probe repository — a sibling of the real one on the
# same REST server, never the real repository itself. Idempotent: the probe
# repo is created only if it doesn't already exist; the fixture it backs up
# is the same few bytes every time, so repeated runs cost nothing new to
# store (restic dedups identical content) beyond one small snapshot entry.
VERIFY_PROBE_FIXTURE_CONTENT="backup-nightly verify-destination fixture (SERV-215) — do not delete by hand"

cmd_verify_destination() {
  local name="${1:-}"
  [ -n "$name" ] || die "verify-destination needs a destination name, e.g.: $0 verify-destination desk"

  # The SAME lock cmd_run takes, before the first run_restic call. Every
  # run_restic invocation opens with `docker rm -f "$RESTIC_CONTAINER_NAME"`
  # against a FIXED name (backup-nightly-restic) — with no lock here, a
  # hand-run verify-destination during the nightly window force-removes
  # whichever restic container the real run is mid-operation with, and a kill
  # landing during the real run's own `forget`/`copy` corrupts that run rather
  # than merely being refused (PR #230 review). This makes the two mutually
  # exclusive, the same as two real runs of cmd_run.
  mkdir -p "$BACKUP_STATE_DIR"
  exec 200>"$LOCK_FILE"
  flock -n 200 || die "verify-destination($name): a nightly run is in progress ($LOCK_FILE) — retry after it finishes"

  local spec="" d
  for d in "${BACKUP_DESTINATIONS[@]}"; do
    [ "${d%%:*}" = "$name" ] && spec="$d"
  done
  [ -n "$spec" ] || die "no destination named '$name' in BACKUP_DESTINATIONS"

  local url upper dest_pw dest_user dest_pass
  url="${spec#*:}"
  upper="$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9' '_')"
  dest_pw="$(eval "printf '%s' \"\${RESTIC_PASSWORD_${upper}:-}\"")"
  dest_user="$(eval "printf '%s' \"\${REST_USER_${upper}:-}\"")"
  dest_pass="$(eval "printf '%s' \"\${REST_PASSWORD_${upper}:-}\"")"
  [ -n "$dest_pw" ] || die "RESTIC_PASSWORD_${upper} is empty/unset"

  # A sibling path on the same REST server — same host:port, never the real
  # repo name. Works for any "rest:http://host:port/reponame/" url, which is
  # the only shape a destination in this file ever takes.
  local base probe_repo probe_http
  base="${url%/}"; base="${base%/*}"
  probe_repo="${base}/backup-nightly-verify-probe/"
  probe_http="${probe_repo#rest:}"

  local fixture="$BACKUP_DATA_DIR/verify-probe-fixture"
  mkdir -p "$BACKUP_DATA_DIR"
  printf '%s\n' "$VERIFY_PROBE_FIXTURE_CONTENT" >"$fixture"

  if ! RESTIC_REPOSITORY="$probe_repo" RESTIC_PASSWORD="$dest_pw" \
       RESTIC_REST_USERNAME="$dest_user" RESTIC_REST_PASSWORD="$dest_pass" \
       run_restic snapshots >/dev/null 2>&1; then
    err "verify-destination($name): probe repository absent — initializing $probe_repo"
    RESTIC_REPOSITORY="$probe_repo" RESTIC_PASSWORD="$dest_pw" \
      RESTIC_REST_USERNAME="$dest_user" RESTIC_REST_PASSWORD="$dest_pass" \
      run_restic init \
      || die "verify-destination($name): could not initialize the probe repository"
  fi

  RESTIC_REPOSITORY="$probe_repo" RESTIC_PASSWORD="$dest_pw" \
    RESTIC_REST_USERNAME="$dest_user" RESTIC_REST_PASSWORD="$dest_pass" \
    run_restic backup --tag verify-probe "$fixture" \
    || die "verify-destination($name): backing up the probe fixture failed — is the receiver reachable?"

  local failed=0

  # `forget <id>` — an EXPLICIT snapshot id, not a retention policy. `--keep-last
  # 0` is that flag's zero value, which restic reads as "not set" and refuses
  # with "no policy was specified" before it ever touches the repository — a
  # refusal that looks identical whether or not append-only is even on (PR
  # #230 review, reproduced against a plain local repo with no append-only
  # anywhere: `Fatal: no policy was specified, no snapshots will be removed`,
  # exit 1). An explicit id has no policy to evaluate, so restic issues the
  # DELETE unconditionally.
  local snap_id
  snap_id="$(RESTIC_REPOSITORY="$probe_repo" RESTIC_PASSWORD="$dest_pw" \
    RESTIC_REST_USERNAME="$dest_user" RESTIC_REST_PASSWORD="$dest_pass" \
    run_restic snapshots --tag verify-probe --latest 1 --json 2>/dev/null \
    | jq -r '.[0].id // empty')"
  [ -n "$snap_id" ] || die "verify-destination($name): could not read back the snapshot just backed up"

  # `forget`'s own EXIT CODE is not trustworthy here — measured directly, not
  # assumed. Against a receiver that refuses the delete with 403, restic logs
  # "unable to remove snapshot ... from the repository" to stderr and STILL
  # exits 0 (confirmed on the pinned restic/restic:0.18.1, forget always
  # exits 0 whether or not the underlying remove succeeded). So this ignores
  # forget's exit status and instead re-reads the snapshot list afterward,
  # asking whether the snapshot is STILL there — report-vs-observation
  # (PRINCIPLES §4), the same shape `copy_one_cluster`'s own freshness check
  # already uses, rather than trusting what the command claims.
  RESTIC_REPOSITORY="$probe_repo" RESTIC_PASSWORD="$dest_pw" \
    RESTIC_REST_USERNAME="$dest_user" RESTIC_REST_PASSWORD="$dest_pass" \
    run_restic forget "$snap_id" >/dev/null 2>&1 || true

  local still_present
  still_present="$(RESTIC_REPOSITORY="$probe_repo" RESTIC_PASSWORD="$dest_pw" \
    RESTIC_REST_USERNAME="$dest_user" RESTIC_REST_PASSWORD="$dest_pass" \
    run_restic snapshots --json 2>/dev/null \
    | jq -r --arg id "$snap_id" '[.[] | select(.id == $id)] | length')"

  if [ "${still_present:-0}" -gt 0 ] 2>/dev/null; then
    err "verify-destination($name): ok — snapshot survived 'restic forget' (append-only holds)"
  else
    err "verify-destination($name): FAIL — snapshot is GONE after 'restic forget' — append-only is NOT in force"
    failed=1
  fi

  # The second, independent proof — same discriminating probe as
  # backup-receiver/install.sh's own verify() and for the same reason:
  # DELETE on the repo root answers 405 whether or not append-only is on,
  # DELETE on .../config is 403 vs 200 and is the one that discriminates.
  local code
  code="$(printf 'user = "%s:%s"\n' "$dest_user" "$dest_pass" \
    | curl -s -o /dev/null -w '%{http_code}' --max-time 10 -K - -X DELETE "${probe_http}config" || echo 000)"
  case "$code" in
    403) err "verify-destination($name): ok — raw DELETE .../config refused (403)" ;;
    *)   err "verify-destination($name): FAIL — raw DELETE .../config returned $code, expected 403"
         failed=1 ;;
  esac

  [ "$failed" -eq 0 ] || die "verify-destination($name): append-only is not fully proven — see above"
  err "verify-destination($name): append-only confirmed"
}

# ─── main ────────────────────────────────────────────────────────────────────

cmd_init_hub() {
  [ -n "${RESTIC_PASSWORD_HUB:-}" ] || die "RESTIC_PASSWORD_HUB is empty/unset — refusing to init a repo with a blank password"
  mkdir -p "$BACKUP_DATA_DIR"
  RESTIC_REPOSITORY="$HUB_REPO" RESTIC_PASSWORD="$RESTIC_PASSWORD_HUB" \
    run_restic init
}

cmd_run() {
  # Same empty-password guard as cmd_init_hub — a run must not discover a
  # blank RESTIC_PASSWORD_HUB only after every database has already been
  # dumped, which is where restic itself would first complain (PR review
  # nit): an unset/empty credential is never a value (db/init-db.sh's own
  # invariant), so this fails loudly, up front, naming the variable.
  [ -n "${RESTIC_PASSWORD_HUB:-}" ] || die "RESTIC_PASSWORD_HUB is empty/unset — refusing to run"

  preflight_static

  # The lock is taken BEFORE anything that touches state.json or staging —
  # including preflight_retry_loop, which writes preflight_failed_count on
  # exhaustion. Rev 1 of this script took it only just before the dump loop,
  # after `staging_setup` had already `rm -rf`'d the staging directory: a
  # second invocation (a manual run colliding with the timer, or two manual
  # runs) would delete the first run's in-progress dumps, fail its own lock
  # check, and then delete the directory a SECOND time via its own EXIT trap
  # — corrupting run A rather than merely being refused (PR review finding
  # #1). `mkdir` alone is idempotent and cheap enough to do ahead of the lock
  # just so the lock file's own directory is guaranteed to exist.
  mkdir -p "$BACKUP_STATE_DIR"
  exec 200>"$LOCK_FILE"
  flock -n 200 || die "another run is already in progress ($LOCK_FILE)"

  # Also before preflight_retry_loop, which was still missed in the first
  # review round: its own exhaustion path calls `state_update` (records
  # preflight_failed_count), and on a state dir that has never been
  # initialized, `state_init_if_missing` had not yet run either — so
  # `state_update` targeted a STATE_FILE that did not exist at all (PR review
  # round 2). `jq` against a missing file fails, but `state_update` moved its
  # empty tmp file into place regardless, installing a 0-byte state.json.
  # `state_init_if_missing`'s own existence check (`-f`) is satisfied by an
  # empty file just as well as a valid one, so nothing ever replaced it again:
  # the weekly check, the monthly read-data-subset and the miss threshold
  # would all have gone permanently, silently inert on exactly the box that
  # had just rebooted into a not-yet-ready docker/tailscale/postgres — the
  # case the retry loop exists for in the first place. Reproduced directly
  # with the script's own state_update against a missing file before fixing
  # this: `jq` exits 2, and the move still lands a 0-byte file.
  state_init_if_missing
  preflight_retry_loop || exit 1

  staging_setup

  local entry container label
  for entry in "${BACKUP_CLUSTERS[@]}"; do
    container="${entry%%:*}"; label="${entry#*:}"
    dump_cluster "$container" "$label"
    hub_backup_cluster "$label"
  done

  hub_retain
  hub_integrity

  # Every configured cluster's label, passed to each destination as a whole
  # so one destination gets one attempt and one miss/success per NIGHT —
  # never one per (cluster × destination) pair. See fanout_destination.
  local -a all_labels=()
  for entry in "${BACKUP_CLUSTERS[@]}"; do
    all_labels+=("${entry#*:}")
  done
  local dest
  for dest in "${BACKUP_DESTINATIONS[@]}"; do
    [ -z "$dest" ] && continue
    fanout_destination "$dest" "${all_labels[@]}"
  done

  if [ "$ANY_DUMP_FAILED" -eq 1 ]; then
    die "one or more databases failed to dump: ${FAILED_DATABASES[*]}"
  fi
  if [ "$ANY_THRESHOLD_TRIPPED" -eq 1 ]; then
    die "a destination crossed its consecutive-miss threshold"
  fi
}

case "${1:-run}" in
  run) cmd_run ;;
  init-hub) cmd_init_hub ;;
  verify-destination) cmd_verify_destination "${2:-}" ;;
  *) die "unknown command '$1'. Use: run | init-hub | verify-destination <name>" ;;
esac
