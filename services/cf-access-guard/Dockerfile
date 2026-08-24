# cf-access-guard (SERV-106) — built here, on the box, rather than pulled.
#
# This is the one first-party image the stack builds instead of pinning to a
# published tag, and that is deliberate: it has no dependencies to resolve, no
# release cadence of its own, and its source is a few hundred lines that live
# beside the compose file they protect. Giving it a repo, a publish workflow and
# a versions.env pin would put four moving parts between an edit and the guard
# that edit describes. `deploy.yml` builds it explicitly, so a source change is
# picked up on the next deploy the same way a config change is.
#
# Digest-pinned for the same reason every third-party image in docker-compose.yml is
# (SERV-105): `golang:1.25-alpine` is a moving tag, and this image is rebuilt on every
# deploy — so without the pin the compiler behind the estate's auth gate can change
# with no diff anywhere. The tag is provenance, the digest is the pin.
FROM golang:1.25-alpine@sha256:1e0126852075c9c60731c8ba49088448b91f63e2aed97ca9d1a9791622a05946 AS build
# The repo layout is mirrored inside the image — the guard at
# services/cf-access-guard, the module at pkg/cfaccess — so the `../../pkg/cfaccess`
# replace in go.mod resolves to the same place here as in a checkout. Flattening it
# would work only by accident of how `..` resolves above /src.
WORKDIR /src/services/cf-access-guard

# Still no go.sum and still nothing to download. The guard now imports
# pkg/cfaccess (SERV-131), but through a path `replace` in its go.mod, and the
# module is itself stdlib-only — so the build stays HERMETIC, which is the
# property the paragraph below has always been about. A `require` on the
# published tag instead would put proxy.golang.org between every deploy and the
# service that decides whether requests to the estate are authenticated.
#
# pkg/cfaccess arrives as a named build context rather than by widening this
# build's context to the repo root. The deploy root holds the rendered .env, and
# making that a docker build context — even with a .dockerignore in front of it —
# is one editing mistake away from shipping every credential in the stack into an
# image layer. A second context is bounded by construction.
#
# Anything that adds a real dependency also adds a network fetch to every deploy;
# reconsider it rather than adding one quietly.
COPY --from=cfaccess . /src/pkg/cfaccess
COPY go.mod ./
COPY *.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/cf-access-guard .

# Tests live in a stage of their own, reached with `docker build --target test`.
# .github/workflows/cf-access-guard.yml is what runs it, and it does so through this
# Dockerfile rather than with its own `setup-go` so there is exactly ONE toolchain pin
# in the repo — CI cannot drift onto a different compiler than the one that builds the
# deployed binary. Nothing downstream depends on this stage, so an ordinary build (and
# therefore every deploy) skips it.
# Tests cover BOTH modules: the guard's own, and the shared verifier's — including
# the vectors Switchyard's TypeScript suite runs against jose. Running them here
# rather than only in the module's own job is what stops a guard change and a
# module change from being green separately and broken together.
FROM build AS test
RUN test -z "$(gofmt -l . ../../pkg/cfaccess)" || { echo "not gofmt-clean:"; gofmt -l . ../../pkg/cfaccess; exit 1; }
RUN go vet ./...
RUN go test ./...
RUN cd ../../pkg/cfaccess && go vet ./... && go test ./...

# FROM scratch: nothing in the image but the binary and a CA bundle. There is no
# shell to exec into and no package manager, which is the right posture for a
# container that sits in front of every tunneled app — and the reason the
# healthcheck runs the binary itself with -healthcheck rather than curl.
FROM scratch

# The commit this binary was built from, stamped so the deploy can tell whether the
# RUNNING container is current (SERV-109). Nothing else can answer that for this image:
# it carries no pin, and the image ID is useless as an identity because BuildKit
# re-exports the config on every build — three builds of identical source produce three
# IDs, measured. Comparing on the ID would therefore recreate the container that decides
# whether requests are authenticated on every single deploy.
#
# Deliberately the SAME label the rest of the estate is compared on (SERV-88), so
# `make versions cf-access-guard` reports a revision like every other first-party image.
#
# `unknown` when nothing passes it — a hand-build on the box, say. That is the loud
# direction: it will not match a real commit, so the deploy recreates the guard rather
# than assuming an unlabelled image is current.
ARG GUARD_REVISION=unknown
LABEL org.opencontainers.image.revision=$GUARD_REVISION

COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=build /out/cf-access-guard /cf-access-guard

# Unprivileged. :4020 is above 1024, so nothing here needs root.
USER 65534:65534
EXPOSE 4020
ENTRYPOINT ["/cf-access-guard"]
