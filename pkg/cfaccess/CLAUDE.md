# pkg/cfaccess

The estate's one Cloudflare Access JWT verifier (SERV-131). Decision of record and the
drift history: `docs/cf-access-verifier.md`.

- Do not write a second verifier and do not copy this one into a service. Import it.
- Consumers `go get` it by tag (`pkg/cfaccess/vX.Y.Z`); the `tag-separator: "/"` in
  `release-please-config.json` is what makes that form resolvable.
- `services/cf-access-guard` is the exception: it tracks HEAD through a path `replace` and
  receives the module as a named Docker build context, never by widening the context to
  the deploy root (that root holds the rendered `.env`).
- Switchyard stays on `jose`. The cross-language check is `testdata/vectors.json`
  (spec `cfaccess-vectors/2`). Only this module's Go tests run it today; Switchyard,
  heitan and Chronicle are expected to vendor a pinned copy and run it (SERV-308/309/310).
  `class: protocol` vectors must hold in any verifier, `keypolicy` ones are
  estate hardening, and a legitimate difference goes in `expectBy`, not a skip.
- Tests: `go test ./...` here; regenerate vectors with `-run TestUpdateVectors -update`.
  The guard's `--target test` Docker build runs both Go modules (see root `CLAUDE.md`).
