module github.com/Einlanzerous/construct-server/services/cf-access-guard

go 1.23

// The shared Cloudflare Access verifier (SERV-131). Three hand-rolled copies of
// this code had already drifted into a panic (LYCM-122) before it was factored
// out; the guard was the copy that happened to be correct.
//
// The guard tracks the module at HEAD rather than at a tag, and it is the ONLY
// consumer that does. Two reasons. It lives in the same repo, so a tag would let
// the reference implementation and its own reference consumer disagree for as
// long as it took to cut one — and the guard is where a breaking change should
// be noticed, before Lyceum and Chronicle inherit it. And a path `replace` keeps
// the build HERMETIC: no network fetch on any deploy, a property this service's
// Dockerfile states outright and which is worth more here than anywhere else in
// the stack.
//
// The zero pseudo-version is what `go mod tidy` normalises a path replace to;
// there is no version to pin because the source is right there. A `replace` in a
// main module is ignored by anything importing it, and nothing imports the
// guard, so this cannot leak downstream.
require github.com/Einlanzerous/construct-server/pkg/cfaccess v0.0.0-00010101000000-000000000000

replace github.com/Einlanzerous/construct-server/pkg/cfaccess => ../../pkg/cfaccess
