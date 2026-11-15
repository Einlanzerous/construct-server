#!/usr/bin/env bash
# traefik-access-log-rollout.sh — run, and RECORD, the owner steps of SATL-24 (Traefik access-log
# rotation plus the User-Agent / Upgrade / X-Access-Subject fields). The steps are the owner list in
# docs/zerogravity-edge.md ("Access log: fields and rotation"); this is that list as subcommands, in the
# shape of scripts/satlink-edge-rollout.sh: phases that each run alone, a markdown record per run,
# PASS / FAIL / PAUSE lines, counts-only evidence, no secrets.
#
#   traefik-access-log-rollout.sh [flags] <phase>
#
#   preflight    READ-ONLY, always executes. #296 merged? running first-party image digests vs the
#                registry tags for the pins on origin/main versions.env (a config/** merge runs the
#                whole-stack deploy, which recreates whatever drifted: pending ones are listed and the
#                run PAUSES), the deployed copy vs origin/main versions.env, `make assert-env-keys
#                vault=1` from a scratch checkout of main, access.log size and no rotated sibling,
#                traefik uptime + image, crowdsec lines-read baseline, satlink collector baseline,
#                `make edge-auth-check` baseline. Every check runs; the run fails if any failed.
#   dropin       validate ansible/roles/server/templates/traefik-access.j2 with `sudo logrotate -d`, `sudo install` it to
#                /etc/logrotate.d/traefik-access, `logrotate -d` the installed file, assert it equals the
#                repo copy byte for byte. Idempotent.
#   merge-gate   prints the exact sequence and PAUSES while YOU merge #299 (retarget to main first);
#                then verifies via gh that it merged, that the prod deploy run for the merge commit
#                finished green (bounded poll), and that the live traefik still runs the OLD config
#                (SERV-164: the deploy goes green, the edge keeps the old traefik.yml).
#   recreate     `make force-recreate svc=traefik` from the deployed copy; time to the first healthy edge
#                response (the check-edge-auth.sh probe: spoofed Host to the internal entrypoint -> 403);
#                same image; `make edge-auth-check`. Records the log offset that `verify` counts from.
#   verify       READ-ONLY, always executes. Counts over the lines written since `recreate`: User-Agent
#                and X-Access-Subject keys present/absent, subject on 2xx internal lines, none on 403s,
#                ZERO Cf-Access-Jwt-Assertion / Cf-Access-Authenticated-User-Email keys, crowdsec
#                lines-read advanced, satlink collector running, `make edge-auth-check`.
#   rotate       the real rotation of the live (~770 MB) log: `sudo logrotate -f`, then access.log.1 plain,
#                traefik writing to the new access.log (and NOT to .1: missed-reopen detection),
#                crowdsec still advancing, satlink collector followed. Extra confirmation required.
#   rollback     the documented rollback: restore the previous traefik.yml from git, recreate traefik,
#                remove the drop-in. Each step confirmed.
#   all          preflight, dropin, merge-gate, recreate, verify, rotate in order, pausing before each
#
#   --print-evidence   print a counts-only markdown block for a Switchyard comment on SATL-24, built
#                      from what the earlier phases recorded in <state dir>/state.kv. Runs nothing else.
#
# MODE. Dry-run is the default: dropin, merge-gate, recreate, rotate and rollback only PRINT their plan
# unless --apply is given. preflight and verify only read, so they execute in either mode.
#
# Flags: --apply            really run the phase (dropin, merge-gate, recreate, rotate, rollback, all)
#        --yes              do not pause between phases of `all` (forced pauses still happen)
#        --confirm-apply    skip the forced owner pauses (drift, merge). Never skips rotate or rollback.
#        --confirm-rotate   skip the typed confirmation of `rotate` (tests; --apply still required)
#        --confirm-rollback skip the per-step confirmation of `rollback` (tests)
#        --pr N             the PR to merge in merge-gate (default 299)
#        --record F         record file (default ~/.cache/traefik-access-log-rollout/rollout-<utc>-<phase>.md)
#        --print-evidence   see above
#
# PAUSE needs a terminal. With none, the run records the PAUSE and exits 3 (not a failure: it is waiting
# for you). Under a dry-run a pause is recorded and not waited for.
#
# WHAT THE RECORD HOLDS. Counts, key names, service names, exit codes, digests. Never a log line, an
# email, an IP, a user agent or a subject value: the log is read inside a pipeline whose only output is
# numbers (jq), and the log reader's output is never echoed. The root-only volume is read with `sudo`
# when sudo works without a prompt; otherwise through `docker exec crowdsec`, which mounts the same
# volume read-only (the record says which). No `set -x`. Nothing here merges, pushes or commits.

set -euo pipefail
set +a +x +v
unset BASH_XTRACEFD
PS4='+ '

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GH_REPO="${TRAEFIK_ROLLOUT_GH_REPO:-Einlanzerous/construct-server}"
DEPLOY_ROOT="${DEPLOY_ROOT:-/opt/construct-server}"
GUARD_PR=296
PR="${TRAEFIK_ROLLOUT_PR:-299}"
DROPIN_SRC="${DROPIN_SRC:-$REPO/ansible/roles/server/templates/traefik-access.j2}"
DROPIN_DEST="${DROPIN_DEST:-/etc/logrotate.d/traefik-access}"
LOG_DIR="${TRAEFIK_LOG_DIR:-/var/lib/docker/volumes/construct-server_traefik_access_logs/_data}"
CTR_LOG_DIR="/var/log/traefik"           # the same volume inside crowdsec / traefik
LOG_NAME="access.log"
PROBE_HOST="${TRAEFIK_PROBE_HOST:-switchyard.zerogravity.industries}"
DEPLOY_WORKFLOW="deploy.yml"
STATE_DIR="${TRAEFIK_ROLLOUT_DIR:-$HOME/.cache/traefik-access-log-rollout}"
STATE="$STATE_DIR/state.kv"
DEPLOY_POLL_MAX="${TRAEFIK_ROLLOUT_DEPLOY_POLL_MAX:-1800}"   # seconds to wait for the deploy run
DEPLOY_POLL_GAP="${TRAEFIK_ROLLOUT_DEPLOY_POLL_GAP:-15}"
MERGE_POLL_MAX="${TRAEFIK_ROLLOUT_MERGE_POLL_MAX:-300}"
HEALTHY_MAX="${TRAEFIK_ROLLOUT_HEALTHY_MAX:-90}"             # seconds for the first healthy response
POLL_GAP="${TRAEFIK_ROLLOUT_POLL_GAP:-5}"                      # seconds between crowdsec / collector polls
SAMPLE_GAP="${TRAEFIK_ROLLOUT_SAMPLE_GAP:-10}"               # seconds between rotate samples
ROTATE_WAIT="${TRAEFIK_ROLLOUT_ROTATE_WAIT:-90}"             # seconds for new-log growth / crowdsec
COLLECTOR_WAIT="${TRAEFIK_ROLLOUT_COLLECTOR_WAIT:-180}"      # seconds for the collector's rotated-file read
ROTATE_MAX_FRESH="${TRAEFIK_ROLLOUT_FRESH_MAX:-52428800}"    # "near zero": the new log is under 50 MiB

DRY=1
APPLY=0
YES=0
CONFIRM_APPLY=0
CONFIRM_ROTATE=0
CONFIRM_ROLLBACK=0
EVIDENCE=0
RECORD=""
PHASE=""
READER=""
OUT=""
RC=0
SCRATCH=""
PF_FAIL=0
LRTMP=""

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
# Output is not recorded.
run() {
  logcmd "$@"
  OUT=""; RC=0
  if OUT="$("$@" 2>&1 </dev/null)"; then RC=0; else RC=$?; fi
  rec "  - exit $RC"
}
run_must() { run "$@"; [ "$RC" -eq 0 ] || die "command exited $RC: $1"; }

# check NAME FUNC [ARGS] — FUNC returns 0 for pass; the first failure stops the run.
check() { local name="$1"; shift; if "$@"; then pass "$name"; else die "$name"; fi; }
# soft NAME FUNC [ARGS] — as check, but only marks the phase failed (preflight reports everything).
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
  [ -n "$LRTMP" ] && [ -d "$LRTMP" ] && rm -rf "$LRTMP"
  if [ -n "$RECORD" ] && [ -f "$RECORD" ]; then printf '\n_Finished %s, exit %s._\n' "$(ts)" "$rc" >>"$RECORD"; fi
  exit "$rc"
}

# ── state (counts only) ──────────────────────────────────────────────────────────

st_set() {   # st_set KEY VALUE
  mkdir -p "$STATE_DIR"; touch "$STATE"
  { grep -v "^$1=" "$STATE" 2>/dev/null || true; printf '%s=%s\n' "$1" "$2"; } >"$STATE.tmp" && mv "$STATE.tmp" "$STATE"
}
st_get() { { grep "^$1=" "$STATE" 2>/dev/null || true; } | tail -1 | cut -d= -f2-; }
st_or() { local v; v="$(st_get "$1")"; printf '%s' "${v:-n/a}"; }

now_s() { date +%s.%N; }
elapsed() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.1f", b-a}'; }

# ── the root-only log volume ─────────────────────────────────────────────────────
# Reader: sudo on the host path when it works without a prompt, else `docker exec crowdsec` on the
# read-only mount. Output of the reader is only ever reduced to a number inside the pipeline.

pick_reader() {
  [ -n "$READER" ] && return 0
  if sudo -n true 2>/dev/null; then READER=sudo; else READER=docker; fi
  rec "- log reader: $READER"
}
log_size() {   # log_size FILE -> bytes, or empty when absent
  pick_reader
  if [ "$READER" = sudo ]; then sudo stat -c %s "$LOG_DIR/$1" 2>/dev/null || true
  else docker exec crowdsec stat -c %s "$CTR_LOG_DIR/$1" 2>/dev/null || true; fi
}
log_names() {   # names in the volume directory (file names are not sensitive)
  pick_reader
  if [ "$READER" = sudo ]; then sudo ls -1 "$LOG_DIR" 2>/dev/null || true
  else docker exec crowdsec ls -1 "$CTR_LOG_DIR" 2>/dev/null || true; fi
}
log_tail() {   # log_tail OFFSET — bytes from OFFSET (0-based) of access.log; feed only into a counter
  pick_reader
  if [ "$READER" = sudo ]; then sudo tail -c "+$(($1 + 1))" "$LOG_DIR/$LOG_NAME"
  else docker exec crowdsec tail -c "+$(($1 + 1))" "$CTR_LOG_DIR/$LOG_NAME"; fi
}
have_sibling() {   # have_sibling NAME
  log_names | grep -qx -- "$1"
}

# Counts over a stream of JSON access-log lines: ONLY numbers come out. Key names are matched
# case-insensitively (Traefik writes request_<canonical-header-name>).
JQ_COUNTS='
def ks: keys | map(ascii_downcase);
def hs($k): ks | index($k) != null;
def subj: to_entries | any(.[]; (.key | ascii_downcase) == "request_x-access-subject" and ((.value | tostring) | IN("", "-") | not));
def st: (.DownstreamStatus // 0);
def internal: ((.entryPointName // "") == "internal");
[inputs | fromjson? | select(type == "object")] as $l
| "total=\($l | length)",
  "ua_with=\($l | map(select(hs("request_user-agent"))) | length)",
  "ua_without=\($l | map(select(hs("request_user-agent") | not)) | length)",
  "subj_with=\($l | map(select(subj)) | length)",
  "subj_without=\($l | map(select(subj | not)) | length)",
  "ok_internal=\($l | map(select(internal and st >= 200 and st < 300)) | length)",
  "ok_internal_subj=\($l | map(select(internal and st >= 200 and st < 300 and subj)) | length)",
  "s403=\($l | map(select(st == 403)) | length)",
  "s403_subj=\($l | map(select(st == 403 and subj)) | length)",
  "leak_jwt=\($l | map(select(hs("request_cf-access-jwt-assertion"))) | length)",
  "leak_email=\($l | map(select(hs("request_cf-access-authenticated-user-email"))) | length)"'

count_log_from() {   # count_log_from OFFSET -> key=value lines, numbers only
  log_tail "$1" 2>/dev/null | jq -Rrn "$JQ_COUNTS" 2>/dev/null
}
kv() { grep "^$2=" <<<"$1" | head -1 | cut -d= -f2; }   # kv "$counts" key

# ── crowdsec / satlink / traefik / edge reads (counts only) ──────────────────────

crowdsec_reads() {   # lines read from the traefik acquisition source, or empty
  docker exec crowdsec cscli metrics show acquisition -o json 2>/dev/null \
    | jq -r '[.acquisition | to_entries[] | select(.key | contains("traefik")) | .value.reads] | if length == 0 then empty else add end' 2>/dev/null || true
}
collector_rollups() {   # collector_rollups SINCE — traefik-rollup run lines since SINCE (counts)
  docker logs --since "$1" satlink 2>&1 | grep -c '\[traefik-rollup\] read' || true
}
collector_errors() {
  docker logs --since "$1" satlink 2>&1 | grep '\[traefik-rollup\]' | grep -ciE 'error|fail|panic' || true
}
collector_rotated_reads() {
  docker logs --since "$1" satlink 2>&1 | grep -c 'rotated file read' || true
}
traefik_state() { docker inspect -f '{{.State.StartedAt}}|{{.Image}}' traefik 2>/dev/null; }   # "started|imageid"
image_digests() { docker image inspect -f '{{join .RepoDigests " "}}' "$1" 2>/dev/null || true; }

edge_addr() {
  awk '/^  internal:/{f=1} f && /address:/{gsub(/[" ]/,"",$2); print $2; exit}' "$DEPLOY_ROOT/config/traefik/traefik.yml" 2>/dev/null
}
edge_probe_code() {   # the check-edge-auth.sh probe: spoofed Host to the internal entrypoint
  curl -s -o /dev/null -w '%{http_code}' --max-time 3 -H "Host: $PROBE_HOST" "http://$1/" 2>/dev/null || true
}
make_deployed() { make -C "$DEPLOY_ROOT" "$@"; }

# ── phase: preflight ─────────────────────────────────────────────────────────────

PENDING=()

pf_guard_merged() {
  run gh pr view "$GUARD_PR" --repo "$GH_REPO" --json state -q .state
  rec "  - #$GUARD_PR state: ${OUT:-n/a}"
  st_set pf_guard_state "${OUT:-n/a}"
  [ "$RC" -eq 0 ] && [ "$OUT" = "MERGED" ]
}

# Expected first-party refs: the compose file with origin/main's versions.env layered over the
# deployed .env (what the next deploy renders). Running: the compose project's containers.
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

pf_env_keys() {
  local url
  url="$(git -C "$REPO" remote get-url origin 2>/dev/null)" || return 1
  run git clone --quiet --depth 1 --branch main "$url" "$SCRATCH/main"
  [ "$RC" -eq 0 ] || return 1
  run make -C "$SCRATCH/main" assert-env-keys vault=1
  [ "$RC" -eq 0 ]
}

pf_log_state() {
  local size n_sib
  size="$(log_size "$LOG_NAME")"
  [ -n "$size" ] || { rec "  - cannot read $LOG_NAME (reader: $READER)"; return 1; }
  n_sib="$(log_names | grep -cE "^${LOG_NAME//./\\.}\\.[0-9]+(\\.gz)?$" || true)"
  rec "  - $LOG_NAME: $size bytes; rotated siblings: $n_sib; reader: $READER"
  st_set pf_log_bytes "$size"; st_set pf_siblings "$n_sib"
  [ "$n_sib" -eq 0 ]
}

pf_traefik() {
  local s started img up d
  s="$(traefik_state)" || return 1
  started="${s%%|*}"; img="${s#*|}"
  up=$(( $(date +%s) - $(date -d "$started" +%s) ))
  d="$(image_digests "$img" | tr ' ' '\n' | head -1 | sed 's/.*@//')"
  rec "  - traefik up ${up}s; image id ${img#sha256:}; repo digest ${d:-none}"
  st_set pf_traefik_uptime_s "$up"; st_set pf_traefik_digest "${d:-${img#sha256:}}"; st_set traefik_image_id "$img"
  [ "$up" -ge 0 ]
}

pf_crowdsec() {
  local r; r="$(crowdsec_reads)"
  rec "  - crowdsec acquisition lines read (traefik source): ${r:-unreadable}"
  [[ "$r" =~ ^[0-9]+$ ]] || return 1
  st_set crowdsec_baseline "$r"
}

pf_collector() {
  local n e
  docker inspect -f '{{.State.Running}}' satlink >/dev/null 2>&1 || { rec "  - satlink container not found: collector baseline unreadable"; return 1; }
  n="$(collector_rollups 10m)"; e="$(collector_errors 10m)"
  rec "  - satlink traefik-rollup runs in the last 10m: $n; error-looking lines: $e"
  st_set pf_collector_runs_10m "$n"
  [ "$n" -ge 1 ] && [ "$e" -eq 0 ]
}

pf_edge_auth() {
  run make_deployed edge-auth-check
  rec "  - make edge-auth-check exit $RC"
  [ "$RC" -eq 0 ]
}

phase_preflight() {
  say "## preflight (read-only)"
  pick_reader
  need gh docker jq make curl git awk
  SCRATCH="$(mktemp -d)"
  PF_FAIL=0; PENDING=()
  soft "#$GUARD_PR (guard emits X-Access-Subject) is merged to main" pf_guard_merged
  soft "first-party image digests resolved against the registry for origin/main's pins" pf_digest_drift
  soft "deployed copy $DEPLOY_ROOT compared with origin/main versions.env" pf_versions_deployed
  soft "make assert-env-keys vault=1 passes from a scratch checkout of main" pf_env_keys
  soft "$LOG_NAME readable and no rotated sibling exists" pf_log_state
  soft "traefik container uptime and image recorded" pf_traefik
  soft "crowdsec acquisition lines-read baseline recorded" pf_crowdsec
  soft "satlink collector baseline recorded and no error lines" pf_collector
  soft "make edge-auth-check baseline passes" pf_edge_auth
  if [ "${#PENDING[@]}" -gt 0 ]; then
    say "- $(ts) PENDING: the whole-stack deploy that a config/** merge triggers would recreate/pull: ${PENDING[*]}"
    note "a digest mismatch can be a benign rebuild of the same commit (SERV-88); read \`make versions\` revision before deciding"
    pause "${#PENDING[@]} pending item(s) above would move on the next deploy. Accept them, or promote/hold first." force
  fi
  [ "$PF_FAIL" -eq 0 ] || die "preflight: one or more checks failed (see above)"
  st_set preflight_ok 1
}

# ── phase: dropin ────────────────────────────────────────────────────────────────

lr_debug() {   # lr_debug FILE — logrotate -d must exit 0 with no `error:` line
  local errs
  run sudo logrotate -d -s "$LRTMP/state" "$1"
  errs="$(grep -c '^error:' <<<"$OUT" || true)"
  rec "  - logrotate -d exit $RC; error lines: $errs"
  [ "$RC" -eq 0 ] && [ "$errs" -eq 0 ]
}

dropin_equal() { sudo cmp -s "$DROPIN_SRC" "$DROPIN_DEST"; }

phase_dropin() {
  say "## dropin"
  if [ "$APPLY" -eq 0 ]; then
    say "- $(ts) DRY-RUN: would, in order:"
    say "  1. copy $DROPIN_SRC to a root-owned temp file and \`sudo logrotate -d\` it (logrotate ignores non-root-owned configs)"
    say "  2. \`sudo install -m 0644 -o root -g root $DROPIN_SRC $DROPIN_DEST\` (skipped when already identical)"
    say "  3. \`sudo logrotate -d $DROPIN_DEST\`"
    say "  4. assert $DROPIN_DEST equals the repo copy byte for byte"
    say "  NOTE: the ansible server role also manages this file (template, tag logrotate) and keeps it in step afterwards;"
    say "  run it with \`--tags logrotate\` only, never the full site.yml. The install here must stay byte-identical to what the role renders."
    return 0
  fi
  need sudo logrotate cmp install
  [ -f "$DROPIN_SRC" ] || die "no drop-in at $DROPIN_SRC (run this from a checkout that has the template; it has no variables, so the role renders the same bytes)"
  run sudo -v; [ "$RC" -eq 0 ] || die "sudo not available"
  LRTMP="$(mktemp -d)"
  run_must sudo install -m 0644 -o root -g root "$DROPIN_SRC" "$LRTMP/traefik-access"
  check "repo copy validates (logrotate -d, root-owned temp copy)" lr_debug "$LRTMP/traefik-access"
  if dropin_equal 2>/dev/null; then
    note "$DROPIN_DEST already identical to the repo copy: install skipped"
  else
    run_must sudo install -m 0644 -o root -g root "$DROPIN_SRC" "$DROPIN_DEST"
  fi
  check "installed drop-in validates (logrotate -d)" lr_debug "$DROPIN_DEST"
  check "installed drop-in equals the repo copy byte for byte" dropin_equal
  st_set dropin_ok 1
  note "the ansible server role keeps this file in step afterwards (--tags logrotate, never the full site.yml); this install is byte-identical to the repo copy it renders from"
}

# ── phase: merge-gate ────────────────────────────────────────────────────────────

print_merge_sequence() {
  say "The sequence (you do the merge; this script never merges):"
  say "  1. retarget #$PR to main:  gh api -X PATCH repos/$GH_REPO/pulls/$PR -F base=main   (gh pr edit fails here)"
  say "  2. merge #$PR yourself (squash, as the repo does). The config/** change runs the whole-stack prod deploy."
  say "  3. this script then checks: #$PR merged, the $DEPLOY_WORKFLOW run for the merge commit finished green,"
  say "     and the live traefik STILL runs the old traefik.yml (SERV-164: a green deploy does not apply it)."
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

mg_old_config_live() {
  local deployed live
  deployed="$(grep -c 'X-Access-Subject' "$DEPLOY_ROOT/config/traefik/traefik.yml" 2>/dev/null || true)"
  live="$(docker exec traefik grep -c 'X-Access-Subject' /etc/traefik/traefik.yml 2>/dev/null || true)"
  rec "  - X-Access-Subject lines: deployed copy ${deployed:-0}, inside the running traefik ${live:-0}"
  st_set old_config_live "$([ "${live:-0}" = 0 ] && echo yes || echo no)"
  if [ "${deployed:-0}" -lt 1 ]; then rec "  - the deployed copy does not carry the new traefik.yml: the deploy has not landed it"; return 1; fi
  [ "${live:-0}" = 0 ]
}

phase_merge_gate() {
  say "## merge-gate"
  print_merge_sequence
  if [ "$APPLY" -eq 0 ]; then say "- $(ts) DRY-RUN: would pause for the merge, then poll gh and assert the three things above"; return 0; fi
  need gh jq docker
  pause "merge #$PR now (retargeted to main). Press Enter once it is merged; the deploy then runs." force
  check "#$PR merged into main" mg_merged
  check "prod deploy run for ${MERGE_SHA:0:9} finished green" mg_deploy_green
  check "live traefik still runs the OLD config (SERV-164: deploy green, edge unchanged)" mg_old_config_live
  st_set merge_gate_ok 1
}

# ── phase: recreate ──────────────────────────────────────────────────────────────

phase_recreate() {
  say "## recreate"
  if [ "$APPLY" -eq 0 ]; then
    say "- $(ts) DRY-RUN: would, in order: record the time and image; \`make -C $DEPLOY_ROOT force-recreate svc=traefik\`;"
    say "  poll the check-edge-auth probe (spoofed Host -> 403 on the internal entrypoint) and record seconds to the"
    say "  first healthy response; assert the container really restarted (its StartedAt changed) on the same image id; record the log offset; \`make edge-auth-check\`."
    say "  The public Argosy path and every tunneled host are down while the container starts."
    return 0
  fi
  need docker make curl jq
  local addr before after t0 t1 t2 code size
  addr="$(edge_addr)"; [ -n "$addr" ] || die "cannot read the internal entrypoint address from $DEPLOY_ROOT/config/traefik/traefik.yml"
  check "the deployed traefik.yml carries the new fields (the deploy landed)" grep -q 'X-Access-Subject' "$DEPLOY_ROOT/config/traefik/traefik.yml"
  before="$(traefik_state)"; started_before="${before%%|*}"; before="${before#*|}"
  [ -n "$before" ] || die "traefik is not running; refusing"
  st_set recreate_ts "$(ts)"
  logcmd "recreate started at $(st_get recreate_ts), edge probe http://$addr/ (Host: $PROBE_HOST)"
  t0="$(now_s)"
  # force-recreate, not recreate: `recreate` is `up -d --no-deps`, which does nothing when the compose spec is
  # unchanged, and a changed single-file bind (traefik.yml) is not spec drift (SERV-164). It exited 0 and left the
  # old container running on the first live run.
  run make_deployed force-recreate svc=traefik
  t1="$(now_s)"
  [ "$RC" -eq 0 ] || die "make force-recreate svc=traefik exited $RC"
  code=""
  while :; do
    code="$(edge_probe_code "$addr")"
    [ "$code" = 403 ] && break
    t2="$(now_s)"
    [ "$(awk -v a="$t0" -v b="$t2" -v m="$HEALTHY_MAX" 'BEGIN{print (b-a>m)?1:0}')" = 0 ] || die "no healthy edge response within ${HEALTHY_MAX}s (last code ${code:-none})"
    sleep 0.25
  done
  t2="$(now_s)"
  size="$(log_size "$LOG_NAME")"; [[ "$size" =~ ^[0-9]+$ ]] || die "cannot read the log size after the recreate"
  st_set recreate_offset "$size"
  st_set recreate_make_s "$(elapsed "$t0" "$t1")"
  st_set recreate_healthy_s "$(elapsed "$t0" "$t2")"
  pass "first healthy edge response $(elapsed "$t0" "$t2")s after the recreate began (make returned at $(elapsed "$t0" "$t1")s)"
  after="$(traefik_state)"; started_after="${after%%|*}"; after="${after#*|}"
  check "traefik really restarted (StartedAt changed; a no-op make would leave it unchanged)" test -n "$started_after" -a "$started_before" != "$started_after"
  st_set recreate_digest_same "$([ "$before" = "$after" ] && echo yes || echo no)"
  check "traefik is on the same image id as before" test "$before" = "$after"
  run make_deployed edge-auth-check
  rec "  - make edge-auth-check exit $RC"
  [ "$RC" -eq 0 ] || die "make edge-auth-check failed after the recreate"
  pass "make edge-auth-check"
  st_set recreate_ok 1
}

# ── phase: verify ────────────────────────────────────────────────────────────────

phase_verify() {
  say "## verify (read-only, counts only)"
  pick_reader
  need docker jq make
  local off since c base now i
  off="$(st_get recreate_offset)"; since="$(st_get recreate_ts)"
  [[ "$off" =~ ^[0-9]+$ ]] && [ -n "$since" ] || die "no recorded recreate offset/timestamp: run the recreate phase first"
  c="$(count_log_from "$off")" || true
  [ -n "$c" ] || die "could not count the log (reader: $READER)"
  local k
  for k in total ua_with ua_without subj_with subj_without ok_internal ok_internal_subj s403 s403_subj leak_jwt leak_email; do
    st_set "v_$k" "$(kv "$c" "$k")"
  done
  rec "- counts since offset $off (recreate at $since): $(tr '\n' ' ' <<<"$c")"
  [ "$(kv "$c" total)" -gt 0 ] || die "no log lines since the recreate"
  check "request_User-Agent present on new lines ($(kv "$c" ua_with) with, $(kv "$c" ua_without) without)" test "$(kv "$c" ua_with)" -gt 0
  check "request_X-Access-Subject present on 2xx internal-entrypoint lines ($(kv "$c" ok_internal_subj) of $(kv "$c" ok_internal); lines without it are exempt or public routers)" \
    test "$(kv "$c" ok_internal_subj)" -gt 0
  check "403 lines exist to judge ($(kv "$c" s403))" test "$(kv "$c" s403)" -gt 0
  check "no 403 line carries a subject ($(kv "$c" s403_subj) of $(kv "$c" s403))" test "$(kv "$c" s403_subj)" -eq 0
  check "ZERO Cf-Access-Jwt-Assertion keys ($(kv "$c" leak_jwt))" test "$(kv "$c" leak_jwt)" -eq 0
  check "ZERO Cf-Access-Authenticated-User-Email keys ($(kv "$c" leak_email))" test "$(kv "$c" leak_email)" -eq 0

  base="$(st_get crowdsec_baseline)"
  [[ "$base" =~ ^[0-9]+$ ]] || die "no crowdsec baseline recorded: run preflight first"
  now=""; i=0
  while :; do
    now="$(crowdsec_reads)"
    [[ "$now" =~ ^[0-9]+$ ]] && [ "$now" -gt "$base" ] && break
    i=$((i + POLL_GAP)); [ "$i" -le "${TRAEFIK_ROLLOUT_CROWDSEC_WAIT:-30}" ] || break
    sleep "$POLL_GAP"
  done
  st_set crowdsec_after_verify "${now:-n/a}"
  check "crowdsec lines-read advanced (baseline $base, now ${now:-unreadable})" test "${now:-0}" -gt "$base"

  local n e
  n="$(collector_rollups "$since")"; e="$(collector_errors "$since")"
  st_set v_collector_runs "$n"; st_set v_collector_errors "$e"
  check "satlink collector ran since the recreate ($n runs) with no error lines ($e)" test "$n" -ge 1 -a "$e" -eq 0
  run make_deployed edge-auth-check
  rec "  - make edge-auth-check exit $RC"
  [ "$RC" -eq 0 ] || die "make edge-auth-check failed"
  pass "make edge-auth-check"
  st_set verify_ok 1
}

# ── phase: rotate ────────────────────────────────────────────────────────────────

rot_plain_one() { have_sibling "$LOG_NAME.1" && ! have_sibling "$LOG_NAME.1.gz"; }
rot_one_stable() { [ "$(log_size "$LOG_NAME.1")" = "$1" ]; }

phase_rotate() {
  say "## rotate (the real log)"
  if [ "$APPLY" -eq 0 ]; then
    say "- $(ts) DRY-RUN: would require a typed confirmation, then \`sudo logrotate -f $DROPIN_DEST\` and assert:"
    say "  access.log.1 appeared plain; traefik writes the NEW access.log (small, growing) and .1 does not grow"
    say "  (a growing .1 = missed reopen); crowdsec lines-read still advancing; the satlink collector logged a rotated-file read."
    return 0
  fi
  need sudo docker jq
  [ "$(st_get verify_ok)" = 1 ] || die "verify has not passed (state): rotate is the last step; run verify first"
  [ "$(st_get dropin_ok)" = 1 ] || die "the drop-in phase has not passed (state)"
  run sudo -v; [ "$RC" -eq 0 ] || die "sudo not available"
  READER=sudo
  local size0 cs0 since now
  size0="$(log_size "$LOG_NAME")"; [[ "$size0" =~ ^[0-9]+$ ]] || die "cannot read $LOG_NAME"
  ! have_sibling "$LOG_NAME.1" || die "$LOG_NAME.1 already exists: not rotating over it"
  cs0="$(crowdsec_reads)"; [[ "$cs0" =~ ^[0-9]+$ ]] || die "crowdsec lines-read unreadable"
  st_set rotate_size_before "$size0"
  if [ "$CONFIRM_ROTATE" -eq 0 ]; then
    confirm_typed rotate "This rotates the REAL access log ($size0 bytes) with sudo logrotate -f. Traefik is signalled by logrotate's postrotate (USR1)."
  fi
  since="$(ts)"
  run sudo logrotate -f "$DROPIN_DEST"
  [ "$RC" -eq 0 ] || die "logrotate -f exited $RC"
  check "$LOG_NAME.1 appeared and is plain (not .gz: delaycompress)" rot_plain_one
  local one0 one1 new0 new1 w=0 grew=0
  one0="$(log_size "$LOG_NAME.1")"
  new0="$(log_size "$LOG_NAME")"
  [[ "$new0" =~ ^[0-9]+$ ]] || die "no new $LOG_NAME after the rotation"
  rec "  - after rotation: .1 $one0 bytes; new log $new0 bytes (was $size0)"
  check "the new $LOG_NAME starts near zero ($new0 bytes, limit $ROTATE_MAX_FRESH)" test "$new0" -lt "$ROTATE_MAX_FRESH"
  while :; do
    sleep "$SAMPLE_GAP"; w=$((w + SAMPLE_GAP))
    new1="$(log_size "$LOG_NAME")"; one1="$(log_size "$LOG_NAME.1")"
    [ "${one1:-0}" = "${one0:-0}" ] || break
    [ "${new1:-0}" -gt "$new0" ] && { grew=1; break; }
    [ "$w" -lt "$ROTATE_WAIT" ] || break
  done
  st_set rotate_new_bytes "${new1:-n/a}"; st_set rotate_one_bytes "${one1:-n/a}"
  rec "  - samples: .1 $one0 -> $one1 bytes; new log $new0 -> $new1 bytes after ${w}s"
  check "access.log.1 is not growing ($one0 -> $one1): traefik reopened" test "${one1:-x}" = "${one0:-y}"
  check "traefik writes to the new $LOG_NAME ($new0 -> $new1 bytes)" test "$grew" -eq 1
  local i=0 cs1=""
  while :; do
    cs1="$(crowdsec_reads)"; [[ "$cs1" =~ ^[0-9]+$ ]] && [ "$cs1" -gt "$cs0" ] && break
    i=$((i + POLL_GAP)); [ "$i" -le "$ROTATE_WAIT" ] || break; sleep "$POLL_GAP"
  done
  st_set rotate_crowdsec "$cs0 -> ${cs1:-n/a}"
  check "crowdsec lines-read still advancing after the rotation ($cs0 -> ${cs1:-unreadable})" test "${cs1:-0}" -gt "$cs0"
  i=0; now=0
  while :; do
    now="$(collector_rotated_reads "$since")"; [ "${now:-0}" -ge 1 ] && break
    i=$((i + POLL_GAP)); [ "$i" -le "$COLLECTOR_WAIT" ] || break; sleep "$POLL_GAP"
  done
  st_set rotate_collector_rotated_reads "${now:-0}"
  check "satlink collector logged a rotated-file read ($now)" test "${now:-0}" -ge 1
  check "access.log.1 is still not growing after the collector read it" rot_one_stable "$one1"
  st_set rotate_ok 1
}

# ── phase: rollback ──────────────────────────────────────────────────────────────

rb_step() {   # rb_step MSG — each step is confirmed
  [ "$CONFIRM_ROLLBACK" -eq 1 ] && { say "- $(ts) CONFIRMED (--confirm-rollback): $1"; return 0; }
  confirm_typed yes "$1"
}

phase_rollback() {
  say "## rollback"
  local ref="${ROLLBACK_REF:-$(st_get merge_sha)^}" tgt="$DEPLOY_ROOT/config/traefik/traefik.yml"
  say "Documented rollback (docs/zerogravity-edge.md): delete the drop-in (rotated files stay and are harmless);"
  say "revert traefik.yml and \`make force-recreate svc=traefik\` (the fields are additive, leaving them is harmless);"
  say "revert routers.yml (hot reload) then the guard. This script does steps 1-3 below; 4 is yours."
  say "  1. restore the previous traefik.yml (git: ${ref}:config/traefik/traefik.yml) onto $tgt"
  say "  2. make -C $DEPLOY_ROOT force-recreate svc=traefik, then the healthy probe and make edge-auth-check"
  say "  3. sudo rm -f $DROPIN_DEST   (the ansible server role reinstalls it on the next --tags logrotate run: revert its task too)"
  say "  4. (yours) git revert the traefik.yml change on main so the next deploy does not re-copy it, then routers.yml, then the guard"
  if [ "$APPLY" -eq 0 ]; then say "- $(ts) DRY-RUN: nothing done"; return 0; fi
  need git docker make curl
  [ "$ref" != "^" ] || die "no merge commit recorded and no ROLLBACK_REF: set ROLLBACK_REF=<commit holding the previous traefik.yml>"
  git -C "$REPO" cat-file -e "$ref:config/traefik/traefik.yml" 2>/dev/null || die "cannot read config/traefik/traefik.yml at $ref in $REPO (git fetch first)"
  rb_step "Step 1: overwrite $tgt with traefik.yml from $ref?"
  git -C "$REPO" show "$ref:config/traefik/traefik.yml" >"$tgt.rollback" || die "git show failed"
  if grep -q 'X-Access-Subject' "$tgt.rollback"; then rm -f "$tgt.rollback"; die "the restored file still carries the new fields: wrong ref"; fi
  mv "$tgt.rollback" "$tgt"
  pass "previous traefik.yml restored on the deployed copy"
  rb_step "Step 2: recreate traefik (edge down for a few seconds)?"
  local addr code t0; addr="$(edge_addr)"; t0="$(now_s)"
  run make_deployed force-recreate svc=traefik; [ "$RC" -eq 0 ] || die "force-recreate exited $RC"
  while :; do
    code="$(edge_probe_code "$addr")"; [ "$code" = 403 ] && break
    [ "$(awk -v a="$t0" -v b="$(now_s)" -v m="$HEALTHY_MAX" 'BEGIN{print (b-a>m)?1:0}')" = 0 ] || die "no healthy edge response after the rollback recreate"
    sleep 0.25
  done
  pass "edge answers again after the rollback recreate"
  run make_deployed edge-auth-check; [ "$RC" -eq 0 ] || die "make edge-auth-check failed after rollback"
  pass "make edge-auth-check"
  rb_step "Step 3: remove $DROPIN_DEST?"
  run sudo rm -f "$DROPIN_DEST"; [ "$RC" -eq 0 ] || die "could not remove the drop-in"
  pass "drop-in removed (rotated files left in place)"
  st_set rollback_done 1
}

# ── evidence ─────────────────────────────────────────────────────────────────────

print_evidence() {
  [ -f "$STATE" ] || { echo "no recorded state at $STATE: nothing to summarise" >&2; return 1; }
  cat <<EOF
**SATL-24 rollout evidence** (counts only; no log lines, addresses, agents, emails or subjects)

- preflight: #296 state $(st_or pf_guard_state); pending whole-stack drift items $(st_or pf_drift_n), versions.env keys differing $(st_or pf_versions_n); access.log $(st_or pf_log_bytes) bytes, rotated siblings $(st_or pf_siblings); traefik up $(st_or pf_traefik_uptime_s)s on image $(st_or pf_traefik_digest); crowdsec lines-read baseline $(st_or crowdsec_baseline); satlink collector runs (10m) $(st_or pf_collector_runs_10m)
- dropin: $([ "$(st_get dropin_ok)" = 1 ] && echo "validated, installed, byte-identical" || echo "not recorded")
- merge-gate: merge commit $(st_or merge_sha | cut -c1-9); deploy run conclusion $(st_or deploy_conclusion); old config still live after the green deploy: $(st_or old_config_live)
- recreate: first healthy edge response $(st_or recreate_healthy_s)s after the recreate began (make returned at $(st_or recreate_make_s)s); same image: $(st_or recreate_digest_same)
- verify (lines since the recreate): total $(st_or v_total); request_User-Agent with/without $(st_or v_ua_with)/$(st_or v_ua_without); request_X-Access-Subject with/without $(st_or v_subj_with)/$(st_or v_subj_without); on 2xx internal $(st_or v_ok_internal_subj) of $(st_or v_ok_internal); on 403 $(st_or v_s403_subj) of $(st_or v_s403); Cf-Access-Jwt-Assertion keys $(st_or v_leak_jwt); Cf-Access-Authenticated-User-Email keys $(st_or v_leak_email); crowdsec lines-read $(st_or crowdsec_baseline) -> $(st_or crowdsec_after_verify); satlink collector runs $(st_or v_collector_runs), error lines $(st_or v_collector_errors); verify passed: $([ "$(st_get verify_ok)" = 1 ] && echo yes || echo no)
- rotate: log before $(st_or rotate_size_before) bytes; after: access.log.1 $(st_or rotate_one_bytes) bytes (not growing), new access.log $(st_or rotate_new_bytes) bytes (growing); crowdsec lines-read $(st_or rotate_crowdsec); satlink rotated-file reads $(st_or rotate_collector_rotated_reads); rotate passed: $([ "$(st_get rotate_ok)" = 1 ] && echo yes || echo no)
EOF
}

# ── driver ───────────────────────────────────────────────────────────────────────

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; DRY=0 ;;
    --dry-run) APPLY=0; DRY=1 ;;
    --yes) YES=1 ;;
    --confirm-apply) CONFIRM_APPLY=1 ;;
    --confirm-rotate) CONFIRM_ROTATE=1 ;;
    --confirm-rollback) CONFIRM_ROLLBACK=1 ;;
    --print-evidence) EVIDENCE=1 ;;
    --pr) PR="${2:?--pr needs a number}"; shift ;;
    --record) RECORD="${2:?--record needs a file}"; shift ;;
    -h|--help) usage; exit 0 ;;
    preflight|dropin|merge-gate|recreate|verify|rotate|rollback|all)
      [ -z "$PHASE" ] || { echo "ERROR: one phase at a time: '$PHASE' and '$1'" >&2; exit 2; }
      PHASE="$1" ;;
    *) echo "ERROR: unknown argument '$1' (try --help)" >&2; exit 2 ;;
  esac
  shift
done
if [ "$EVIDENCE" -eq 1 ]; then print_evidence; exit $?; fi
[ -n "$PHASE" ] || { usage >&2; exit 2; }
[[ "$PR" =~ ^[0-9]+$ ]] || { echo "ERROR: --pr must be a number" >&2; exit 2; }

umask 077
if [ -z "$RECORD" ]; then
  RECORD="$STATE_DIR/rollout-$(date -u +%Y%m%dT%H%M%SZ)-$PHASE.md"
fi
mkdir -p "$(dirname "$RECORD")" "$STATE_DIR"
[ ! -e "$RECORD" ] || [ ! -s "$RECORD" ] || RECORD="$RECORD.$(date -u +%H%M%S)"
: >"$RECORD"
trap cleanup EXIT
printf 'Record: %s\n' "$RECORD"
rec "# SATL-24 traefik access-log rollout: $PHASE"
rec ""
rec "- started $(ts) as $(id -un) on $(hostname), repo $REPO, branch $(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?'), deploy root $DEPLOY_ROOT"
rec "- mode: $([ "$APPLY" -eq 1 ] && echo '--apply (live)' || echo 'DRY-RUN (read-only phases still execute)')"
rec ""

case "$PHASE" in
  preflight) phase_preflight ;;
  dropin) phase_dropin ;;
  merge-gate) phase_merge_gate ;;
  recreate) phase_recreate ;;
  verify) phase_verify ;;
  rotate) phase_rotate ;;
  rollback) phase_rollback ;;
  all)
    for p in preflight dropin merge-gate recreate verify rotate; do
      pause "about to run phase: $p"
      "phase_${p//-/_}"
    done ;;
esac
rec ""
if [ "$APPLY" -eq 0 ]; then say "- $(ts) **DRY-RUN complete**: preflight/verify read for real; every other phase only printed its plan"
else say "- $(ts) **DONE**: $PHASE, every automated step passed"; fi
printf 'Record: %s\n' "$RECORD"
