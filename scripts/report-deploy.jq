# The POST /v1/deployments body for `report-deploy` (SWY-191).
#
# Kept in its own file rather than inlined in report.sh so that
# `server/test/lib/report-deploy-payload.test.ts` can run THIS filter and parse
# what it emits with the shared `CreateDeployment` zod schema. An assertion that
# re-implemented the shape in the test would prove nothing about the action
# (CLAUDE.md's known-answer rule for wire formats); running the real artifact
# against the real contract is what makes a drift on either side fail loudly.
#
# ── Absent, never null ─────────────────────────────────────────────────────
#
# Every optional field is OMITTED when its input is blank.
#
# For MOST of `CreateDeployment` omitted and null are interchangeable, so the
# reason is editorial: the body should stay a description of what the caller
# actually knew. A report with no gate is a report that did not run one, and
# `"gate_passed": null` on the wire invites the reader to believe a gate was
# measured and came back empty. Same rule the UI follows when it omits a chip
# rather than zeroing it.
#
# For two fields it is load-bearing rather than editorial. `deployed_at` and
# `observed_at` are `Iso8601.optional()` in shared/src/schemas/delivery.ts —
# optional but NOT nullable — so an explicit null there is a 400, not an accepted
# absence. Anyone relaxing this rule has to keep those two omitted.
#
# ── `source` is hard-coded, and is not an input ────────────────────────────
#
# This action can only ever REPORT. Writing `observed` needs `deployments:observe`,
# which the CI token deliberately does not hold: the matrix's
# `claimed_not_confirmed` state is only falsifiable while confirming is strictly
# harder than claiming (server/src/routes/delivery.ts:21-27). Making the source
# an input would put that one keystroke away.

def present: . != null and . != "";
def opt($k): if present then { ($k): . } else {} end;

# The numeric fields arrive as strings because every composite-action input is a
# string. `tonumber` on a non-numeric value is a hard jq error, which is what we
# want: a typo'd `gate-passed: "3/4"` should fail the step loudly rather than
# silently dropping the gate and rendering "No gate" on a gate that did run.
def optnum($k): if present then { ($k): tonumber } else {} end;

# Ticket keys accept either a JSON array (what release-facts.ts emits) or a
# comma/whitespace-separated list (what a human wiring this by hand will type).
# Both are common enough that rejecting either would just move the parsing into
# every caller.
def ticket_keys:
  if present | not then {}
  elif sub("^[[:space:]]+"; "") | startswith("[") then { ticket_keys: fromjson }
  else
    { ticket_keys: ([splits("[,[:space:]]+")] | map(select(length > 0))) }
  end;

{
  service: $service,
  environment: $environment,
  source: "reported",
  status: $status,
}
+ ($version       | opt("version"))
+ ($digest        | opt("digest"))
+ ($sha           | opt("sha"))
+ ($deployed_at   | opt("deployed_at"))
+ ($deployed_by   | opt("deployed_by"))
+ ($deployed_by_login | opt("deployed_by_login"))
+ ($source_ref    | opt("source_ref"))
+ ($run_url       | opt("run_url"))
+ ($gate_run_url  | opt("gate_run_url"))
+ ($gate_passed   | optnum("gate_passed"))
+ ($gate_total    | optnum("gate_total"))
+ ($commit_count  | optnum("commit_count"))
+ ($note          | opt("note"))
+ ($ticket_keys   | ticket_keys)
