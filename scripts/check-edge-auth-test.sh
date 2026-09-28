#!/usr/bin/env bash
# check-edge-auth-test.sh — Prove check-edge-auth.sh still goes RED on an edge that does
# not gate (SERV-171).
#
# WHY THIS EXISTS. The condition it guards cannot be produced on demand: a host with no
# Cloudflare Access application is dashboard state, and the only way to make one on the
# real edge is to break production. So a check for it can go quietly wrong — stop
# sending the header that makes mcp redirect, stop reading `kid=` — and look exactly
# like an edge with nothing to report. Both are green. This is the difference: it runs
# the REAL script, config half and live half, against stub `docker` and `curl` that play
# the edge, and asserts each state is told apart.
#
# The stubs answer with the responses measured on the live edge on 2026-09-28 (a gated
# host: 302 to the team login carrying `kid=`; a host with no application: the origin
# guard's 403 with `x-cf-access-guard: deny`, as catenary was in SERV-171). The gated
# hosts, their audiences and the team domain are read from docker-compose.yml, so the
# suite follows the estate's host list instead of restating it.
#
# Never touches the network, Docker or the running stack, so it is safe at any time.
# Prod edge only: --dev runs the same code with different paths and needs a dev stack.
#
# Usage: ./scripts/check-edge-auth-test.sh   (or: make edge-auth-test)

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="${CHECK:-$REPO/scripts/check-edge-auth.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 not found in PATH" >&2; exit 2; }

BIN="$TMP/bin"
mkdir -p "$BIN"

# docker: the guard's address, and no second address on traefik (so the bind check passes).
cat > "$BIN/docker" <<'STUB'
#!/usr/bin/env bash
[ "$1" = inspect ] || exit 1
case "$*" in
  *'range $k'*)      exit 0 ;;
  *cf-access-guard*) printf '10.9.9.9 ' ;;
  *)                 exit 1 ;;
esac
STUB

# curl: plays the origin for http://, the guard for :4020 and Cloudflare for https://.
# Unreachable is exit 6 with no output, which is what curl does.
cat > "$BIN/curl" <<'STUB'
#!/usr/bin/env bash
url="" host="" html=0 mode=body
while [ $# -gt 0 ]; do
  case "$1" in
    -D-) mode=head ;;
    -w)  mode=code; shift ;;
    -H)  case "$2" in "Host: "*) host="${2#Host: }" ;; "Accept: text/html") html=1 ;; esac; shift ;;
    -o|--max-time) shift ;;
    http://*|https://*) url="$1" ;;
  esac
  shift
done
case "$url" in
  *:4020/healthz) printf 'mode=enforce hosts=6 ok keys=2 refreshed=1s ago'; exit 0 ;;
  https://*)
    h="${url#https://}"; h="${h%%/*}"
    f="$FIX/public/$h"
    # A host that answers non-browser clients differently (mcp: Managed OAuth, 401).
    [ "$html" -eq 0 ] && [ -f "$f.nohtml" ] && f="$f.nohtml"
    [ -f "$f" ] || exit 6
    head="$(cat "$f")" ;;
  http://*)
    # The only non-/ paths the script asks the origin for are the exempt ones, which
    # bypass the guard even on a gated host (switchyard's webhook).
    path="/${url#http://*/}"
    if [ "$path" != / ]; then head='HTTP/1.1 404'
    elif grep -qxF "$host" "$FIX/gated"; then head=$'HTTP/1.1 403\nx-cf-access-guard: deny'
    elif [[ $host != definitely-not-a-real-host* ]]; then head='HTTP/1.1 200'
    else head='HTTP/1.1 404'; fi ;;
  *) exit 6 ;;
esac
case "$mode" in
  code) printf '%s' "$(printf '%s\n' "$head" | awk 'NR==1{print $2}')" ;;
  head) printf '%s\n' "$head" | sed 's/$/\r/'; printf '\r\n' ;;
esac
STUB
chmod +x "$BIN/docker" "$BIN/curl"

# The healthy world: every gated host redirects to the team login with its mapped audience.
python3 - "$REPO/docker-compose.yml" "$TMP/base" <<'PY'
import os, re, sys
raw, out = open(sys.argv[1]).read(), sys.argv[2]
team = re.search(r"^\s*-\s*CF_ACCESS_TEAM_DOMAIN=(\S+)$", raw, re.M).group(1)
amap = re.search(r"^\s*-\s*CF_ACCESS_AUD_MAP=(.*)$", raw, re.M).group(1)
os.makedirs(f"{out}/public")
gated = []
for entry in re.split(r"[,\s]+", amap.strip()):
    if not entry:
        continue
    host, _, aud = entry.partition("=")
    gated.append(host.lower())
    with open(f"{out}/public/{host.lower()}", "w") as fh:
        fh.write(f"HTTP/2 302\nlocation: https://{team}/cdn-cgi/access/login/{host.lower()}?kid={aud}&meta=x.y.z\nserver: cloudflare\n")
open(f"{out}/gated", "w").write("\n".join(gated) + "\n")
open(f"{out}/team", "w").write(team)
PY
HOST="$(head -n 1 "$TMP/base/gated")"
TEAM="$(cat "$TMP/base/team")"
AUD="$(sed -n 's/.*kid=\([0-9a-f]*\).*/\1/p' "$TMP/base/public/$HOST")"

PASS=0; FAIL=0
ok()  { printf '  \033[32mok\033[0m   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; printf '%s\n' "$OUT" | sed 's/^/       | /'; FAIL=$((FAIL + 1)); }

# run <case> <expected rc> <needle>... — the world for this case is $TMP/case, mutated by
# the caller first; every needle must appear in the output, verbatim.
run() {
  local name="$1" want="$2"; shift 2
  OUT="$(PATH="$BIN:$PATH" FIX="$TMP/case" "$CHECK" 2>&1)"; local rc=$?
  local missing=""
  for needle in "$@"; do printf '%s' "$OUT" | grep -qF -- "$needle" || missing="$missing [$needle]"; done
  if [ "$rc" -ne "$want" ]; then bad "$name: exit $rc, expected $want"
  elif [ -n "$missing" ]; then bad "$name: output lacks$missing"
  else ok "$name"; fi
}
world() { rm -rf "$TMP/case"; cp -r "$TMP/base" "$TMP/case"; }
say() { printf '%s\n' "$1" > "$TMP/case/public/$HOST"; }

echo "=== check-edge-auth.sh edge-gating cases (SERV-171) ==="

world
run "every host gated, audiences match -> green, both claims stated" 0 \
  "ok    edge: $HOST is gated by Access" "The origin authenticates:" "The edge gates:"

world
say $'HTTP/2 403\nx-cf-access-guard: deny\nserver: cloudflare'
run "no Access application (the origin guard answered) -> red, naming the host" 1 \
  "FAIL  edge: $HOST has no Cloudflare Access application" \
  "origin: authenticating" "edge:   NOT confirmed gated"

world
say "HTTP/2 302
location: https://$TEAM/cdn-cgi/access/login/$HOST?kid=${AUD%?}0&meta=x.y.z"
[ "${AUD%?}0" != "$AUD" ] || say "HTTP/2 302
location: https://$TEAM/cdn-cgi/access/login/$HOST?kid=${AUD%?}1&meta=x.y.z"
run "live audience differs from CF_ACCESS_AUD_MAP -> red, both audiences shown in full" 1 \
  "FAIL  edge: $HOST is behind an Access application whose audience is not the mapped one" \
  "CF_ACCESS_AUD_MAP:   $AUD"

world
say "HTTP/2 302
location: https://someone-else.cloudflareaccess.com/cdn-cgi/access/login/$HOST?kid=$AUD"
run "redirect to a different team's login -> red" 1 "FAIL  edge: $HOST redirects to"

world
say "HTTP/2 302
location: https://$TEAM/cdn-cgi/access/login/some-other-host.example?kid=$AUD"
run "redirect to the login for a different host -> red" 1 "not for itself"

world
say "HTTP/2 502"
run "answered by something that is neither Access nor the guard -> red" 1 \
  "FAIL  edge: $HOST answered 502"

world
rm "$TMP/case/public/$HOST"
run "edge unreachable is not a pass -> red" 1 "FAIL  edge: could not reach https://$HOST/healthz"

world
printf 'HTTP/2 401\nwww-authenticate: Bearer realm="OAuth", error="invalid_token"\n' > "$TMP/case/public/$HOST.nohtml"
run "a host that 401s non-browsers must be asked as a browser -> green" 0 \
  "ok    edge: $HOST is gated by Access"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
