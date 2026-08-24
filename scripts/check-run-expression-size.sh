#!/usr/bin/env bash
# check-run-expression-size.sh — how close is a workflow's largest `run:` block to
# GitHub's hard expression cap? (SERV-136)
#
# THE FAILURE THIS EXISTS TO NAME. A `run:` block is ONE expression to GitHub, and
# an expression may not exceed 21,000 characters. Cross it and EVERY run of that
# workflow dies at load time, before a single job is created:
#
#   Invalid workflow file: .github/workflows/pr-review-reusable.yml#L1
#   (Line: 385, Col: 14): Exceeded max expression length 21000
#
# Three things make that message near-useless on its own:
#
#   * It names the line of the `run:` KEY, not the line you edited. In SERV-136
#     the edit was 190 lines further down.
#   * The run is named after the workflow FILE PATH rather than the workflow, has
#     zero jobs, and no log — `gh run view --log` returns "log not found".
#   * SHELL COMMENTS COUNT. A change that adds only `#` lines can break CI, which
#     is exactly the shape nobody suspects. SERV-136 spent three pushes bisecting
#     a comment-only diff before reading the error off the web UI.
#
# And nothing local catches it: actionlint, PyYAML and the SchemaStore workflow
# schema all accept the file. That is the whole reason this script exists.
#
# THE CHEAP FIX WHEN IT TRIPS: move prose OUT of the `run:` block to a YAML
# comment above the step. Those are not part of the expression and cost nothing.
# The block keeps the code; the reasoning lives immediately above it.
#
# Usage:
#   scripts/check-run-expression-size.sh [file...]     # defaults to .github/workflows/*.yml
#
# Exit codes:
#   0  every run block is under the cap
#   1  at least one is at or over it
#   2  missing dependency

set -euo pipefail

command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 not found in PATH" >&2; exit 2; }
python3 -c 'import yaml' 2>/dev/null || {
  echo "ERROR: the python3 'yaml' module is not available." >&2
  echo "  pip install --user pyyaml   (or run this where ansible's deps are present)" >&2
  exit 2
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd)"

if [ $# -gt 0 ]; then
  FILES=("$@")
else
  # No nullglob assumption: if the glob matches nothing python reports it.
  mapfile -t FILES < <(find "$REPO_ROOT/.github/workflows" -maxdepth 1 -name '*.yml' -o -maxdepth 1 -name '*.yaml' 2>/dev/null | sort)
fi

[ "${#FILES[@]}" -gt 0 ] || { echo "No workflow files found."; exit 0; }

python3 - "${FILES[@]}" <<'PY'
import sys, yaml

CAP = 21000
# Warn well before the cliff: the point is to notice while there is still room to
# add a sentence, not to find out from a red workflow that loads no jobs.
WARN_AT = 0.85

worst_rc = 0
rows = []

for path in sys.argv[1:]:
    try:
        with open(path) as fh:
            doc = yaml.safe_load(fh)
    except Exception as exc:                       # a file this cannot parse is not
        print(f"  skip  {path}: {exc}")            # this script's problem to report
        continue
    if not isinstance(doc, dict):
        continue
    for job_name, job in (doc.get("jobs") or {}).items():
        if not isinstance(job, dict):
            continue
        for step in (job.get("steps") or []):
            if not isinstance(step, dict):
                continue
            run = step.get("run")
            if not isinstance(run, str):
                continue
            rows.append((len(run), path, job_name, step.get("name", "<unnamed>")))

rows.sort(reverse=True)

if not rows:
    print("No `run:` blocks found.")
    sys.exit(0)

print(f"Largest `run:` blocks (cap {CAP}):\n")
for size, path, job, name in rows[:10]:
    pct = size / CAP
    if size >= CAP:
        mark, worst_rc = "OVER ", 1
    elif pct >= WARN_AT:
        mark = "TIGHT"
    else:
        mark = "ok   "
    short = path.split("/")[-1]
    print(f"  {mark} {size:6d}  {CAP - size:+6d} headroom  {short}  {job}/{name}")

if worst_rc:
    print(f"\nAt least one `run:` block is at or over the {CAP}-character cap.")
    print("GitHub will refuse to load that workflow — every run fails before any job starts.")
    print("Move prose out of the block into a YAML comment above the step; those are free.")
else:
    tight = [r for r in rows if r[0] / CAP >= WARN_AT]
    if tight:
        print(f"\n{len(tight)} block(s) above {int(WARN_AT*100)}% of the cap. Prefer YAML comments")
        print("above the step over shell comments inside it — only the latter count.")

sys.exit(worst_rc)
PY
