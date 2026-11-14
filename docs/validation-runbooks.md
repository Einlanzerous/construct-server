# Validating a change: per-check notes

Moved out of the root `CLAUDE.md` (SERV-317). The root file lists the commands; this
file says when each is needed and what its failure modes are. The `promote-dispatch-check`
runbook lives in `docs/delivery-pipeline.md`, and the lint gate's fail-open design in
`docs/lint-gate.md`.

There is no test suite — this repo is configuration, so validation is mostly
"does the thing it configures still come up".

`ansible-lint` runs in CI on `ansible/**`; run it locally before pushing.
`make workflow-size` after editing any GitHub workflow (SERV-136). A `run:` block
is ONE expression and GitHub caps an expression at 21,000 characters — over it,
the workflow does not load at all: every run fails before a job exists, named
after the file path, with no log, and the error points at the `run:` key rather
than at your edit. **Shell comments inside the block count**, so a comment-only
change can break CI, and `actionlint` accepts the file either way. Prose belongs
in a YAML comment *above* the step, which is free.
`make base-images-check dir=~/projects` after editing any Dockerfile in any estate repo,
and `make base-images-check` to ask what is merged (SERV-170). `make base-images-test`
proves the check can still fail — it fails closed, so unlike the lint gate a broken
check and a clean estate do not look alike, but the fixture run is still what shows the
EOL and floating verdicts actually fire. An `UNMAPPED` row is fixed by adding the
product to `PRODUCT_MAP`, never by an exemption.
`docker compose config` catches compose syntax and interpolation errors.
The two Go modules are the only real test suites here. After touching either,
`docker build --build-context cfaccess=./pkg/cfaccess --target test -f
services/cf-access-guard/Dockerfile services/cf-access-guard` runs **both**
through the pinned toolchain — the same thing CI does, so there is still exactly
one compiler pin in the repo. `cd pkg/cfaccess && go test ./...` is the fast
local loop; regenerate the shared vectors with `-run TestUpdateVectors -update`.
`gh workflow run verify.yml -f ticket=<key>` after touching the verifier
(SERV-80) — and against a ticket whose answer you already know, because a
verifier is only worth something once you have seen it say `not_met`. Its check
goes green on a `not_met` verdict by design, so "it passed" and "it found
nothing" look identical from the checks list; read the verdict, not the colour.
`./scripts/check-compose-drift.sh [service]` after any mount or env change.
`make health-check` (or `./scripts/assert-healthy.sh [service]`) to ask whether
the stack actually works, which `docker compose ps` does not answer — it fails
on anything unhealthy and lists every container with no healthcheck at all.
`deploy.yml` runs it as a post-deploy gate (SERV-102). `make dev-health-check`
is the dev project's copy, run by `deploy-dev.yml`.
`make assert-tokens` / `make dev-assert-tokens` after anything that changes the
rendered environment — a vault edit, a `signet sync`, a rotation. It asks whether the
switchyard API tokens in the resolved compose config carry a shape switchyard will
accept, and **both tiers now gate their deploy on it** (SERV-118 for dev, SERV-124 for
prod), ahead of any pull or recreate. Malformed is not a degraded state: switchyard
refuses to boot on one (SWY-295), and `ensureBootstrapToken` is additive, so correcting
the variable afterwards adds a second dead row instead of repairing the first — the
last good copy lives in the running container's environment and dies with the recreate.
Stopping the deploy before that recreate is the recovery path, not just the alarm.
It **fails closed**: the pattern is a shell copy of switchyard's `API_TOKEN_RE_SOURCE`,
so if switchyard ever widens the alphabet or the length, a valid new token blocks the
prod deploy until `scripts/assert-token-shapes.sh` follows. Accepted deliberately;
SWY-303 removes the copy. Being Signet-managed is **not** a substitute — `signet render
--check` compares key sets, not values, so a vault seeded from a stale file renders the
stale value and reports success.
`make assert-env-keys` / `make dev-assert-env-keys` after anything that changes the
rendered environment's **key set** — a `signet target add-key`, a retired secret, a
manifest edit (SERV-173). It asks whether every key in `required-env-keys.txt` reaches
the deployed `.env` with a value, which is the question `assert-tokens` does not ask
and compose's `:-` defaults make unanswerable from anywhere else. Both deploys gate on
it, before any pull. `vault=1` asks the vault instead of the deployed file, for the
interval between a `signet sync` and the deploy that renders it — the same ordering
`promote-dispatch-check` documents. It also names, as a note, every delivered key the
manifest does not list: those are unprotected, not wrong, and the note is the prompt to
list the ones the stack reads and retire the rest.
`make env-ownership-check` / `make dev-env-ownership-check` after changing what the
vault *delivers* — a `signet target add-key`, an `import`, a re-seeded render target.
It is the ownership question, not the value question `assert-tokens` asks: whether the
vault claims a key `versions.env` owns, or writes a file something else also writes
(SERV-94). Both conditions held on the prod project for a week or two and neither was visible
from anywhere — the pins because `render-env.sh` strips them, the file target because a
losing writer leaves no trace. It reads target metadata only and never a value.
Host-side, and **not a deploy gate**: while the strip is in the path the hazard is
latent, and a red prod deploy is the wrong way to learn that a vault edit was careless.

`make chronicle-upstream-check` after minting or rotating `CHRONICLE_SWITCHYARD_TOKEN`,
and after any deploy that was supposed to deliver it (SERV-185). It asks Switchyard and
Amber the two questions Chronicle's resolvers ask, because **the failure mode of these
two credentials is silence**: without them every reference Chronicle renders answers
`unconfigured`, which is a *true* answer rather than an error, so nothing else in the
stack reports it. `vault=1` asks the vault instead of the deployed `.env`, the same
ordering `promote-dispatch-check` documents above and for the same reason.
Host-side and **not a deploy gate** — it needs both containers up, and a deploy that
recreated chronicle before switchyard would fail it for a reason that is not a
credential problem. It proves the credentials are ACCEPTED, and (SERV-227) that the
Switchyard token's grant is **create-only**: it sends a well-formed create naming a
withheld field against a project key that does not exist, which Switchyard refuses
before any lookup with `create_only_field` for a read-plus-create token, answers 404
for a wider one and the scope 403 for a read-only one — nothing is written in any of
the three. That probe exists only because `tickets:create` (SWY-464) put a refusal
ahead of the write; before it there was no safe one. The scope list is still asserted
where it is minted — `mint-chronicle-token.sh` reads the granted scopes back out of the
mint response and refuses to hand over anything that is not exactly `tickets:read`
plus `tickets:create`. **Note the compose pair is atomic**: `CHRONICLE_SWITCHYARD_URL` is
derived from the token's presence (`${CHRONICLE_SWITCHYARD_TOKEN:+...}`), so an
undelivered token leaves both halves empty and chronicle boots unconfigured rather than
refusing to start on a half-configured pair.
`make lint-gate` runs this repo's format/lint checks the way the pre-push hook does,
and `make lint-gate-test` proves the hook still BLOCKS (SERV-58). The second one is the
one that matters: the gate fails open on purpose, so a gate that has quietly stopped
working is indistinguishable from a clean tree — both are green. Re-run
`make lint-gate-install` after pulling a change to `scripts/lint-gate.sh`; the installed
copy is a copy, and `make lint-gate-status` is what surfaces the drift.
`make probe-status` after touching the prober or its role — it shows the timer
*and* the last oneshot run, which is the pair that matters: the failure mode is
the service landing in `failed` while the timer keeps cheerfully firing it.
`make probe-delivery` runs one probe now, using the deployed credential rather
than one you exported by hand.
`make runner-node-path` after a reboot, after registering a runner, or after
`fnm default` moves — it prints which node every self-hosted runner resolves and
whether the running listener has loaded the file it sits beside (SERV-135). `fix=1`
rewrites the `.path` files; `restart=1` bounces only idle runners whose live PATH
is stale, and skips any with a job in flight rather than killing it.
`make versions` / `make dev-versions` to answer *what is actually running* — the
image ref, the resolved digest, and the commit each image was built from. **Read
the revision column, not the digest**: the publish workflow builds the same source
twice seconds apart, so two digests from one commit is normal and comparing them
invents drift that is not there (SERV-88).
`make dev-edge-auth-check` after touching the dev edge (`config/traefik-dev/`,
the dev guard's AUD map, the dev routers). It skips itself when the dev edge is not
deployed, which is the honest answer — there is no origin to interrogate then;
`config_only=1` checks the committed config from a checkout and names which dev
Access applications still have no AUD recorded.
For edge or auth changes, the only real check is a request through the public
path — internal container-to-container success proves nothing about Access.
`make edge-auth-check` now makes that request itself (SERV-171); after editing it,
`make edge-auth-test` is the one that shows it still goes red.
