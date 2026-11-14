#!/usr/bin/env bash
# satlink-edge-rollout.sh — run, and RECORD, the owner steps of the SATL-58 edge PR (SATL-16 row 3).
#
# The PR body lists five ordered owner preconditions and a post-deploy checklist. This script
# is the same list as subcommands, each one idempotent and stopping at its first failure, with
# a markdown record of what ran: timestamps, the command lines, exit codes, pass/fail per check.
#
#   satlink-edge-rollout.sh [global flags] <phase> [--apply]
#
#   exporter     clone satlink at v0.2.0 into a scratch dir, run its docker-state install.sh,
#                then record timer state, Linger and the state-file age (<35s, twice, 60s apart)
#   access       print the purser provision PLAN; with --apply, apply it. Then pause for the
#                dashboard policy, take the AUD (silent prompt or SATLINK_ACCESS_AUD), patch
#                BOTH __SATLINK_ACCESS_AUD__ placeholders and show the (masked) diff. No commit.
#   vault        read the allowlist email silently, pipe it to `signet set`, add-key, sync,
#                then check [in sync] count == 1 and the value is non-empty (signet exec -redact)
#   pre-merge    `make assert-env-keys vault=1` from a scratch checkout of the PR branch
#   post-deploy  guard healthy, another gated host 302, satlink 302, no tailscale serve for it,
#                satlink:4018 -> 403 from inside construct_net, purser plan shows no drift.
#                The signed-in checks are the owner's: printed as instructions, never automated.
#   all          the five phases in that order, pausing before each
#
# Global flags: --dry-run   print the commands, run nothing, change nothing
#               --record F  record file (default ~/.cache/satlink-rollout/rollout-<utc>-<phase>.md)
#               --yes       do not pause between phases (the secret prompts still happen)
#               --secrets-from-stdin  take the AUD / email from stdin lines, not the tty (tests)
#               --replace   (vault only) run `signet set` even though the key already exists
#               --confirm-apply  skip the pause before an --apply (--yes alone never does)
#               --apply     (access only) really run `purser provision-service ... --apply`
#
# SECRET HANDLING. Two values must never reach the record, stdout, argv, the repo or a child's
# environment: the allowlist email and the Access AUD. Both live only in unexported shell
# variables; the email reaches `signet set` on stdin through a `printf` builtin (no argv), and
# reaches the non-empty check only through `signet exec`, which is what injects it. The AUD is
# patched in with bash string replacement, not sed, so it is in no argv either, and the diff is
# shown with it masked. An AUD or email put in the environment ahead of time is read once and
# unset, so no child inherits it. Command lines are written to the record through redact(), and
# the EXIT trap re-scans the record for the values and blanks it if one is ever found. The
# record holds pass/fail and status codes, never output of a secret-bearing command. No `set -x`.
#
# Nothing here merges, pushes or commits. `access` edits docker-compose.yml in the working tree
# and leaves the commit to the owner.

set -euo pipefail
set +a +x +v
unset BASH_XTRACEFD
PS4='+ '

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PR_BRANCH="${SATLINK_PR_BRANCH:-feat/satlink-edge-satl-58}"
SATLINK_REPO="${SATLINK_REPO:-Einlanzerous/satlink}"
SATLINK_VERSION_TAG="v0.2.0"
HOSTNAME_FQDN="satlink.zerogravity.industries"
OTHER_GATED_HOST="${OTHER_GATED_HOST:-switchyard.zerogravity.industries}"
PROBE_CONTAINER="${PROBE_CONTAINER:-traefik}"
VAULT_PROJECT="construct-server"
VAULT_KEY="SATLINK_ACCESS_ALLOWED_EMAILS"
STATE_FILE="${SATLINK_STATE_FILE:-$HOME/.local/share/satlink-docker-state/state/docker-state.json}"
PLACEHOLDER="__SATLINK_ACCESS_AUD__"
AGE_LIMIT=35
AGE_GAP="${SATLINK_ROLLOUT_AGE_GAP:-60}"   # seconds between the two age checks (tests shorten it)

DRY=0
YES=0
APPLY=0
REPLACE=0
STDIN_SECRETS=0
CONFIRM_APPLY=0
RECORD=""
PHASE=""

# Secret values held in this shell only, never exported.
SECRETS=()
unset EMAIL AUD   # drops any inherited export attribute before they ever hold a secret
EMAIL=""
AUD=""
# The environment may carry them from the owner's shell: take them once, then drop them so that
# no child process inherits them.
AUD_FROM_ENV="${SATLINK_ACCESS_AUD:-}"
unset SATLINK_ACCESS_AUD "$VAULT_KEY" 2>/dev/null || true

SCRATCH=""
OUT=""
RC=0

usage() {
  sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

# ── record + output ──────────────────────────────────────────────────────────────

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

redact() {
  local s="$1" v
  for v in "${SECRETS[@]+"${SECRETS[@]}"}"; do
    [ -n "$v" ] && s="${s//"$v"/<redacted>}"
  done
  printf '%s' "$s"
}

rec() { printf '%s\n' "$(redact "$*")" >>"$RECORD"; }
say() { printf '%s\n' "$(redact "$*")"; rec "$*"; }

die() {
  say "- $(ts) **FAIL**: $*"
  exit 1
}

pass() { say "- $(ts) PASS: $*"; }

# Show, and record, a command line. Arguments are never secret by construction; redact() is
# the second line of defence.
logcmd() { rec "- $(ts) \`$*\`"; printf '+ %s\n' "$(redact "$*")"; }

# run CMD...  — logs, runs (unless --dry-run), captures combined output in OUT and the exit
# code in RC. Never aborts on a non-zero exit: callers decide. Output is not recorded.
run() {
  logcmd "$@"
  OUT=""; RC=0
  if [ "$DRY" -eq 1 ]; then rec "  - dry-run: not executed"; return 0; fi
  if OUT="$("$@" 2>&1 </dev/null)"; then RC=0; else RC=$?; fi
  rec "  - exit $RC"
}

# run_must CMD... — run, and stop at the first failure.
run_must() {
  run "$@"
  [ "$RC" -eq 0 ] || die "command exited $RC: $(redact "$1")"
}

# check NAME FUNC [ARGS] — FUNC returns 0 for pass. Under --dry-run nothing is evaluated.
check() {
  local name="$1"; shift
  if [ "$DRY" -eq 1 ]; then
    say "- $(ts) DRY-RUN: would check: $name"
    return 0
  fi
  if "$@"; then pass "$name"; else die "$name"; fi
}

# A line of output is shown to the owner but never recorded, and AUD-bearing lines are withheld
# (purser may echo an Access application's AUD after an apply).
show_filtered() {
  local line
  while IFS= read -r line; do
    if [[ "${line,,}" == *aud* ]] || [[ "$line" =~ [0-9a-fA-F]{32} ]]; then
      printf '  [line withheld: may carry an AUD]\n'
    else
      printf '  %s\n' "$(redact "$line")"
    fi
  done <<<"$1"
}

need() {
  [ "$DRY" -eq 1 ] && return 0
  local t
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || die "required tool not on PATH: $t"
  done
}

pause() {   # pause MSG [force]  — force ignores --yes
  say "- $(ts) PAUSE: $1"
  [ "$DRY" -eq 1 ] && return 0
  [ "$YES" -eq 1 ] && [ "${2:-}" != force ] && return 0
  [ "$CONFIRM_APPLY" -eq 1 ] && [ "${2:-}" = force ] && return 0
  [ -r /dev/tty ] || die "needs a terminal to pause (or pass --yes): $1"
  printf '\n>>> %s\n>>> Press Enter to continue, Ctrl-C to stop. ' "$1" >/dev/tty
  read -r _ </dev/tty
}

# Read a secret silently from the terminal. Sets the variable named by $1; value never echoed.
read_secret() {
  local __name="$1" __prompt="$2" __v=""
  if [ "$STDIN_SECRETS" -eq 1 ]; then
    IFS= read -r __v || true   # --secrets-from-stdin: one value per line, in prompt order
  else
    [ -r /dev/tty ] || die "needs a terminal for the silent prompt: $__prompt"
    printf '%s' "$__prompt" >/dev/tty
    read -rs __v </dev/tty
    printf '\n' >/dev/tty
  fi
  printf -v "$__name" '%s' "$__v"
}

new_scratch() {
  [ -z "$SCRATCH" ] || rm -rf "$SCRATCH"
  SCRATCH="$(mktemp -d)"
}

cleanup() {
  local rc=$?
  [ -n "$SCRATCH" ] && [ -d "$SCRATCH" ] && rm -rf "$SCRATCH"
  if [ -n "$RECORD" ] && [ -f "$RECORD" ]; then
    # Last line of defence: if a secret value ever reached the record, blank the record.
    local v body
    body="$(<"$RECORD")"
    for v in "${SECRETS[@]+"${SECRETS[@]}"}"; do
      if [ -n "$v" ] && [[ "$body" == *"$v"* ]]; then
        printf '# RECORD WITHHELD: a secret value reached it and it was blanked.\n' >"$RECORD"
        printf 'ERROR: secret value detected in record; record blanked.\n' >&2
        rc=1
        break
      fi
    done
    printf '\n_Finished %s, exit %s._\n' "$(ts)" "$rc" >>"$RECORD"
  fi
  exit "$rc"
}

# ── phase: exporter ──────────────────────────────────────────────────────────────

state_age_ok() {
  local m now age
  [ -f "$STATE_FILE" ] || { rec "  - state file missing"; return 1; }
  m="$(stat -c %Y "$STATE_FILE")"; now="$(date +%s)"; age=$((now - m))
  rec "  - state file age ${age}s (limit <${AGE_LIMIT}s)"
  [ "$age" -ge 0 ] && [ "$age" -lt "$AGE_LIMIT" ]
}

state_age_wait() {   # first check: the timer may need a moment after the install
  for _ in 1 2 3 4 5 6 7 8; do
    state_age_ok && return 0
    sleep 5
  done
  return 1
}

phase_exporter() {
  say "## exporter"
  need git gh systemctl loginctl stat
  new_scratch
  local clone="$SCRATCH/satlink" user; user="$(id -un)"
  run_must gh repo clone "$SATLINK_REPO" "$clone" -- --depth 1 --branch "$SATLINK_VERSION_TAG" --quiet
  check "clone is exactly $SATLINK_VERSION_TAG" \
    test "$(git -C "$clone" describe --tags --exact-match 2>/dev/null)" = "$SATLINK_VERSION_TAG"
  # install.sh is idempotent in satlink: re-running reinstalls the units and restarts the timer.
  run_must env -C "$clone" SATLINK_TAG=0.2.0 host/docker-state/install.sh
  run systemctl --user is-active satlink-docker-state.timer
  rec "  - timer: ${OUT:-n/a}"
  check "satlink-docker-state.timer is active" test "$RC" -eq 0 -a "$OUT" = "active"
  run systemctl --user list-timers satlink-docker-state.timer
  if [ "$DRY" -eq 0 ]; then rec '```'; rec "$OUT"; rec '```'; fi
  run loginctl show-user "$user" -p Linger
  rec "  - ${OUT:-n/a}"
  check "Linger=yes for $user" test "$OUT" = "Linger=yes"
  logcmd "state-file age check 1 of 2 ($STATE_FILE)"
  check "state file younger than ${AGE_LIMIT}s (check 1)" state_age_wait
  [ "$DRY" -eq 1 ] || sleep "$AGE_GAP"
  logcmd "state-file age check 2 of 2, ${AGE_GAP}s later"
  check "state file younger than ${AGE_LIMIT}s (check 2, ${AGE_GAP}s later)" state_age_ok
}

# ── phase: access ────────────────────────────────────────────────────────────────

PURSER_ARGS=(provision-service --service satlink --hostname "$HOSTNAME_FQDN" --mode tunnelled
  --tunnel prod --upstream http://traefik:9080 --access gated)

count_in() {   # count_in FILE NEEDLE — occurrences of a fixed string
  local c rest; c="$(cat "$1"; printf x)"; c="${c%x}"
  rest="${c//"$2"/}"
  echo $(( (${#c} - ${#rest}) / ${#2} ))
}

patch_aud() {
  local f="$REPO/docker-compose.yml" n_ph n_aud content
  n_ph="$(count_in "$f" "$PLACEHOLDER")"
  n_aud="$(count_in "$f" "$AUD")"
  if [ "$n_ph" -eq 0 ] && [ "$n_aud" -eq 2 ]; then
    rec "  - placeholders already replaced with the supplied AUD (2 occurrences): nothing to patch"
    return 0
  fi
  [ "$n_ph" -eq 2 ] || { rec "  - expected 2 placeholders, found $n_ph (AUD occurrences: $n_aud)"; return 1; }
  content="$(cat "$f"; printf x)"; content="${content%x}"
  content="${content//"$PLACEHOLDER"/"$AUD"}"
  printf '%s' "$content" >"$f"
  [ "$(count_in "$f" "$PLACEHOLDER")" -eq 0 ] && [ "$(count_in "$f" "$AUD")" -eq 2 ]
}

show_masked_diff() {
  local line
  say "- $(ts) \`git diff -- docker-compose.yml\` (AUD masked on screen, not recorded)"
  git -C "$REPO" diff --stat -- docker-compose.yml
  git -C "$REPO" diff -U0 -- docker-compose.yml | while IFS= read -r line; do
    printf '  %s\n' "${line//"$AUD"/<AUD>}"
  done
}

phase_access() {
  say "## access"
  need docker git
  run docker exec purser purser "${PURSER_ARGS[@]}"
  [ "$DRY" -eq 1 ] || show_filtered "$OUT"
  [ "$RC" -eq 0 ] || die "purser plan exited $RC"
  if [ "$APPLY" -eq 1 ]; then
    pause "about to APPLY the purser plan above (creates DNS, Access app, tunnel route)" force
    run docker exec purser purser "${PURSER_ARGS[@]}" --apply
    [ "$DRY" -eq 1 ] || show_filtered "$OUT"
    [ "$RC" -eq 0 ] || die "purser apply exited $RC"
    pass "purser apply"
  else
    say "- $(ts) NOTE: plan only. Re-run \`access --apply\` to apply it."
  fi
  pause "In the Cloudflare dashboard apply ruling 3's members-group policy to the satlink Access application, then read its AUD. Next you supply the AUD (silent prompt, or SATLINK_ACCESS_AUD in the environment)."
  if [ "$DRY" -eq 1 ]; then
    say "- $(ts) DRY-RUN: would read the AUD, replace both $PLACEHOLDER in docker-compose.yml, show the masked git diff (no commit)"
    return 0
  fi
  AUD="$AUD_FROM_ENV"
  [ -n "$AUD" ] || read_secret AUD "Access AUD (input hidden): "
  SECRETS+=("$AUD")
  [[ "$AUD" =~ ^[0-9a-f]{64}$ ]] || die "the AUD is not 64 lowercase hex characters (the shape of the other AUDs here); nothing patched"
  logcmd "patch both $PLACEHOLDER in docker-compose.yml (bash string replacement, no argv)"
  check "both $PLACEHOLDER replaced in docker-compose.yml" patch_aud
  show_masked_diff
  AUD=""
  say "- $(ts) NOTE: not committed. Review the diff, then commit it on the PR branch yourself."
}

# ── phase: vault ─────────────────────────────────────────────────────────────────

vault_row() { signet status 2>/dev/null | awk -v p="$VAULT_PROJECT" -v k="$VAULT_KEY" '$1==p && $2==k'; }

vault_in_sync_one() {
  local row n
  row="$(vault_row)"
  n="$(printf '%s\n' "$row" | grep -o '\[in sync\]' | wc -l | tr -d ' ')"
  rec "  - [in sync] count for $VAULT_KEY: $n"
  [ "$n" = "1" ]
}

vault_nonempty() {
  logcmd signet exec -secret "$VAULT_PROJECT/$VAULT_KEY" -redact -- bash -c '<prints 0 if the value has a non-space character, else 1>'
  local out rc=0
  # The child sees the secret only because signet exec injects it; it prints one digit.
  out="$(signet exec -secret "$VAULT_PROJECT/$VAULT_KEY" -redact -- bash -c \
    'v="${SATLINK_ACCESS_ALLOWED_EMAILS-}"; v="${v//[[:space:]]/}"; if [ -n "$v" ]; then echo 0; else echo 1; fi' 2>/dev/null)" || rc=$?
  [[ "$out" =~ ^[01]$ ]] || out="n/a"
  rec "  - exit $rc; emptiness flag: $out (0 = non-empty)"
  [ "$rc" -eq 0 ] && [ "$out" = "0" ]
}

phase_vault() {
  say "## vault"
  need signet
  local row have_key=0 have_target=0
  if [ "$DRY" -eq 0 ]; then
    signet status >/dev/null 2>&1 || die "signet status failed; not guessing whether the key exists"
    row="$(vault_row || true)"
    [ -n "$row" ] && have_key=1
    [[ "$row" == *"PROD_ENV_FILE"* ]] && have_target=1
  fi
  if [ "$have_key" -eq 1 ] && [ "$REPLACE" -eq 0 ]; then
    say "- $(ts) SKIP: $VAULT_KEY is already in the vault (signet set not repeated; the stored value is kept)"
  else
    if [ "$DRY" -eq 1 ]; then
      say "- $(ts) DRY-RUN: would read the email with read -rs, then: printf <email> | signet set --project $VAULT_PROJECT --name $VAULT_KEY"
    else
      read_secret EMAIL "Owner allowlist email (input hidden): "
      [ -n "${EMAIL//[[:space:]]/}" ] || die "empty email; nothing written"
      SECRETS+=("$EMAIL")
      logcmd signet set --project "$VAULT_PROJECT" --name "$VAULT_KEY" "<value on stdin>"
      local rc=0
      # printf is a builtin: the value is on a pipe, in no argv and in no environment.
      printf '%s' "$EMAIL" | signet set --project "$VAULT_PROJECT" --name "$VAULT_KEY" >/dev/null 2>&1 || rc=$?
      rec "  - exit $rc"
      [ "$rc" -eq 0 ] || die "signet set exited $rc (output withheld)"
      pass "signet set"
      EMAIL=""
    fi
  fi
  if [ "$have_target" -eq 1 ]; then
    say "- $(ts) SKIP: $VAULT_KEY already targets PROD_ENV_FILE"
  else
    run_must signet target add-key --project "$VAULT_PROJECT" --gh-secret PROD_ENV_FILE --name "$VAULT_KEY"
  fi
  run_must signet sync
  check "$VAULT_KEY shows exactly one [in sync]" vault_in_sync_one
  check "$VAULT_KEY is non-empty (whitespace-safe, via signet exec -redact)" vault_nonempty
}

# ── phase: pre-merge ─────────────────────────────────────────────────────────────

phase_pre_merge() {
  say "## pre-merge"
  need git make signet
  new_scratch
  local url; url="$(git -C "$REPO" remote get-url origin)"
  if [[ "$url" == *://*@* ]]; then   # never log credentials embedded in the remote URL
    local ui="${url#*://}"; SECRETS+=("${ui%%@*}")
  fi
  run_must git clone --quiet --single-branch --branch "$PR_BRANCH" "$url" "$SCRATCH/pr"
  check "the pushed $PR_BRANCH no longer holds $PLACEHOLDER" test "$(grep -c "$PLACEHOLDER" "$SCRATCH/pr/docker-compose.yml" 2>/dev/null || true)" = 0
  rec "  - scratch checkout at $(git -C "$SCRATCH/pr" rev-parse --short HEAD 2>/dev/null || echo '?') of $PR_BRANCH (the pushed branch, not the working tree)"
  run make -C "$SCRATCH/pr" assert-env-keys vault=1
  check "make assert-env-keys vault=1 passes from a scratch checkout of $PR_BRANCH" test "$RC" -eq 0
}

# ── phase: post-deploy ───────────────────────────────────────────────────────────

http_code() { curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H 'Accept: text/html' "https://$1/" 2>/dev/null || true; }
redirects_to_access() {
  local hdrs
  hdrs="$(curl -s -D- -o /dev/null --max-time 10 -H 'Accept: text/html' "https://$1/" 2>/dev/null | tr -d '\r')" || true
  grep -i '^location:' <<<"$hdrs" | grep -c -i 'cloudflareaccess\.com' >/dev/null
}

host_is_302() {   # host_is_302 HOST — 302 and the redirect is to the Access login
  local code; code="$(http_code "$1")"
  rec "  - GET https://$1/ -> $code"
  [ "$code" = "302" ] && redirects_to_access "$1"
}

guard_healthy() {
  run docker inspect -f '{{.State.Health.Status}}' cf-access-guard
  rec "  - health: ${OUT:-n/a}"
  [ "$RC" -eq 0 ] && [ "$OUT" = "healthy" ]
}

no_tailscale_serve() {
  run tailscale serve status
  [ "$RC" -eq 0 ] || return 1   # a status we could not read proves nothing
  ! grep -Eqi 'satlink|:4018' <<<"$OUT"
}

direct_is_403() {
  run docker exec "$PROBE_CONTAINER" wget -q -S -O /dev/null --timeout=5 http://satlink:4018/
  local status; status="$(grep -o 'HTTP/[0-9.]* [0-9]*' <<<"$OUT" | head -1 | awk '{print $2}')"
  rec "  - satlink:4018 from $PROBE_CONTAINER -> ${status:-no response}"
  [ "$status" = "403" ]
}

purser_no_drift() {
  run docker exec purser purser "${PURSER_ARGS[@]}"
  [ "$RC" -eq 0 ] || return 1
  # The plan's last summary line reads "N in place, M to do, K skipped".
  grep -Eq ', 0 to do,' <<<"$OUT"
}

phase_post_deploy() {
  say "## post-deploy"
  need docker curl tailscale
  check "cf-access-guard is healthy" guard_healthy
  check "$OTHER_GATED_HOST still answers the Access 302" host_is_302 "$OTHER_GATED_HOST"
  check "unauthenticated $HOSTNAME_FQDN answers the Access 302" host_is_302 "$HOSTNAME_FQDN"
  check "tailscale serve status shows nothing for satlink" no_tailscale_serve
  check "satlink:4018 with no assertion answers 403 from $PROBE_CONTAINER on construct_net" direct_is_403
  check "purser plan shows no drift (0 to do)" purser_no_drift
  say "- $(ts) OWNER-CHECK (not automated, pending):"
  say "  - signed in at https://$HOSTNAME_FQDN/ : the site loads and /api/overview returns 200"
  say "  - signed in : /api/collectors shows the docker collector ok and not stale, at least 2 minutes after the deploy"
  say "  - run \`make assert-env-keys vault=1\` once more if the vault changed since pre-merge"
}

# ── driver ───────────────────────────────────────────────────────────────────────

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --yes) YES=1 ;;
    --apply) APPLY=1 ;;
    --confirm-apply) CONFIRM_APPLY=1 ;;   # skip the apply pause (--yes alone does not)
    --replace) REPLACE=1 ;;
    --secrets-from-stdin) STDIN_SECRETS=1 ;;
    --record) RECORD="${2:?--record needs a file}"; shift ;;
    -h|--help) usage; exit 0 ;;
    exporter|access|vault|pre-merge|post-deploy|all)
      [ -z "$PHASE" ] || { echo "ERROR: one phase at a time: '$PHASE' and '$1'" >&2; exit 2; }
      PHASE="$1" ;;
    *) echo "ERROR: unknown argument '$1' (try --help)" >&2; exit 2 ;;
  esac
  shift
done
[ -n "$PHASE" ] || { usage >&2; exit 2; }
if [ "$APPLY" -eq 1 ] && [ "$PHASE" != "access" ] && [ "$PHASE" != "all" ]; then
  echo "ERROR: --apply belongs to the access phase only" >&2; exit 2
fi
[ -z "$AUD_FROM_ENV" ] || SECRETS+=("$AUD_FROM_ENV")

umask 077
if [ -z "$RECORD" ]; then
  RECORD_DIR="${SATLINK_ROLLOUT_DIR:-$HOME/.cache/satlink-rollout}"
  mkdir -p "$RECORD_DIR"
  RECORD="$RECORD_DIR/rollout-$(date -u +%Y%m%dT%H%M%SZ)-$PHASE.md"
else
  mkdir -p "$(dirname "$RECORD")"
fi
[ ! -e "$RECORD" ] || [ ! -s "$RECORD" ] || RECORD="$RECORD.$(date -u +%H%M%S)"   # never overwrite an earlier record
: >"$RECORD"
trap cleanup EXIT
printf 'Record: %s\n' "$RECORD"
rec "# SATL-58 satlink edge rollout: $PHASE"
rec ""
rec "- started $(ts) as $(id -un) on $(hostname), repo $REPO, branch $(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
rec "- mode: $([ "$DRY" -eq 1 ] && echo DRY-RUN || echo live)$([ "$APPLY" -eq 1 ] && echo ', --apply')"
rec ""

case "$PHASE" in
  exporter) phase_exporter ;;
  access) phase_access ;;
  vault) phase_vault ;;
  pre-merge) phase_pre_merge ;;
  post-deploy) phase_post_deploy ;;
  all)
    for p in exporter access vault pre-merge post-deploy; do
      case "$p" in
        pre-merge) pause "before pre-merge: commit and PUSH the AUD patch from 'access' first; the check reads the pushed branch" ;;
        post-deploy) pause "before post-deploy: the PR must be merged and its deploy finished" ;;
        *) pause "about to run phase: $p" ;;
      esac
      "phase_${p//-/_}"
    done ;;
esac
rec ""
if [ "$DRY" -eq 1 ]; then say "- $(ts) **DRY-RUN complete**: nothing was executed, no check was evaluated"
else say "- $(ts) **DONE**: $PHASE, every automated step passed (owner-checks excepted)"; fi
printf 'Record: %s\n' "$RECORD"
