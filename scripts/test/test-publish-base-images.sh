#!/usr/bin/env bash
# test-publish-base-images.sh — failing tests for scripts/publish-base-images.sh and
# scripts/base-images-sweep.sh, plus a few structural assertions on base-images.yml that a
# behavioural test cannot reach (SERV-294). Run by `make base-images-test`, which is what
# base-images.yml's "Prove the check can fail" step runs.
#
# Every case here can fail: each refusal is checked against a branch that must stay
# untouched, and the workflow greps fail when the line they name is edited out.
#
# The shims live in scripts/test/mock-bin-base-images, never in scripts/test/mock-bin:
# backup-test.sh prepends that whole directory to PATH.
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$HERE/../.." && pwd)"
PUBLISH="$ROOT/scripts/publish-base-images.sh"
SWEEP="$ROOT/scripts/base-images-sweep.sh"
WORKFLOW="$ROOT/.github/workflows/base-images.yml"
MOCK="$HERE/mock-bin-base-images"
REAL_GIT="$(command -v git)"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fails=0
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }

# The test commits, so it owns its git identity and ignores the caller's config.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
export RUNNER_TEMP="$T/runner"; mkdir -p "$RUNNER_TEMP"
# Synthetic: it only has to be recognisable if it ever shows up somewhere it must not.
TOKEN="sentinel-token-0123456789abcdef"

bare() { "$REAL_GIT" init -q --bare "$1"; }
branch_sha() { "$REAL_GIT" -C "$1" rev-parse -q --verify refs/heads/estate-results 2>/dev/null || true; }
mkdoc() { # file generatedAt [scope] [schema]
  jq -n --arg g "$2" --arg s "${3:-public-only}" --argjson v "${4:-1}" \
    '{schema: $v, scope: $s, generatedAt: $g, today: "2026-11-23", mode: "estate", exit: 0,
      summary: {findings: 0}, repos: [], images: []}' >"$1"
}
# publish REMOTE DOC [env...]: runs the script, rc and output in $rc / $T/pub.out
publish() {
  local remote="$1" doc="$2"; shift 2
  rc=0
  env PATH="$MOCK:$PATH" PUBLISH_REMOTE="$remote" PUBLISH_GH_TOKEN="$TOKEN" "$@" "$PUBLISH" "$doc" >"$T/pub.out" 2>&1 || rc=$?
}

echo "test-publish-base-images: publish refusals"
R="$T/remote.git"; bare "$R"
mkdoc "$T/good.json" 2026-11-23T07:00:00Z
mkdoc "$T/unfiltered.json" 2026-11-23T07:00:00Z unfiltered
mkdoc "$T/schema2.json" 2026-11-23T07:00:00Z public-only 2
echo 'not json' >"$T/garbage.json"
jq 'del(.scope)' "$T/good.json" >"$T/noscope.json"
jq 'del(.generatedAt)' "$T/good.json" >"$T/nogen.json"
for c in unfiltered schema2 garbage noscope nogen; do
  publish "$R" "$T/$c.json"
  if [ "$rc" = 2 ] && [ -z "$(branch_sha "$R")" ]; then ok "refuses $c: exit 2, nothing pushed"
  else bad "refuses $c: exit $rc, branch: $(branch_sha "$R")"; fi
done
publish "$R" "$T/missing.json"
if [ "$rc" = 2 ]; then ok "refuses a missing file: exit 2"; else bad "missing file: exit $rc"; fi
rc=0; env -u PUBLISH_GH_TOKEN PATH="$MOCK:$PATH" PUBLISH_REMOTE="$R" "$PUBLISH" "$T/good.json" >"$T/pub.out" 2>&1 || rc=$?
if [ "$rc" = 2 ] && [ -z "$(branch_sha "$R")" ]; then ok "a missing PUBLISH_GH_TOKEN exits 2"; else bad "no token: exit $rc"; fi
rc=0; env PATH="$MOCK:$PATH" PUBLISH_REMOTE="$R" PUBLISH_GH_TOKEN= "$PUBLISH" "$T/good.json" >"$T/pub.out" 2>&1 || rc=$?
if [ "$rc" = 2 ]; then ok "a blank PUBLISH_GH_TOKEN exits 2"; else bad "blank token: exit $rc"; fi
# An unreachable remote is exit 2, not "branch absent, push away".
publish "$T/does-not-exist.git" "$T/good.json"
if [ "$rc" = 2 ]; then ok "an unlistable remote is exit 2, not read as absent"; else bad "unlistable remote: exit $rc"; fi

echo "test-publish-base-images: first publish, commit shape, ordering"
publish "$R" "$T/good.json" SHIM_LOG="$T/argv.log"
if [ "$rc" = 0 ] && [ -n "$(branch_sha "$R")" ]; then ok "publishes when the branch is absent"; else bad "first publish: exit $rc: $(cat "$T/pub.out")"; fi
count="$("$REAL_GIT" -C "$R" rev-list --count "$(branch_sha "$R")")"
parents="$("$REAL_GIT" -C "$R" log -1 --format=%P estate-results)"
files="$("$REAL_GIT" -C "$R" ls-tree -r --name-only estate-results)"
if [ "$count" = 1 ] && [ -z "$parents" ] && [ "$files" = base-images.json ]; then ok "one orphan commit holding only base-images.json (position 7)"
else bad "commit shape: $count commit(s), parents '$parents', files '$files'"; fi
if "$REAL_GIT" -C "$R" show estate-results:base-images.json | cmp -s - "$T/good.json"; then ok "the branch file is the document, byte for byte"; else bad "branch file differs from the document"; fi
if ! grep -qF -e "$TOKEN" -e "$(printf 'x-access-token:%s' "$TOKEN" | base64 -w0)" -e x-access-token "$T/argv.log" && [ -s "$T/argv.log" ]; then ok "the token (raw or base64) is in no git argv"
else bad "the token reached a git argv, or no argv was recorded"; fi
if ! grep -qF "$TOKEN" "$T/pub.out"; then ok "the token is not in the script's output"; else bad "the token is in the output"; fi

mkdoc "$T/newer.json" 2026-11-30T07:00:00Z
publish "$R" "$T/newer.json"
if [ "$rc" = 0 ] && [ "$("$REAL_GIT" -C "$R" rev-list --count estate-results)" = 1 ] && [ "$("$REAL_GIT" -C "$R" show estate-results:base-images.json | jq -r .generatedAt)" = 2026-11-30T07:00:00Z ]; then
  ok "a newer document replaces the single orphan commit (no history grows)"
else bad "newer publish: exit $rc"; fi
before="$(branch_sha "$R")"
mkdoc "$T/older.json" 2026-11-16T07:00:00Z
publish "$R" "$T/older.json"
if [ "$rc" = 0 ] && [ "$(branch_sha "$R")" = "$before" ] && grep -q 'stale, not published' "$T/pub.out"; then ok "refuses to overwrite a newer branch document (stale, exit 0, branch untouched)"
else bad "older document: exit $rc, branch moved: $([ "$(branch_sha "$R")" = "$before" ] && echo no || echo yes)"; fi

echo "test-publish-base-images: a racing first publisher"
R2="$T/race.git"; bare "$R2"
W="$T/winner"; "$REAL_GIT" init -q "$W"; mkdoc "$W/base-images.json" 2026-11-22T07:00:00Z
"$REAL_GIT" -C "$W" add base-images.json; "$REAL_GIT" -C "$W" commit -q -m winner
winner_sha="$("$REAL_GIT" -C "$W" rev-parse HEAD)"
publish "$R2" "$T/good.json" SHIM_RACE_FROM="$W" SHIM_RACE_TO="$R2"
if [ "$rc" = 1 ] && [ "$(branch_sha "$R2")" = "$winner_sha" ]; then ok "the lease expects absence: a branch that appears first wins, this publish loses (exit 1)"
else bad "race: exit $rc, branch $(branch_sha "$R2") expected $winner_sha"; fi

echo "test-publish-base-images: the sweep wrapper"
cat >"$T/fake-check.sh" <<'FAKE'
#!/usr/bin/env bash
# Stands in for check-base-images.sh: FAKE_RC is its exit, FAKE_WRITE=1 makes it write the
# document it was asked for. It logs its argv so the test can see what the wrapper passed.
printf '%s\n' "$@" >"$FAKE_ARGV"
out=""; while [ $# -gt 0 ]; do [ "$1" = --json-out ] && out="$2"; shift; done
if [ "${FAKE_WRITE:-}" = 1 ]; then echo '{"schema":1}' >"$out"; fi
exit "${FAKE_RC:-0}"
FAKE
chmod +x "$T/fake-check.sh"
sweep() { # rc write [precreate-stale]
  SWEEP_OUT="$T/sweep.output"; : >"$SWEEP_OUT"
  mkdir -p "$RUNNER_TEMP/out"; rm -f "$RUNNER_TEMP/out/base-images.json"
  [ -z "${3:-}" ] || echo stale >"$RUNNER_TEMP/out/base-images.json"
  rc=0; env BASE_IMAGES_CHECK="$T/fake-check.sh" FAKE_RC="$1" FAKE_WRITE="$2" FAKE_ARGV="$T/fake.argv" GITHUB_OUTPUT="$SWEEP_OUT" "$SWEEP" >/dev/null 2>&1 || rc=$?
}
sweep 1 1
if [ "$rc" = 1 ] && grep -qx 'published=true' "$SWEEP_OUT"; then ok "exit 1 with a document: published=true, still exits 1 (a week with findings still publishes)"; else bad "exit 1 with doc: rc $rc, output '$(cat "$SWEEP_OUT")'"; fi
sweep 0 1
if [ "$rc" = 0 ] && grep -qx 'published=true' "$SWEEP_OUT"; then ok "exit 0 with a document: published=true, exits 0"; else bad "exit 0 with doc: rc $rc"; fi
sweep 2 0
if [ "$rc" = 2 ] && [ ! -s "$SWEEP_OUT" ]; then ok "exit 2 with no file: no output, exits 2"; else bad "exit 2: rc $rc, output '$(cat "$SWEEP_OUT")'"; fi
sweep 2 0 stale
if [ "$rc" = 2 ] && [ ! -s "$SWEEP_OUT" ] && [ ! -e "$RUNNER_TEMP/out/base-images.json" ]; then ok "a stale file from an earlier step is never published after exit 2"; else bad "stale file: rc $rc, output '$(cat "$SWEEP_OUT")'"; fi
sweep 2 1
if [ "$rc" = 2 ] && [ ! -s "$SWEEP_OUT" ]; then ok "exit 2 is never published even if a file appeared"; else bad "exit 2 with file: rc $rc, output '$(cat "$SWEEP_OUT")'"; fi
sweep 0 1
if grep -qx -e --public-only "$T/fake.argv" && grep -qx -e --json-out "$T/fake.argv" && grep -qx -e --estate "$T/fake.argv"; then ok "the wrapper runs the estate sweep with --json-out and --public-only"; else bad "wrapper argv: $(tr '\n' ' ' <"$T/fake.argv")"; fi

echo "test-publish-base-images: base-images.yml structure"
# The workflow without its comment lines: prose that names `always()` or `contents: write`
# must not satisfy or break an assertion about the code.
CODE="$T/workflow-code.yml"; grep -vE '^[[:space:]]*#' "$WORKFLOW" >"$CODE"
# A job's block: from "  <job>:" to the next two-space key.
job() { awk -v j="$1" '$0 ~ "^  " j ":" {p=1; print; next} p && /^  [a-z]/ {p=0} p' "$CODE"; }
step() { awk -v n="$1" '$0 ~ "- name: " n {p=1; print; next} p && /^      - / {p=0} p' "$CODE"; }
sweepjob="$(job sweep)"; pubjob="$(job publish)"
if step 'Prove the check can fail' | grep -q 'run: make base-images-test'; then ok "the self-test step runs make base-images-test"; else bad "self-test step does not run make base-images-test"; fi
if grep -q '^permissions:' "$CODE" && awk '/^permissions:/{getline; print}' "$CODE" | grep -qx '  contents: read' && ! grep -q 'permissions:' <<<"$sweepjob"; then ok "the sweep job stays contents: read (top-level block only)"; else bad "sweep job permissions changed"; fi
if [ "$(grep -c 'contents: write' "$CODE")" = 1 ] && grep -q 'contents: write' <<<"$pubjob"; then ok "only the publish job has contents: write"; else bad "contents: write is not exclusive to the publish job"; fi
gate="github.event_name != 'pull_request' && github.ref == 'refs/heads/main'"
upload="$(step 'Upload')"
if grep -q '!cancelled()' <<<"$upload" && grep -q "steps.sweep.outputs.published == 'true'" <<<"$upload" && grep -qF "$gate" <<<"$upload"; then ok "the upload step runs on !cancelled(), the published output and the event/ref gate"; else bad "upload step if: is missing a part"; fi
if grep -q 'retention-days: 1' <<<"$upload" && grep -q 'base-images.json' <<<"$upload"; then ok "the upload carries one file with retention-days 1"; else bad "upload retention/path"; fi
pubif="$(grep -m1 '^    if:' <<<"$pubjob")"
if grep -q '!cancelled()' <<<"$pubif" && grep -q "needs.sweep.outputs.published == 'true'" <<<"$pubif" && grep -qF "$gate" <<<"$pubif"; then ok "the publish job's if: has !cancelled(), the published output and the gate"; else bad "publish if: '$pubif'"; fi
if ! grep -q 'always()' "$CODE"; then ok "no always(): a cancelled run publishes nothing"; else bad "always() is in the workflow"; fi
if grep -A3 '^    concurrency:' <<<"$pubjob" | grep -q 'group: base-images-publish' && grep -A3 '^    concurrency:' <<<"$pubjob" | grep -q 'cancel-in-progress: false'; then ok "the publish job's concurrency group is base-images-publish, cancel-in-progress false"; else bad "publish concurrency block"; fi
if grep -q 'persist-credentials: false' <<<"$pubjob"; then ok "the publish checkout does not persist credentials"; else bad "publish checkout persists credentials"; fi
if ! grep -qF '${{ github.event.' "$CODE"; then ok "no event field is interpolated into the workflow"; else bad "a github.event field is interpolated"; fi
for p in Makefile scripts/base-images-sweep.sh scripts/publish-base-images.sh 'scripts/test/\*\*'; do
  if [ "$(grep -c -- "- '$p'" "$CODE")" -ge 2 ]; then ok "paths: lists $p for pull_request and push"; else bad "paths: missing $p"; fi
done
# backup-test.sh puts all of scripts/test/mock-bin on PATH; a gh or jq there would shadow the
# real one. The new shims live beside it, and this directory must stay as it was.
if [ "$(ls "$HERE/mock-bin" | tr '\n' ' ')" = "docker tailscale " ]; then ok "scripts/test/mock-bin holds only docker and tailscale"; else bad "scripts/test/mock-bin changed: $(ls "$HERE/mock-bin" | tr '\n' ' ')"; fi

if [ "$fails" -gt 0 ]; then echo "test-publish-base-images: $fails case(s) failed" >&2; exit 1; fi
echo "test-publish-base-images: passed"
