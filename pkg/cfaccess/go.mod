module github.com/Einlanzerous/construct-server/pkg/cfaccess

// Deliberately BELOW every consumer's own go directive (lyceum 1.25, chronicle
// 1.26, cf-access-guard 1.25). A shared module's go line is a floor on everyone
// who imports it, so raising it to reach a convenience — slog.DiscardHandler,
// say — spends a consumer's toolchain choice on this module's tidiness. Raise it
// only for something that cannot be written without it.
go 1.23
