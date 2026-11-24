// What `--help` prints. The rules below are owned here and in docs/base-images.md; a
// consumer reads the JSON document and does not copy them. The tests pin the digest wording
// across this text, the docs and the workflow's explanation.
export const USAGE = `check.ts — Fail on a base image that is past end-of-life or floating (SERV-170).

Every first-party service builds FROM a public base image, and nothing used to ask
whether that image was still receiving security updates. A survey on 2026-09-05 found
four repos on alpine:3.20 (EOL 2026-04-01), two on node:20 (EOL 2026-04-30), one Go
builder on 1.24 and another on 1.25 (both out of Go's two-release window), three nginx
runtimes on 1.27 (EOL 2025-06-24), and two tags that named no version at all. None of
it was visible from anywhere: an EOL base image builds, passes CI, deploys and reports
healthy — the only difference is that \`apk add\` and \`apt-get install\` resolve against a
branch nobody patches any more. This program is what makes that state loud.

TWO RULES, checked against endoflife.date rather than a table kept here:

  1. NOT PAST END-OF-LIFE. The tag's version is mapped onto a release cycle of the
     product behind the image (alpine 3.23, nodejs 24, go 1.26, ...) and that cycle's
     \`isEol\` must be false. A cycle whose EOL is inside the warning window is reported
     but does not fail — the point is to see it coming.

  2. NOT FLOATING. The tag must name the version to at least the product's cycle
     precision: \`alpine:3.23\` and \`node:24-alpine\` are pinned, \`alpine:3\`, \`nginx:alpine\`
     and \`node:latest\` are not. A floating tag is an image that changes underneath a
     rebuild with nothing in the diff to show it — the opposite of what versions.env
     exists to give this estate — and it cannot be evaluated by rule 1 either, since it
     names no cycle. A digest (\`@sha256:…\`) satisfies rule 2 on its own: it is the pin.
     It does NOT satisfy rule 1. A digest-pinned ref whose tag names no cycle
     (\`alpine@sha256:…\`) is UNKNOWN, exit 1: the pin is real but nothing says whether
     the image behind it still gets security updates, and "could not tell" is a
     finding here. A digest on a tag that does name a cycle (\`alpine:3.23@sha256:…\`)
     is checked like any other ref.

The policy data is endoflife.date's v1 API and NOT a table in this program. A table is
exactly the thing that goes stale — that is what happened to the Dockerfiles. The cost
is a network dependency: when the API cannot be reached the program exits 2, never 0,
because "could not check" must not read as "checked and fine". BASE_IMAGE_POLICY_DIR
points at cached product JSON for offline runs and the tests.

WHAT IT REFUSES RATHER THAN GUESSES (exit 1, same as a finding):
  - an image repo with no entry in PRODUCT_MAP (src/ref.ts) — add the mapping, do not skip it;
  - a tag whose version is not a cycle endoflife.date knows;
  - a digest-pinned ref whose tag names no cycle (UNKNOWN: pinned, but rule 1 cannot run);
  - a \`FROM \${VAR}\` whose ARG default is not declared earlier in the same file;
  - in --estate mode, a repo whose tree could not be read (token lacks access).

USAGE
  check.ts <Dockerfile>...           check the named files
  check.ts --dir <path>              every Dockerfile under a tree (~/projects)
  check.ts --estate [compose.yml]    every Dockerfile on the default branch of
                                     every first-party repo, read via \`gh api\`.
                                     Repos are derived from the compose file's
                                     ghcr.io images plus EXTRA_REPOS.
  check.ts --self-test               prove the program can FAIL: runs its test suite

  --json                 print one JSON document (schema 1) to stdout; the human table, the
                         footer and gh's noise go to stderr
  --json-out FILE        write the same document to FILE (the human output stays on stdout)
  --public-only          --estate only: publish only repos the PRIVACY_GH_TOKEN can see as
                         public (see MACHINE-READABLE OUTPUT)
  --redact               --estate only: print detail only for public repos (see REDACTION).
                         Implied by GITHUB_ACTIONS, CI or GITHUB_STEP_SUMMARY being set to
                         anything; there is no flag to turn it off, unset those instead.

ENV
  BASE_IMAGE_WARN_DAYS   warn when EOL is within this many days (default 90)
  BASE_IMAGE_POLICY_DIR  read <product>.json from here instead of the API
  BASE_IMAGE_API         the API's base URL (default https://endoflife.date/api/v1/products)
  BASE_IMAGE_TODAY       YYYY-MM-DD, overrides the clock (tests)
  GH_TOKEN / GITHUB_TOKEN  what \`gh api\` authenticates with in --estate mode
  PRIVACY_GH_TOKEN       --public-only and --redact: the token that decides which repos are public. It must
                         be one that cannot read private repos (a 404 is the answer for them);
                         there is no fallback to GH_TOKEN, which can read them

EXIT CODES (the PROCESS exit; --json and --json-out never change it)
  0  every base image is a pinned, supported cycle
  1  at least one finding (EOL, floating, or unevaluable)
  2  usage error, missing dependency, or the policy source was unreachable. No document is
     printed and any stale --json-out file is removed: an exit-2 run never leaves one behind.
     An internal error is exit 2 as well, never 1.

MACHINE-READABLE OUTPUT (SERV-294). The rule stays owned here and in docs/base-images.md;
a consumer reads the document and does not copy the rule. Shape, null rules, the status
vocabulary and the stability promise are in docs/base-images.md. In short: one object per
FROM line in images[], \`status\` is one of OK SOON EOL FLOATING UNKNOWN UNMAPPED UNRESOLVED,
an undeterminable field is null (never "" or 0), and in --estate mode repos[] says per repo
whether it was read, partly read, unreadable, or has no Dockerfile. A repo or file that
could not be read never becomes a row.

--public-only is the privacy filter, run here so that no file or artifact ever holds private
data. A repo is published only when \`gh api repos/<owner>/<repo> --jq .private\` made with
PRIVACY_GH_TOKEN exits 0 and prints exactly \`false\`. A 404 or \`true\` withholds it (counted in
summary.withheldRepos); any other answer withholds it and is itself a finding
(summary.visibilityUnreadable), because "could not tell" must be loud. Withheld repos are
still swept, so they still count toward the PROCESS exit and, outside CI, still appear in the
human log (see REDACTION). The document's summary and exit describe only what it publishes,
so \`exit: 0\` means the public view is clean and says nothing about the estate.

REDACTION (SERV-350). This repo is public, so a CI run log, its annotations and its step
summary are world-readable, and the sweep token can read private repos. Under redaction a
repo is shown in full only when the privacy lookup above (the same one --public-only uses,
same fail-closed rule) says public. A private repo, or one whose privacy could not be
determined, prints nothing about itself: no name, path, image or detail, in stdout, stderr,
annotations or the step summary. Only a count prints, e.g. "2 repo(s) withheld (private or
privacy unknown): 1 finding(s), 0 warning(s)". Findings in a withheld repo still count
toward the process exit, so the Monday alarm still goes red; to see what to fix, run it
locally (\`make base-images-check\`), where redaction is off. Redaction is on when --redact is
given (the workflow passes it) or when GITHUB_ACTIONS, CI or GITHUB_STEP_SUMMARY is set to
anything: an unrecognised CI that sets none of those is the only way to get detail, which
is why the explicit flag exists. Redaction also implies --public-only for the estate, so
--json and --json-out never carry a private repo into a log or an artifact. File and --dir
modes have no privacy lookup, so they refuse (exit 2) under redaction rather than print paths.

A guard that fails closed is only worth having if it is known to fail at all, so
\`--self-test\` runs the test suite, which builds a fixture policy and fixture Dockerfiles
and asserts that an EOL tag, a floating tag and an unmapped image each produce exit 1 while
a clean file produces exit 0, and that the privacy filter and the redaction withhold what
they must. The workflow runs it before the real check.
`;
