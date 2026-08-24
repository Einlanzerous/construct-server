module github.com/Einlanzerous/construct-server/pkg/cfaccess

// At or below every consumer's own go directive (lyceum 1.25, chronicle 1.26,
// cf-access-guard 1.23 — equal, not above). A shared module's go line is a floor
// on everyone who imports it, so raising it to reach a convenience —
// slog.DiscardHandler, say — spends a consumer's toolchain choice on this
// module's tidiness. Raise it only for something that cannot be written without
// it, and check the consumers' directives first rather than their base images:
// the guard builds on golang:1.25-alpine and still declares 1.23.
go 1.23
