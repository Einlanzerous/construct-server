# cf-access-guard (SERV-106) — built here, on the box, rather than pulled.
#
# This is the one first-party image the stack builds instead of pinning to a
# published tag, and that is deliberate: it has no dependencies to resolve, no
# release cadence of its own, and its source is a few hundred lines that live
# beside the compose file they protect. Giving it a repo, a publish workflow and
# a versions.env pin would put four moving parts between an edit and the guard
# that edit describes. `deploy.yml` builds it explicitly, so a source change is
# picked up on the next deploy the same way a config change is.
FROM golang:1.25-alpine AS build
WORKDIR /src

# No go.sum and nothing to download: the guard is stdlib-only, which is what
# makes this build hermetic. Anything that adds a dependency also adds a network
# fetch to every deploy — reconsider it rather than adding one quietly.
COPY go.mod ./
COPY *.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/cf-access-guard .

# FROM scratch: nothing in the image but the binary and a CA bundle. There is no
# shell to exec into and no package manager, which is the right posture for a
# container that sits in front of every tunneled app — and the reason the
# healthcheck runs the binary itself with -healthcheck rather than curl.
FROM scratch
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=build /out/cf-access-guard /cf-access-guard

# Unprivileged. :4020 is above 1024, so nothing here needs root.
USER 65534:65534
EXPOSE 4020
ENTRYPOINT ["/cf-access-guard"]
