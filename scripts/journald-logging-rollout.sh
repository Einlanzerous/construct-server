#!/usr/bin/env bash
# journald-logging-rollout.sh — run, and RECORD, the owner steps of the SATL-25 journald canary (wave A:
# satlink logs through journald so its lines survive a recreate). The steps are the owner list in
# docs/journald-logging.md ("Owner-only steps"); this is that list as subcommands, in the shape of
# scripts/traefik-access-log-rollout.sh and scripts/satlink-edge-rollout.sh: phases that each run alone,
# a markdown record per run, PASS / FAIL / PAUSE lines, counts-only evidence, no secrets.
#
#   journald-logging-rollout.sh [flags] <phase>
#
#   preflight    READ-ONLY, always executes, needs no sudo. Baselines: `journalctl --disk-usage`; the oldest
#                journal entry (so we can prove nothing is vacuumed); the two drop-ins absent, or present and
#                byte-identical to ansible/roles/server/files/journald/; LogRateLimitBurst as PID 1 sees it;
#                containers per log driver; satlink's driver, container id and StartedAt; `make journald-check`
#                (non-zero is expected before the merge: satlink is still json-file); whether PR #297 is merged;
#                first-party image drift (a compose merge takes the whole-stack deploy path and recreates every
#                drifted service: pending ones are listed and the run PAUSES).
#   dropin       (--apply, sudo -v up front) `sudo install -d` the two dirs, `sudo install -m 0644` the two repo
#                files, daemon-reload, restart systemd-journald. Asserts the installed files are byte-identical to
#                the repo, journal disk usage not reduced and the oldest entry unchanged (nothing vacuumed), then
#                LogRateLimitBurst 50000 in PID 1 AND in /run/systemd/units/log-rate-limit-burst:docker.service.
#                A wrong/missing value there is a WAVE-C BLOCKER, not a canary blocker (docs): it is recorded as
#                FAIL, the run continues and ends non-zero. Never restarts dockerd or a container. Idempotent.
#   merge-gate   (--apply) prints the sequence and PAUSES while YOU merge the PR; then verifies via gh that it
#                merged and that the prod deploy run for the merge commit finished green (bounded poll), then that
#                satlink reports LogConfig.Type=journald and plimsoll / plimsoll-llm still json-file. The merge
#                deploy itself recreates satlink onto journald.
#   canary       (--apply) BEFORE counts from the journal (CONTAINER_NAME=satlink lines, the CONTAINER_ID of the
#                running container), `make -C <deploy root> force-recreate svc=satlink` (NEVER plain `recreate`:
#                that is `up -d --no-deps`, a no-op on an unchanged spec; it exited 0 and left the old traefik
#                container running), asserts the container id AND StartedAt changed, then AFTER counts: AFTER >=
#                BEFORE, lines for the OLD container id > 0, `docker logs satlink` works, satlink healthy, zero
#                'Suppressed ... docker.service' notices in the window. Counts only.
#   verify       READ-ONLY, always executes. `make journald-check`, disk usage not vacuumed, oldest entry
#                unchanged, driver per service, the Suppressed count against the preflight baseline, and the
#                Dozzle check that only YOU can do (recorded as PAUSE until you confirm; never an auto-PASS).
#   rollback     (--apply, each step confirmed) the documented revert: you merge the revert of the compose
#                logging block; this script waits for it, force-recreates satlink if it is still on journald,
#                asserts json-file and that the journal history is still queryable. Removing the two drop-ins
#                and restarting journald happens ONLY with --remove-dropins.
#   all          preflight, dropin, merge-gate, canary, verify in order, pausing before each
#
#   --print-evidence   print a counts-only markdown block for a Switchyard comment on SATL-25 / SATL-71, built
#                      from what the earlier phases recorded in <state dir>/state.kv. Runs nothing else.
#
# MODE. Dry-run is the default: dropin, merge-gate, canary and rollback only PRINT their plan unless --apply is
# given. preflight and verify only read, so they execute in either mode (verify inside a dry-run `all` only prints).
#
# Flags: --apply            really run the phase (dropin, merge-gate, canary, rollback, all)
#        --yes              do not pause between phases of `all` (forced pauses still happen)
#        --confirm-apply    skip the forced owner pauses (drift, merge). Never skips a rollback step.
#        --confirm-rollback skip the per-step typed confirmation of `rollback` (tests)
#        --confirm-dozzle   record the Dozzle check as owner-confirmed without asking (tests)
#        --remove-dropins   rollback: also remove the host drop-ins and restart journald
#        --pr N             the PR to merge in merge-gate (default 297)
#        --revert-pr N      rollback: the revert PR the owner merges (optional, verified via gh when given)
#        --record F         record file (default ~/.cache/journald-logging-rollout/rollout-<utc>-<phase>.md)
#        --print-evidence   see above
#
# PAUSE needs a terminal. With none, the run records the PAUSE and exits 3 (not a failure: it is waiting for
# you). Under a dry-run a pause is recorded and not waited for.
#
# WHAT THE RECORD HOLDS. Counts, container ids, service names, exit codes, byte sizes, dates. Never a log line:
# every journal read is a pipeline whose only output is a number, and the reader's output is never echoed. No
# `set -x`. Nothing here merges, pushes or commits, and nothing here restarts dockerd or any other container
# than satlink (canary / rollback only).

set -euo pipefail
set +a +x +v
unset BASH_XTRACEFD
PS4='+ '

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GH_REPO="${JOURNALD_ROLLOUT_GH_REPO:-Einlanzerous/construct-server}"
DEPLOY_ROOT="${DEPLOY_ROOT:-/opt/construct-server}"
PR="${JOURNALD_ROLLOUT_PR:-297}"
SRC_DIR="${DROPIN_SRC_DIR:-$REPO/ansible/roles/server/files/journald}"
JD_DIR="${JOURNALD_DEST_DIR:-/etc/systemd/journald.conf.d}"
DK_DIR="${DOCKER_DEST_DIR:-/etc/systemd/system/docker.service.d}"
JD_FILE="50-construct-containers.conf"
DK_FILE="50-log-rate.conf"
RUN_UNITS_DIR="${RUN_UNITS_DIR:-/run/systemd/units}"
BURST_WANT=50000
SVC="satlink"
JSONFILE_SVCS=(plimsoll plimsoll-llm)
DEPLOY_WORKFLOW="deploy.yml"
STATE_DIR="${JOURNALD_ROLLOUT_DIR:-$HOME/.cache/journald-logging-rollout}"
STATE="$STATE_DIR/state.kv"
DEPLOY_POLL_MAX="${JOURNALD_ROLLOUT_DEPLOY_POLL_MAX:-1800}"   # seconds to wait for the deploy run
DEPLOY_POLL_GAP="${JOURNALD_ROLLOUT_DEPLOY_POLL_GAP:-15}"
MERGE_POLL_MAX="${JOURNALD_ROLLOUT_MERGE_POLL_MAX:-300}"
HEALTHY_MAX="${JOURNALD_ROLLOUT_HEALTHY_MAX:-120}"            # seconds for satlink to come back healthy
DISK_SLACK_PCT="${JOURNALD_ROLLOUT_DISK_SLACK_PCT:-1}"        # a restart may archive a file; more than this shrinking is a vacuum

APPLY=0
YES=0
CONFIRM_APPLY=0
CONFIRM_ROLLBACK=0
CONFIRM_DOZZLE=0
REMOVE_DROPINS=0
REVERT_PR=""
EVIDENCE=0
RECORD=""
PHASE=""
OUT=""
RC=0
SCRATCH=""
PF_FAIL=0
WAVEC_FAIL=0
SUDO_OK=0
PENDING=()

usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; }

# ── record + output ──────────────────────────────────────────────────────────────

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
rec() { printf '%s\n' "$*" >>"$RECORD"; }
say() { printf '%s\n' "$*"; rec "$*"; }
die() { say "- $(ts) **FAIL**: $*"; exit 1; }
pass() { say "- $(ts) PASS: $*"; }
note() { say "- $(ts) NOTE: $*"; }
logcmd() { rec "- $(ts) \`$*\`"; printf '+ %s\n' "$*"; }

# run CMD... — logs, runs, captures combined output in OUT and the exit code in RC. Never aborts.
# Output is not recorded. Never use it for a command whose output is log content.
run() {
  logcmd "$@"
  OUT=""; RC=0
  if OUT="$("$@" 2>&1 </dev/null)"; then RC=0; else RC=$?; fi
  rec "  - exit $RC"
}
run_must() { run "$@"; [ "$RC" -eq 0 ] || die "command exited $RC: $1"; }

check() { local name="$1"; shift; if "$@"; then pass "$name"; else die "$name"; fi; }
soft() { local name="$1"; shift; if "$@"; then pass "$name"; else say "- $(ts) **FAIL**: $name"; PF_FAIL=1; fi; }

need() { local t; for t in "$@"; do command -v "$t" >/dev/null 2>&1 || die "required tool not on PATH: $t"; done; }

have_tty() { ( : </dev/tty ) 2>/dev/null; }

# pause MSG [kind]  kind: soft (skipped by --yes) | force (skipped by --confirm-apply) | strict (never)
pause() {
  local kind="${2:-soft}"
  if [ "$APPLY" -eq 0 ]; then say "- $(ts) PAUSE: $1 (dry-run: not waiting)"; return 0; fi
  say "- $(ts) PAUSE: $1"
  [ "$kind" = soft ] && [ "$YES" -eq 1 ] && return 0
  [ "$kind" = force ] && [ "$CONFIRM_APPLY" -eq 1 ] && return 0
  if ! have_tty; then
    say "- $(ts) **PAUSED**: waiting for the owner and there is no terminal; stopping (exit 3)"
    exit 3
  fi
  printf '\n>>> %s\n>>> Press Enter to continue, Ctrl-C to stop. ' "$1" >/dev/tty
  read -r _ </dev/tty
}

confirm_typed() {   # confirm_typed WORD MSG — the owner types WORD
  local ans=""
  have_tty || die "needs a terminal for the typed confirmation: $2"
  printf '\n>>> %s\n>>> Type %s to continue: ' "$2" "$1" >/dev/tty
  read -r ans </dev/tty
  [ "$ans" = "$1" ] || die "confirmation not given; nothing done"
}

cleanup() {
  local rc=$?
  [ -n "$SCRATCH" ] && [ -d "$SCRATCH" ] && rm -rf "$SCRATCH"
  if [ -n "$RECORD" ] && [ -f "$RECORD" ]; then printf '\n_Finished %s, exit %s._\n' "$(ts)" "$rc" >>"$RECORD"; fi
  exit "$rc"
}

ensure_sudo() {   # the owner types the password once; everything privileged below uses sudo
  [ "$SUDO_OK" -eq 1 ] && return 0
  need sudo
  run sudo -v
  [ "$RC" -eq 0 ] || die "sudo not available (run this from your own terminal and type the password)"
  SUDO_OK=1
}

# ── state (counts only) ──────────────────────────────────────────────────────────

st_set() {   # st_set KEY VALUE
  mkdir -p "$STATE_DIR"; touch "$STATE"
  { grep -v "^$1=" "$STATE" 2>/dev/null || true; printf '%s=%s\n' "$1" "$2"; } >"$STATE.tmp" && mv "$STATE.tmp" "$STATE"
}
st_get() { { grep "^$1=" "$STATE" 2>/dev/null || true; } | tail -1 | cut -d= -f2-; }
st_or() { local v; v="$(st_get "$1")"; printf '%s' "${v:-n/a}"; }

now_s() { date +%s.%N; }

# ── reads (numbers only: a log line never leaves these pipelines) ────────────────

jcount() {   # jcount FIELD=VALUE -> number of journal lines
  { journalctl "$1" --no-pager -q -o cat 2>/dev/null || true; } | wc -l | tr -d ' '
}
journal_container_id() {   # the CONTAINER_ID journal field of the newest satlink entry (12 chars), nothing else
  { journalctl "CONTAINER_NAME=$SVC" --no-pager -q -n 1 -o json 2>/dev/null || true; } | jq -r '.CONTAINER_ID // empty' 2>/dev/null | head -1
}
suppressed_since() {   # suppressed_since "<journalctl --since value>" -> count
  { journalctl -u systemd-journald --since "$1" --no-pager -q -o cat 2>/dev/null || true; } | grep -c 'Suppressed .* messages from docker.service' || true
}
disk_bytes() {   # `journalctl --disk-usage` -> bytes ("... take up 2.7G in the file system.")
  journalctl --disk-usage 2>/dev/null | awk '
    { for (i = 1; i <= NF; i++) if ($i == "up") { v = $(i + 1); break } }
    END { if (v == "") exit; n = v + 0; u = v; sub(/^[0-9.]+/, "", u)
      m = (u == "K") ? 1024 : (u == "M") ? 1048576 : (u == "G") ? 1073741824 : (u == "T") ? 1099511627776 : 1
      printf "%.0f\n", n * m }'
}
oldest_epoch() {   # epoch seconds of the oldest journal entry (first field of the first line; the rest is dropped)
  { journalctl --no-pager -q -o short-unix 2>/dev/null || true; } | { head -n 1 || true; } | cut -d' ' -f1 | cut -d. -f1
}
date_of() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$1"; }
driver_of() { docker inspect -f '{{.HostConfig.LogConfig.Type}}' "$1" 2>/dev/null || true; }
ctr_id_started() { docker inspect -f '{{.Id}}|{{.State.StartedAt}}' "$1" 2>/dev/null || true; }   # "fullid|started"
ctr_health() { docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$1" 2>/dev/null || true; }
burst_pid1() { systemctl show docker.service -p LogRateLimitBurst --value 2>/dev/null || true; }
burst_run_file() { cat "$RUN_UNITS_DIR/log-rate-limit-burst:docker.service" 2>/dev/null | tr -d '[:space:]' || true; }
make_deployed() { make -C "$DEPLOY_ROOT" "$@"; }
image_digests() { docker image inspect -f '{{join .RepoDigests " "}}' "$1" 2>/dev/null || true; }

not_vacuumed() {   # not_vacuumed BASE_BYTES BASE_OLDEST — usage not reduced beyond the slack, oldest entry the same
  local now_b now_o
  now_b="$(disk_bytes)"; now_o="$(oldest_epoch)"
  [[ "$now_b" =~ ^[0-9]+$ ]] && [[ "$now_o" =~ ^[0-9]+$ ]] || { rec "  - journal disk usage / oldest entry unreadable now"; return 1; }
  rec "  - disk usage: baseline $1 bytes, now $now_b; oldest entry: baseline $(date_of "$2"), now $(date_of "$now_o")"
  st_set last_disk_bytes "$now_b"; st_set last_oldest_epoch "$now_o"
  [ "$now_o" = "$2" ] || { rec "  - the oldest entry moved: something was vacuumed"; return 1; }
  awk -v a="$1" -v b="$now_b" -v p="$DISK_SLACK_PCT" 'BEGIN{exit (b >= a * (1 - p / 100)) ? 0 : 1}' || { rec "  - usage shrank by more than ${DISK_SLACK_PCT}%: something was vacuumed"; return 1; }
}

dropin_state() {   # dropin_state SRC DEST -> absent | identical | differs
  if [ ! -e "$2" ]; then echo absent; elif cmp -s "$1" "$2"; then echo identical; else echo differs; fi
}

# ── phase: preflight ─────────────────────────────────────────────────────────────

pf_disk() {
  local b o
  b="$(disk_bytes)"; o="$(oldest_epoch)"
  [[ "$b" =~ ^[0-9]+$ ]] || { rec "  - cannot read journalctl --disk-usage"; return 1; }
  [[ "$o" =~ ^[0-9]+$ ]] || { rec "  - cannot read the oldest journal entry"; return 1; }
  rec "  - journal disk usage $b bytes ($(journalctl --disk-usage 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="up"){print $(i+1); exit}}')); oldest entry $(date_of "$o")"
  st_set pf_disk_bytes "$b"; st_set pf_oldest_epoch "$o"
}

pf_dropins() {
  local a b
  a="$(dropin_state "$SRC_DIR/$JD_FILE" "$JD_DIR/$JD_FILE")"; b="$(dropin_state "$SRC_DIR/$DK_FILE" "$DK_DIR/$DK_FILE")"
  [ -f "$SRC_DIR/$JD_FILE" ] && [ -f "$SRC_DIR/$DK_FILE" ] || { rec "  - repo drop-ins missing under $SRC_DIR"; return 1; }
  rec "  - $JD_DIR/$JD_FILE: $a; $DK_DIR/$DK_FILE: $b"
  st_set pf_dropin_journald "$a"; st_set pf_dropin_docker "$b"
  [ "$a" != differs ] && [ "$b" != differs ]
}

pf_burst() {
  local v; v="$(burst_pid1)"
  rec "  - LogRateLimitBurst as PID 1 sees it for docker.service: ${v:-unreadable} (the host default is 10000 until the drop-in is loaded)"
  [[ "$v" =~ ^[0-9]+$ ]] || return 1
  st_set pf_burst "$v"
}

pf_drivers() {
  local id d total=0 j=0 f=0 o=0
  for id in $(docker ps -aq 2>/dev/null); do
    d="$(driver_of "$id")"; total=$((total + 1))
    case "$d" in journald) j=$((j + 1)) ;; json-file) f=$((f + 1)) ;; *) o=$((o + 1)) ;; esac
  done
  rec "  - containers by log driver: journald $j, json-file $f, other $o (of $total)"
  st_set pf_ctr_total "$total"; st_set pf_ctr_journald "$j"; st_set pf_ctr_jsonfile "$f"; st_set pf_ctr_other "$o"
  [ "$total" -gt 0 ]
}

pf_satlink() {
  local d s id started
  s="$(ctr_id_started "$SVC")"
  [ -n "$s" ] || { rec "  - container $SVC not found"; return 1; }
  d="$(driver_of "$SVC")"; id="${s%%|*}"; started="${s#*|}"
  rec "  - $SVC driver $d, container ${id:0:12}, StartedAt $started"
  st_set pf_satlink_driver "$d"; st_set pf_satlink_id "${id:0:12}"; st_set pf_satlink_started "$started"
}

pf_check() {
  local s
  run make -C "$REPO" journald-check
  s="$(sed -n 's/^Suppressed notices for docker.service: \([0-9][0-9]*\).*/\1/p' <<<"$OUT" | head -1)"
  rec "  - make journald-check exit $RC (make reports the check's exit 1 as 2; a non-zero exit is expected before the merge: $SVC is still json-file); Suppressed notices (24h): ${s:-n/a}"
  st_set pf_check_rc "$RC"; st_set pf_suppressed "${s:-0}"
  # it must have RUN (its last section printed), whatever it concluded about the drivers
  [ "$RC" -eq 0 ] || grep -q '^== rate-limit drops' <<<"$OUT"
}

pf_pr_state() {
  run gh pr view "$PR" --repo "$GH_REPO" --json state -q .state
  rec "  - #$PR state: ${OUT:-n/a}"
  st_set pf_pr_state "${OUT:-n/a}"
  [ "$RC" -eq 0 ]
}

# Expected first-party refs: the compose file with origin/main's versions.env layered over the deployed .env
# (what the next deploy renders). Running: the compose project's containers.
pf_digest_drift() {
  local main_env="$SCRATCH/main-versions.env" exp="$SCRATCH/expected" runn="$SCRATCH/running" id line svc ref img rd reg d
  if ! gh api "repos/$GH_REPO/contents/versions.env?ref=main" -H 'Accept: application/vnd.github.raw' >"$main_env" 2>/dev/null; then
    rec "  - could not read origin/main versions.env"; return 1
  fi
  docker compose -f "$DEPLOY_ROOT/docker-compose.yml" --env-file "$DEPLOY_ROOT/.env" --env-file "$main_env" config --format json 2>/dev/null \
    | jq -r '.services | to_entries[] | select((.value.image // "") | startswith("ghcr.io/einlanzerous/")) | "\(.key) \(.value.image)"' >"$exp" || true
  [ -s "$exp" ] || { rec "  - no first-party refs resolved from compose"; return 1; }
  : >"$runn"
  for id in $(docker compose -f "$DEPLOY_ROOT/docker-compose.yml" ps -aq 2>/dev/null); do
    line="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.service"}}|{{.Config.Image}}|{{.Image}}' "$id" 2>/dev/null)" || continue
    printf '%s\n' "$line" >>"$runn"
  done
  PENDING=()
  while read -r svc ref; do
    line="$(grep "^$svc|" "$runn" | head -1 || true)"
    [ -n "$line" ] || continue                     # not running: nothing to recreate
    IFS='|' read -r _ img rd <<<"$line"
    if [ "$img" != "$ref" ]; then PENDING+=("$svc(tag)"); continue; fi
    reg="$(docker buildx imagetools inspect "$ref" --format '{{.Manifest.Digest}}' 2>/dev/null || true)"
    [ -n "$reg" ] || { PENDING+=("$svc(registry-unreadable)"); continue; }
    d="$(image_digests "$rd")"
    case " $d " in *"@$reg "*) ;; *) PENDING+=("$svc(digest)") ;; esac
  done <"$exp"
  rec "  - first-party services compared: $(wc -l <"$exp" | tr -d ' '); pending: ${#PENDING[@]}${PENDING[*]:+ (${PENDING[*]})}"
  st_set pf_drift_n "${#PENDING[@]}"
  return 0
}

pf_versions_deployed() {
  local main_env="$SCRATCH/main-versions.env" keys
  [ -s "$main_env" ] || { rec "  - origin/main versions.env not fetched"; return 1; }
  [ -f "$DEPLOY_ROOT/versions.env" ] || { rec "  - no $DEPLOY_ROOT/versions.env"; return 1; }
  keys="$(diff <(grep -E '^[A-Z0-9_]+_TAG=' "$main_env" | sort) <(grep -E '^[A-Z0-9_]+_TAG=' "$DEPLOY_ROOT/versions.env" | sort) \
    | grep -E '^[<>]' | cut -c3- | cut -d= -f1 | sort -u | paste -sd' ' - || true)"
  rec "  - deployed versions.env differs from origin/main in $(wc -w <<<"$keys" | tr -d ' ') key(s)${keys:+: $keys}"
  st_set pf_versions_n "$(wc -w <<<"$keys" | tr -d ' ')"
  [ -z "$keys" ] || PENDING+=("versions.env:${keys// /,}")
  return 0
}

phase_preflight() {
  say "## preflight (read-only, no sudo)"
  need gh docker jq make git awk journalctl systemctl
  SCRATCH="$(mktemp -d)"
  PF_FAIL=0; PENDING=()
  soft "journal disk usage and the oldest entry recorded (the not-vacuumed baseline)" pf_disk
  soft "the two drop-ins are absent, or present and byte-identical to the repo copies" pf_dropins
  soft "LogRateLimitBurst for docker.service as PID 1 sees it recorded" pf_burst
  soft "containers counted per log driver" pf_drivers
  soft "$SVC driver, container id and StartedAt recorded" pf_satlink
  soft "make journald-check baseline ran (a red result is expected before the merge)" pf_check
  soft "#$PR state read (merged or not; recorded)" pf_pr_state
  soft "first-party image digests resolved against the registry for origin/main's pins" pf_digest_drift
  soft "deployed copy $DEPLOY_ROOT compared with origin/main versions.env" pf_versions_deployed
  if [ "${#PENDING[@]}" -gt 0 ]; then
    say "- $(ts) PENDING: the whole-stack deploy that merging a docker-compose.yml change triggers would recreate/pull: ${PENDING[*]}"
    note "a digest mismatch can be a benign rebuild of the same commit (SERV-88); read \`make versions\` revision before deciding"
    pause "${#PENDING[@]} pending item(s) above would move on the merge deploy. Accept them, or promote/hold first." force
  fi
  [ "$PF_FAIL" -eq 0 ] || die "preflight: one or more checks failed (see above)"
  st_set preflight_ok 1
}

# ── phase: dropin ────────────────────────────────────────────────────────────────

dropins_identical() {
  cmp -s "$SRC_DIR/$JD_FILE" "$JD_DIR/$JD_FILE" && cmp -s "$SRC_DIR/$DK_FILE" "$DK_DIR/$DK_FILE"
}

phase_dropin() {
  say "## dropin"
  if [ "$APPLY" -eq 0 ]; then
    say "- $(ts) DRY-RUN: would, in order (sudo -v first; you type the password):"
    say "  1. record the journal disk usage and the oldest entry date"
    say "  2. \`sudo install -d $JD_DIR $DK_DIR\`"
    say "  3. \`sudo install -m 0644 $SRC_DIR/$JD_FILE $JD_DIR/\` and \`... $SRC_DIR/$DK_FILE $DK_DIR/\` (skipped when already identical)"
    say "  4. \`sudo systemctl daemon-reload\` (re-reads units; does NOT restart dockerd) and \`sudo systemctl restart systemd-journald\`"
    say "  5. assert both installed files equal the repo copies byte for byte"
    say "  6. assert nothing was vacuumed: disk usage not reduced, oldest entry date unchanged"
    say "  7. \`systemctl show docker.service -p LogRateLimitBurst\` and $RUN_UNITS_DIR/log-rate-limit-burst:docker.service both $BURST_WANT"
    say "     (a missing/wrong /run file is a WAVE-C blocker, not a canary blocker: decide the global RateLimitBurst fallback before wave C)"
    say "  dockerd and every container are left running: nothing here restarts them."
    return 0
  fi
  need sudo install cmp systemctl journalctl
  [ -f "$SRC_DIR/$JD_FILE" ] && [ -f "$SRC_DIR/$DK_FILE" ] || die "no drop-ins under $SRC_DIR (run this from a checkout that has them)"
  ensure_sudo
  local b0 o0
  b0="$(disk_bytes)"; o0="$(oldest_epoch)"
  [[ "$b0" =~ ^[0-9]+$ ]] && [[ "$o0" =~ ^[0-9]+$ ]] || die "cannot read the journal disk usage / oldest entry before installing"
  rec "- before: journal $b0 bytes, oldest entry $(date_of "$o0")"
  st_set dropin_disk_before "$b0"; st_set dropin_oldest_before "$o0"
  run_must sudo install -d "$JD_DIR" "$DK_DIR"
  if dropins_identical 2>/dev/null; then
    note "both drop-ins already identical to the repo copies: install skipped"
  else
    run_must sudo install -m 0644 "$SRC_DIR/$JD_FILE" "$JD_DIR/$JD_FILE"
    run_must sudo install -m 0644 "$SRC_DIR/$DK_FILE" "$DK_DIR/$DK_FILE"
  fi
  run_must sudo systemctl daemon-reload
  run_must sudo systemctl restart systemd-journald
  note "dockerd and the containers were NOT restarted"
  check "installed $JD_FILE equals the repo copy byte for byte" cmp -s "$SRC_DIR/$JD_FILE" "$JD_DIR/$JD_FILE"
  check "installed $DK_FILE equals the repo copy byte for byte" cmp -s "$SRC_DIR/$DK_FILE" "$DK_DIR/$DK_FILE"
  check "nothing vacuumed: journal usage not reduced and the oldest entry unchanged" not_vacuumed "$b0" "$o0"
  st_set dropin_ok 1
  local v1 v2
  v1="$(burst_pid1)"; v2="$(burst_run_file)"
  rec "  - LogRateLimitBurst: PID 1 ${v1:-unreadable}; $RUN_UNITS_DIR/log-rate-limit-burst:docker.service ${v2:-missing}"
  st_set dropin_burst_pid1 "${v1:-unreadable}"; st_set dropin_burst_run "${v2:-missing}"
  if [ "$v1" = "$BURST_WANT" ] && [ "$v2" = "$BURST_WANT" ]; then
    pass "LogRateLimitBurst $BURST_WANT in PID 1 and in the /run file journald reads"
    st_set wavec_blocker 0
  else
    WAVEC_FAIL=1; st_set wavec_blocker 1
    say "- $(ts) **FAIL** (WAVE-C BLOCKER, NOT a canary blocker): LogRateLimitBurst is not $BURST_WANT where journald reads it (PID 1: ${v1:-unreadable}; /run file: ${v2:-missing}). Decide the global RateLimitBurst fallback (the journald drop-in) BEFORE wave C (switchyard). Satlink alone will not approach 10000 lines per 30 s, so the canary may proceed."
    note "the /run file is written when PID 1 starts docker.service; this phase deliberately does not restart dockerd, so it can stay missing until the next docker restart"
  fi
}

# ── phase: merge-gate ────────────────────────────────────────────────────────────

print_merge_sequence() {
  say "The sequence (you do the merge; this script never merges):"
  say "  1. merge #$PR yourself (squash, as the repo does), AFTER the dropin phase passed. The docker-compose.yml change runs the"
  say "     whole-stack prod deploy, which recreates satlink onto journald (and any drifted first-party service, see preflight)."
  say "  2. this script then checks: #$PR merged into main, the $DEPLOY_WORKFLOW run for the merge commit finished green,"
  say "     $SVC reports LogConfig.Type=journald, and ${JSONFILE_SVCS[*]} still report json-file."
}

mg_merged() {
  local i=0 j
  while :; do
    run gh pr view "$PR" --repo "$GH_REPO" --json state,baseRefName,mergeCommit
    if [ "$RC" -eq 0 ] && [ "$(jq -r .state <<<"$OUT")" = MERGED ]; then break; fi
    i=$((i + DEPLOY_POLL_GAP)); [ "$i" -le "$MERGE_POLL_MAX" ] || { rec "  - #$PR not merged within ${MERGE_POLL_MAX}s"; return 1; }
    sleep "$DEPLOY_POLL_GAP"
  done
  j="$OUT"
  [ "$(jq -r .baseRefName <<<"$j")" = main ] || { rec "  - #$PR merged into $(jq -r .baseRefName <<<"$j"), not main"; return 1; }
  MERGE_SHA="$(jq -r '.mergeCommit.oid // empty' <<<"$j")"
  [ -n "$MERGE_SHA" ] || return 1
  rec "  - merge commit ${MERGE_SHA:0:9}"
  st_set merge_sha "$MERGE_SHA"
}

mg_deploy_green() {
  local waited=0 concl="" stat="" row
  while :; do
    run gh run list --repo "$GH_REPO" --workflow "$DEPLOY_WORKFLOW" --commit "$MERGE_SHA" --json status,conclusion,databaseId --limit 1
    row="$(jq -c '.[0] // empty' <<<"$OUT" 2>/dev/null || true)"
    if [ -n "$row" ]; then
      stat="$(jq -r .status <<<"$row")"; concl="$(jq -r .conclusion <<<"$row")"
      rec "  - deploy run $(jq -r .databaseId <<<"$row"): status $stat, conclusion $concl"
      [ "$stat" = completed ] && break
    else
      rec "  - no $DEPLOY_WORKFLOW run for ${MERGE_SHA:0:9} yet"
    fi
    waited=$((waited + DEPLOY_POLL_GAP))
    [ "$waited" -le "$DEPLOY_POLL_MAX" ] || { rec "  - deploy did not finish within ${DEPLOY_POLL_MAX}s"; return 1; }
    sleep "$DEPLOY_POLL_GAP"
  done
  st_set deploy_conclusion "$concl"
  [ "$concl" = success ]
}

mg_drivers() {
  local d s ok=0
  d="$(driver_of "$SVC")"; rec "  - $SVC driver: ${d:-unreadable}"
  st_set mg_satlink_driver "${d:-unreadable}"
  [ "$d" = journald ] || ok=1
  for s in "${JSONFILE_SVCS[@]}"; do
    d="$(driver_of "$s")"; rec "  - $s driver: ${d:-unreadable}"
    st_set "mg_${s//-/_}_driver" "${d:-unreadable}"
    [ "$d" = json-file ] || ok=1
  done
  return "$ok"
}

phase_merge_gate() {
  say "## merge-gate"
  print_merge_sequence
  if [ "$APPLY" -eq 0 ]; then say "- $(ts) DRY-RUN: would pause for the merge, then poll gh and assert the checks above"; return 0; fi
  need gh jq docker
  pause "merge #$PR now (the host drop-ins must already be installed). Press Enter once it is merged; the deploy then runs." force
  check "#$PR merged into main" mg_merged
  check "prod deploy run for ${MERGE_SHA:0:9} finished green" mg_deploy_green
  check "$SVC is on journald; ${JSONFILE_SVCS[*]} are still json-file" mg_drivers
  st_set merge_gate_ok 1
}

# ── phase: canary ────────────────────────────────────────────────────────────────

wait_healthy() {   # wait_healthy NAME — healthy, or running when the image has no healthcheck
  local t0 h; t0="$(now_s)"
  while :; do
    h="$(ctr_health "$1")"
    case "$h" in healthy|running) rec "  - $1 state: $h"; return 0 ;; esac
    [ "$(awk -v a="$t0" -v b="$(now_s)" -v m="$HEALTHY_MAX" 'BEGIN{print (b-a>m)?1:0}')" = 0 ] || { rec "  - $1 not healthy within ${HEALTHY_MAX}s (last: ${h:-none})"; return 1; }
    sleep 1
  done
}

phase_canary() {
  say "## canary"
  if [ "$APPLY" -eq 0 ]; then
    say "- $(ts) DRY-RUN: would, in order:"
    say "  1. assert $SVC is on journald; BEFORE = lines of \`journalctl CONTAINER_NAME=$SVC\`; OLD_ID = the CONTAINER_ID journal field; record container id and StartedAt"
    say "  2. \`make -C $DEPLOY_ROOT force-recreate svc=$SVC\` (NOT plain \`recreate\`: that is up -d --no-deps, a no-op on an unchanged spec)"
    say "  3. assert the container id AND StartedAt changed (a no-op make would leave both), $SVC healthy"
    say "  4. AFTER = lines of CONTAINER_NAME=$SVC (>= BEFORE); OLDN = lines of CONTAINER_ID=OLD_ID (> 0); \`docker logs $SVC\` works;"
    say "     zero 'Suppressed ... messages from docker.service' notices since the start. Counts only; no line is printed."
    say "  $SVC is down for a few seconds (its Docker-state exporter may read unavailable for up to 90 s)."
    return 0
  fi
  need docker make jq journalctl
  local d s0 id0 started0 jid before since after oldn s1 id1 started1 dl sup
  d="$(driver_of "$SVC")"
  check "$SVC is on the journald driver before the canary (got ${d:-none})" test "$d" = journald
  s0="$(ctr_id_started "$SVC")"; [ -n "$s0" ] || die "$SVC is not running; refusing"
  id0="${s0%%|*}"; started0="${s0#*|}"
  jid="$(journal_container_id)"
  before="$(jcount "CONTAINER_NAME=$SVC")"
  rec "  - BEFORE: $before journal lines for CONTAINER_NAME=$SVC; journal CONTAINER_ID ${jid:-none}; running container ${id0:0:12}, StartedAt $started0"
  [[ "$before" =~ ^[0-9]+$ ]] && [ "$before" -gt 0 ] || die "no journal lines for CONTAINER_NAME=$SVC before the recreate: nothing to prove survives (is the deploy done and $SVC logging?)"
  [ -n "$jid" ] || die "the journal carries no CONTAINER_ID field for $SVC"
  check "the journal's newest CONTAINER_ID is the running container (${jid})" test "$jid" = "${id0:0:12}"
  st_set canary_before "$before"; st_set canary_old_id "$jid"; st_set canary_started_before "$started0"
  since="$(date '+%Y-%m-%d %H:%M:%S')"
  st_set canary_since "$since"
  # force-recreate, not recreate: `recreate` is `up -d --no-deps`, which does nothing when the compose spec is
  # unchanged. It exited 0 and left the old container running in the traefik window (SERV-164).
  run make_deployed force-recreate "svc=$SVC"
  [ "$RC" -eq 0 ] || die "make force-recreate svc=$SVC exited $RC"
  s1="$(ctr_id_started "$SVC")"; id1="${s1%%|*}"; started1="${s1#*|}"
  rec "  - after: container ${id1:0:12}, StartedAt $started1"
  check "$SVC really restarted (container id changed; a no-op make leaves it)" test -n "$id1" -a "$id0" != "$id1"
  check "$SVC StartedAt changed" test -n "$started1" -a "$started0" != "$started1"
  check "$SVC healthy again" wait_healthy "$SVC"
  st_set canary_new_id "${id1:0:12}"
  after="$(jcount "CONTAINER_NAME=$SVC")"; oldn="$(jcount "CONTAINER_ID=$jid")"
  rec "  - AFTER: $after lines (BEFORE $before); lines for the old container $jid: $oldn"
  st_set canary_after "$after"; st_set canary_old_lines "$oldn"
  check "pre-recreate lines survived (AFTER $after >= BEFORE $before)" test "$after" -ge "$before"
  check "the old container id still yields journal lines ($oldn > 0)" test "$oldn" -gt 0
  if docker logs --tail 5 "$SVC" >/dev/null 2>&1; then pass "docker logs $SVC works"; st_set canary_docker_logs ok; else st_set canary_docker_logs fail; die "docker logs $SVC failed"; fi
  dl="$({ docker logs "$SVC" 2>&1 || true; } | wc -l | tr -d ' ')"
  rec "  - docker logs $SVC lines (new container only): $dl"; st_set canary_docker_lines "$dl"
  sup="$(suppressed_since "$since")"
  rec "  - 'Suppressed ... docker.service' notices since $since: $sup"
  st_set canary_suppressed "$sup"
  check "zero Suppressed notices from docker.service in the window" test "${sup:-1}" = 0
  st_set canary_ok 1
}

# ── phase: verify ────────────────────────────────────────────────────────────────

vf_check() {
  local s
  run make -C "$REPO" journald-check
  s="$(sed -n 's/^Suppressed notices for docker.service: \([0-9][0-9]*\).*/\1/p' <<<"$OUT" | head -1)"
  rec "  - make journald-check exit $RC; Suppressed notices (24h): ${s:-n/a} (preflight baseline $(st_or pf_suppressed))"
  st_set v_check_rc "$RC"; st_set v_suppressed "${s:-n/a}"
  [ "$RC" -eq 0 ] || return 1
  local base; base="$(st_get pf_suppressed)"; [[ "$base" =~ ^[0-9]+$ ]] || base=0
  [[ "$s" =~ ^[0-9]+$ ]] && [ "$s" -le "$base" ]
}

vf_drivers() {
  local d s ok=0
  d="$(driver_of "$SVC")"; rec "  - $SVC: ${d:-unreadable}"; st_set v_satlink_driver "${d:-unreadable}"; [ "$d" = journald ] || ok=1
  for s in "${JSONFILE_SVCS[@]}"; do
    d="$(driver_of "$s")"; rec "  - $s: ${d:-unreadable}"; st_set "v_${s//-/_}_driver" "${d:-unreadable}"; [ "$d" = json-file ] || ok=1
  done
  return "$ok"
}

vf_dozzle() {
  say "- $(ts) MANUAL CHECK (only you can do this): open Dozzle, select the $SVC container."
  say "    a) the LIVE TAIL streams new lines;  b) scroll-back / history renders older lines and timestamps."
  say "    Then run \`journalctl CONTAINER_NAME=$SVC --since -1h | wc -l\` yourself if you want a count. Do not paste lines anywhere."
  if [ "$CONFIRM_DOZZLE" -eq 1 ]; then
    say "- $(ts) PASS (owner-confirmed via --confirm-dozzle): Dozzle live tail and history for $SVC"; st_set dozzle confirmed; return 0
  fi
  if [ "$APPLY" -eq 1 ] && have_tty; then
    local ans=""
    printf '\n>>> Did Dozzle show BOTH the live tail and the history for %s? Type yes to record it, anything else to leave it pending: ' "$SVC" >/dev/tty
    read -r ans </dev/tty
    if [ "$ans" = yes ]; then say "- $(ts) PASS (owner-confirmed, typed yes): Dozzle live tail and history for $SVC"; st_set dozzle confirmed; return 0; fi
  fi
  say "- $(ts) PAUSE: Dozzle live tail and history for $SVC are NOT yet confirmed by the owner (not an automatic pass). Re-run verify with a terminal and --apply, or record it by hand."
  st_set dozzle pending
}

phase_verify() {
  say "## verify (read-only, counts only)"
  if [ "$APPLY" -eq 0 ] && [ "$PHASE" = all ]; then
    say "- $(ts) DRY-RUN: verify would run make journald-check, the not-vacuumed check, driver per service and the Dozzle manual check (read-only; skipped inside a dry-run \`all\` because nothing was applied)"
    return 0
  fi
  need docker make journalctl jq
  local b o
  b="$(st_get pf_disk_bytes)"; o="$(st_get pf_oldest_epoch)"
  [[ "$b" =~ ^[0-9]+$ ]] && [[ "$o" =~ ^[0-9]+$ ]] || die "no recorded preflight baseline (disk usage / oldest entry): run the preflight phase first"
  check "make journald-check passes and Suppressed is not above the baseline" vf_check
  check "nothing vacuumed since the preflight baseline (usage not reduced, oldest entry unchanged)" not_vacuumed "$b" "$o"
  check "driver per service: $SVC journald, ${JSONFILE_SVCS[*]} json-file" vf_drivers
  vf_dozzle
  st_set verify_ok 1
}

# ── phase: rollback ──────────────────────────────────────────────────────────────

rb_step() {   # rb_step MSG — each step is confirmed
  [ "$CONFIRM_ROLLBACK" -eq 1 ] && { say "- $(ts) CONFIRMED (--confirm-rollback): $1"; return 0; }
  confirm_typed yes "$1"
}

rb_compose_driver() {   # the logging driver the DEPLOYED compose file gives satlink
  docker compose -f "$DEPLOY_ROOT/docker-compose.yml" --env-file "$DEPLOY_ROOT/.env" config --format json 2>/dev/null \
    | jq -r --arg s "$SVC" '.services[$s].logging.driver // "json-file"' 2>/dev/null || true
}

phase_rollback() {
  say "## rollback"
  say "Documented rollback (docs/journald-logging.md): per service, no data cost."
  say "  1. (yours) revert the PR that put \`logging: *journald-logging\` on $SVC (or put its json-file 10m x 3 block back) and merge it;"
  say "     this script waits for it${REVERT_PR:+ (#$REVERT_PR)} and checks the deployed compose file gives $SVC json-file"
  say "  2. \`make -C $DEPLOY_ROOT force-recreate svc=$SVC\` if it is still on journald (the revert deploy normally recreates it already);"
  say "     assert json-file and that the journal lines are STILL queryable (\`journalctl CONTAINER_NAME=$SVC\`)"
  say "  3. only with --remove-dropins: \`sudo rm -f\` the two drop-ins, daemon-reload, restart systemd-journald (touches no container)"
  if [ "$APPLY" -eq 0 ]; then say "- $(ts) DRY-RUN: nothing done"; return 0; fi
  need docker make jq journalctl
  [ "$REMOVE_DROPINS" -eq 0 ] || ensure_sudo
  rb_step "Step 1: have you merged the revert of the compose logging block, and has its deploy finished?"
  if [ -n "$REVERT_PR" ]; then
    run gh pr view "$REVERT_PR" --repo "$GH_REPO" --json state -q .state
    [ "$RC" -eq 0 ] && [ "$OUT" = MERGED ] || die "revert PR #$REVERT_PR is not merged"
    pass "revert PR #$REVERT_PR is merged"
  fi
  local cd; cd="$(rb_compose_driver)"
  rec "  - deployed compose gives $SVC logging driver: ${cd:-unreadable}"
  check "the deployed compose file no longer puts $SVC on journald (got ${cd:-unreadable})" test "$cd" = json-file
  local d s0 s1
  d="$(driver_of "$SVC")"
  if [ "$d" = journald ]; then
    rb_step "Step 2: force-recreate $SVC (a few seconds of dashboard downtime)?"
    s0="$(ctr_id_started "$SVC")"
    run make_deployed force-recreate "svc=$SVC"; [ "$RC" -eq 0 ] || die "make force-recreate svc=$SVC exited $RC"
    s1="$(ctr_id_started "$SVC")"
    check "$SVC really restarted (container id changed)" test -n "${s1%%|*}" -a "${s0%%|*}" != "${s1%%|*}"
  else
    note "$SVC is already on ${d:-?} (the revert deploy recreated it): no recreate needed"
  fi
  check "$SVC healthy" wait_healthy "$SVC"
  check "$SVC is back on json-file" test "$(driver_of "$SVC")" = json-file
  local n; n="$(jcount "CONTAINER_NAME=$SVC")"
  rec "  - journal lines for CONTAINER_NAME=$SVC after the rollback: $n (canary AFTER was $(st_or canary_after))"
  st_set rb_journal_lines "$n"
  check "journal history stays queryable after the rollback ($n lines)" test "$n" -gt 0
  if [ "$REMOVE_DROPINS" -eq 1 ]; then
    rb_step "Step 3: remove the two host drop-ins and restart systemd-journald (no container is touched)?"
    run sudo rm -f "$JD_DIR/$JD_FILE" "$DK_DIR/$DK_FILE"; [ "$RC" -eq 0 ] || die "could not remove the drop-ins"
    run_must sudo systemctl daemon-reload
    run_must sudo systemctl restart systemd-journald
    pass "drop-ins removed, journald restarted (journal files left in place)"
    st_set rb_dropins_removed 1
  else
    note "host drop-ins left in place (pass --remove-dropins to remove them)"
  fi
  st_set rollback_done 1
}

# ── evidence ─────────────────────────────────────────────────────────────────────

print_evidence() {
  [ -f "$STATE" ] || { echo "no recorded state at $STATE: nothing to summarise" >&2; return 1; }
  cat <<EOF
**SATL-25 / SATL-71 journald canary evidence** (counts only; no log line, no log value)

- preflight: #$PR state $(st_or pf_pr_state); journal $(st_or pf_disk_bytes) bytes, oldest entry $(date_of "$(st_or pf_oldest_epoch)"); drop-ins before: $(st_or pf_dropin_journald) / $(st_or pf_dropin_docker); LogRateLimitBurst (PID 1) $(st_or pf_burst); containers by driver: journald $(st_or pf_ctr_journald), json-file $(st_or pf_ctr_jsonfile), other $(st_or pf_ctr_other) of $(st_or pf_ctr_total); $SVC driver $(st_or pf_satlink_driver), container $(st_or pf_satlink_id); journald-check exit $(st_or pf_check_rc); Suppressed (24h) $(st_or pf_suppressed); pending whole-stack drift items $(st_or pf_drift_n), versions.env keys differing $(st_or pf_versions_n)
- dropin: $([ "$(st_get dropin_ok)" = 1 ] && echo "installed, byte-identical, nothing vacuumed (journal $(st_or dropin_disk_before) bytes before)" || echo "not recorded"); LogRateLimitBurst PID 1 $(st_or dropin_burst_pid1), /run file $(st_or dropin_burst_run); wave-C blocker: $([ "$(st_get wavec_blocker)" = 1 ] && echo "YES (decide the global RateLimitBurst fallback before wave C)" || echo no)
- merge-gate: merge commit $(st_or merge_sha | cut -c1-9); deploy run conclusion $(st_or deploy_conclusion); drivers: $SVC $(st_or mg_satlink_driver), plimsoll $(st_or mg_plimsoll_driver), plimsoll-llm $(st_or mg_plimsoll_llm_driver)
- canary: BEFORE $(st_or canary_before) lines, AFTER $(st_or canary_after) lines, old container $(st_or canary_old_id) lines $(st_or canary_old_lines), new container $(st_or canary_new_id); docker logs $(st_or canary_docker_logs) ($(st_or canary_docker_lines) lines, new container only); Suppressed in the window $(st_or canary_suppressed); canary passed: $([ "$(st_get canary_ok)" = 1 ] && echo yes || echo no)
- verify: journald-check exit $(st_or v_check_rc), Suppressed (24h) $(st_or v_suppressed); journal now $(st_or last_disk_bytes) bytes, oldest entry $(date_of "$(st_or last_oldest_epoch)"); drivers: $SVC $(st_or v_satlink_driver), plimsoll $(st_or v_plimsoll_driver), plimsoll-llm $(st_or v_plimsoll_llm_driver); Dozzle (live tail + history): $(st_or dozzle); verify passed: $([ "$(st_get verify_ok)" = 1 ] && echo yes || echo no)
- rollback: $([ "$(st_get rollback_done)" = 1 ] && echo "done; journal lines still queryable $(st_or rb_journal_lines); drop-ins removed: $(st_or rb_dropins_removed)" || echo "not run")
EOF
}

# ── driver ───────────────────────────────────────────────────────────────────────

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --dry-run) APPLY=0 ;;
    --yes) YES=1 ;;
    --confirm-apply) CONFIRM_APPLY=1 ;;
    --confirm-rollback) CONFIRM_ROLLBACK=1 ;;
    --confirm-dozzle) CONFIRM_DOZZLE=1 ;;
    --remove-dropins) REMOVE_DROPINS=1 ;;
    --print-evidence) EVIDENCE=1 ;;
    --pr) PR="${2:?--pr needs a number}"; shift ;;
    --revert-pr) REVERT_PR="${2:?--revert-pr needs a number}"; shift ;;
    --record) RECORD="${2:?--record needs a file}"; shift ;;
    -h|--help) usage; exit 0 ;;
    preflight|dropin|merge-gate|canary|verify|rollback|all)
      [ -z "$PHASE" ] || { echo "ERROR: one phase at a time: '$PHASE' and '$1'" >&2; exit 2; }
      PHASE="$1" ;;
    *) echo "ERROR: unknown argument '$1' (try --help)" >&2; exit 2 ;;
  esac
  shift
done
if [ "$EVIDENCE" -eq 1 ]; then print_evidence; exit $?; fi
[ -n "$PHASE" ] || { usage >&2; exit 2; }
[[ "$PR" =~ ^[0-9]+$ ]] || { echo "ERROR: --pr must be a number" >&2; exit 2; }
[[ -z "$REVERT_PR" || "$REVERT_PR" =~ ^[0-9]+$ ]] || { echo "ERROR: --revert-pr must be a number" >&2; exit 2; }

umask 077
if [ -z "$RECORD" ]; then
  RECORD="$STATE_DIR/rollout-$(date -u +%Y%m%dT%H%M%SZ)-$PHASE.md"
fi
mkdir -p "$(dirname "$RECORD")" "$STATE_DIR"
[ ! -e "$RECORD" ] || [ ! -s "$RECORD" ] || RECORD="$RECORD.$(date -u +%H%M%S)"
: >"$RECORD"
trap cleanup EXIT
printf 'Record: %s\n' "$RECORD"
rec "# SATL-25 journald canary rollout: $PHASE"
rec ""
rec "- started $(ts) as $(id -un) on $(hostname), repo $REPO, branch $(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?'), deploy root $DEPLOY_ROOT"
rec "- mode: $([ "$APPLY" -eq 1 ] && echo '--apply (live)' || echo 'DRY-RUN (read-only phases still execute)')"
rec ""

# sudo is asked for once, up front, whenever a phase that needs it will really run
if [ "$APPLY" -eq 1 ] && { [ "$PHASE" = dropin ] || [ "$PHASE" = all ] || { [ "$PHASE" = rollback ] && [ "$REMOVE_DROPINS" -eq 1 ]; }; }; then
  ensure_sudo
fi

case "$PHASE" in
  preflight) phase_preflight ;;
  dropin) phase_dropin ;;
  merge-gate) phase_merge_gate ;;
  canary) phase_canary ;;
  verify) phase_verify ;;
  rollback) phase_rollback ;;
  all)
    for p in preflight dropin merge-gate canary verify; do
      pause "about to run phase: $p"
      "phase_${p//-/_}"
    done ;;
esac
rec ""
if [ "$WAVEC_FAIL" -eq 1 ]; then
  say "- $(ts) **FAIL**: $PHASE finished, but the WAVE-C-blocker check above failed (the canary itself is not blocked): decide the global RateLimitBurst fallback before wave C"
  exit 1
fi
if [ "$APPLY" -eq 0 ]; then say "- $(ts) **DRY-RUN complete**: preflight/verify read for real; every other phase only printed its plan"
else say "- $(ts) **DONE**: $PHASE, every automated step passed"; fi
printf 'Record: %s\n' "$RECORD"
