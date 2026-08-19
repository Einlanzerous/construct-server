#!/usr/bin/env bash
#
# Run the delivery prober once (SERV-111).
#
# This is the host-side producer for the DEV column of Switchyard's delivery
# matrix. Switchyard's in-process reconciler covers `prod` and structurally
# cannot cover `dev`: it runs on `construct_net`, dev runs on
# `construct_dev_net`, and the two share nothing on purpose. Bridging them is
# what SERV-106/107 closed. The HOST can reach both — dev publishes
# 127.0.0.1:14002 and friends — so the probe runs here and posts inward.
# Switchyard never crosses the boundary; it receives.
#
# Invoked by delivery-prober.service on a timer. Also runnable by hand:
#
#   make probe-delivery
#   sudo systemctl start delivery-prober.service   # exactly what the timer does
#
# ── Why it runs the script out of the IMAGE ────────────────────────────────
#
# `probe-delivery.ts` lives in the switchyard repo (`server/scripts/`) and is
# deliberately NOT vendored here. It is a client of an API contract that moves
# with the server — SWY-284 changed how a failed probe is reported, and a copy in
# this repo would have kept silently posting nothing. Running it from the image
# the live switchyard container is already using means the prober and the ingest
# it posts to are always the same build, for free, with no checkout, no bun on
# the runner's bare system PATH (the SERV-62 trap), and nothing to keep in sync.
#
# ── The one-cron rule ──────────────────────────────────────────────────────
#
# SWY-194 (container-inspect, tier B) is a SECOND producer for the same ingest,
# and its collector will also need to run on this host on a schedule. It must be
# added as another ExecStart on delivery-prober.service — NOT as its own timer
# and env file. Two host jobs with two configs and two tokens posting to one
# ledger is how the two disagree at 3am with no way to tell which was stale.
# This script takes the in-image script path as $1 precisely so that second
# producer reuses it.

set -euo pipefail

SWITCHYARD_CONTAINER="${SWITCHYARD_CONTAINER:-switchyard}"
# The seam described above. Default is tier A; SWY-194's collector passes its own.
IN_IMAGE_SCRIPT="${1:-server/scripts/probe-delivery.ts}"

die() { echo "Error: $*" >&2; exit 1; }

# ── config ──────────────────────────────────────────────────────────────────
# An empty environment variable is not a value (the repo's oldest invariant —
# db/init-db.sh and the SIGNET_API_TOKEN crash-loop both learned it the hard
# way). Skip loudly rather than substitute a default: probe-delivery.ts applies
# the same rule to these four, but it would be doing so from inside a container
# whose stderr is one more layer away from whoever is reading `systemctl status`.
for v in SWITCHYARD_URL SWITCHYARD_TOKEN PROBE_ENVIRONMENT PROBE_TARGETS; do
  val="${!v-}"
  if [ -z "${val// }" ]; then
    die "$v is unset or empty.
  The unit reads these from /etc/delivery-prober/prober.env, which ansible
  writes only when delivery_prober_token is available. If that file is missing,
  the role installed the unit but never had a token to give it."
  fi
done

# ── the image ───────────────────────────────────────────────────────────────
# Read off the running container rather than from versions.env, so the prober
# tracks what is actually deployed rather than what the pins say should be. If
# the two ever disagree, the running one is the one whose API this posts to.
#
# Run the resolved image ID, not the tag. `.Config.Image` is the reference as
# written in compose — `…/backend:${SWITCHYARD_TAG}`, a major.minor tag that
# CLAUDE.md documents as deliberately MOVING. Running that resolves whatever the
# tag points at locally right now, which is not necessarily what the live
# container was created from: any pull-without-recreate opens the gap, and a
# scoped SERV-109 deploy or a queue-cancelled one leaves exactly that state with
# nothing red in the Actions tab. In that window the tag would run a newer
# probe-delivery.ts against the older ingest it is posting to — the precise skew
# "prober and ingest are always the same build" claims to remove. `.Image` is the
# image ID the container actually runs, and `docker run` takes it directly.
image_ref="$(docker inspect -f '{{.Config.Image}}' "$SWITCHYARD_CONTAINER" 2>/dev/null || true)"
image_id="$(docker inspect -f '{{.Image}}' "$SWITCHYARD_CONTAINER" 2>/dev/null || true)"
[ -n "$image_id" ] || die "container '$SWITCHYARD_CONTAINER' is not running — nothing to take the prober from, and its API is where the results go anyway."

# Both: the ref is what a human recognises, the ID is what actually ran.
echo "[probe-delivery] image=$image_ref id=${image_id#sha256:} script=$IN_IMAGE_SCRIPT env=$PROBE_ENVIRONMENT"

# ── run ─────────────────────────────────────────────────────────────────────
# --network host is what makes this work at all: the dev tier publishes on
# 127.0.0.1 only, which is unreachable from a bridge network, and prod
# switchyard is on localhost:4002. A short-lived container in the host netns
# sees both. Nothing is published and nothing is left running.
#
# Env is passed BY NAME (-e VAR, no `=value`), so the token is inherited from
# this process's environment instead of appearing in the container's argv, which
# is world-readable via /proc for the life of the run.
#
# Streamed through `tee`, not captured into a variable. Buffering the whole run
# and echoing it at the end loses ALL of it on the one failure the unit's
# TimeoutStartSec=120 exists to catch: systemd SIGTERMs the unit's cgroup, bash
# included, so a final `printf` never runs and the journal keeps only the header
# line above. `make probe-status` would report `failed` with nothing to say why.
# tee puts every line in the journal as it happens and leaves a copy to grep.
log="$(mktemp)"
# PrivateTmp=true in the unit gives this run its own /tmp, so the file is not
# visible to anything else on the box and dies with the unit either way.
trap 'rm -f "$log"' EXIT

rc=0
docker run --rm --network host \
  -e SWITCHYARD_URL -e SWITCHYARD_TOKEN -e PROBE_ENVIRONMENT -e PROBE_TARGETS \
  ${PROBE_TIMEOUT_MS:+-e PROBE_TIMEOUT_MS} \
  "$image_id" bun "/app/$IN_IMAGE_SCRIPT" 2>&1 | tee "$log" || rc=$?

[ "$rc" -eq 0 ] || die "prober exited $rc"

# ── did it actually record anything? ────────────────────────────────────────
# probe-delivery.ts exits 0 even when every POST is rejected — it reports per
# target and carries on, which is right for one dead service and wrong as an
# exit code. The failure that matters here is the silent one: an expired or
# wrongly-scoped token 401/403s every POST, the run looks clean, and the matrix
# quietly stops advancing while `systemctl status` still says the timer is fine.
# That is the SWY-128 shape this ticket exists to avoid, so it is a hard failure.
#
# Matching the script's own stderr text is a coupling to another repo, and a
# deliberate one: the alternative is trusting an exit code that is documented
# not to carry this. If probe-delivery.ts ever grows a real exit code, delete
# this block rather than keeping both.
if grep -q "POST failed" "$log"; then
  die "at least one result was NOT recorded (see the POST failed lines above).
  A 401/403 means the token is expired or missing deployments:observe.
  A 404 means the service is not in Switchyard's inventory — a probe that got no
  answer deliberately does not auto-register one, so the name has to exist first."
fi

# Not fatal: the prober falls back to /healthz for every target and says so. But
# it silently means a service with a custom health_path is being probed at the
# wrong URL, which reads as `unreachable` for something that is running fine.
if grep -q "could not read /v1/services" "$log"; then
  echo "[probe-delivery] WARNING: health paths came from the fallback, not the inventory." >&2
fi
