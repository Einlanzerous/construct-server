package main

import (
	"regexp"
	"strings"
)

// Session kinds, decided from the transcript directory name alone. The
// directory is Claude Code's encoding of the working directory, so the kind is
// really "where did this session start".
const (
	KindInteractive = "interactive"
	KindRunner      = "runner"
	KindDispatch    = "dispatch"
)

// Kinds is the stable report order.
var Kinds = []string{KindInteractive, KindRunner, KindDispatch}

// classify mirrors the SERV-320 inspection script: CI runner checkouts live
// under ~/runners, dispatched agents either have "dispatch" in the directory
// or run in a drydock worktree, everything else is a person at a terminal.
func classify(dir string) string {
	switch {
	case strings.HasPrefix(dir, "-home-magos-runners-"):
		return KindRunner
	case strings.Contains(dir, "dispatch"), strings.HasPrefix(dir, "-home-magos--drydock-"):
		return KindDispatch
	default:
		return KindInteractive
	}
}

// Model families. Substring match so a new minor version (claude-opus-5-6)
// lands in the right row without a code change.
const (
	FamilyOpus   = "opus"
	FamilySonnet = "sonnet"
	FamilyHaiku  = "haiku"
	FamilyFable  = "fable"
	FamilyOther  = "other"
)

// Families is the stable report order.
var Families = []string{FamilyOpus, FamilyFable, FamilySonnet, FamilyHaiku, FamilyOther}

func family(model string) string {
	m := strings.ToLower(model)
	for _, f := range []string{FamilyOpus, FamilyFable, FamilySonnet, FamilyHaiku} {
		if strings.Contains(m, f) {
			return f
		}
	}
	return FamilyOther
}

// Operator phrases, matched case-insensitively as substrings. Curly
// apostrophes are folded to straight ones first, so "I don’t see" counts.
const (
	PhraseFileTicket = "file a ticket"
	PhraseDontSee    = "i don't see"
)

var apostrophes = strings.NewReplacer("’", "'", "‘", "'", "ʼ", "'")

func hasPhrase(text, phrase string) bool {
	return strings.Contains(strings.ToLower(apostrophes.Replace(text)), phrase)
}

var ghPRCreate = regexp.MustCompile(`\bgh\s+pr\s+create\b`)

// planTools are the Switchyard plan tools the audit counts.
var planTools = []string{"open_plan_draft", "submit_plan", "revise_plan", "get_plan", "get_plan_feedback"}

// switchyardTool returns the short tool name when name is a Switchyard MCP
// tool under either server prefix (mcp__switchyard__x, mcp__claude_ai_Switchyard__x).
func switchyardTool(name string) (string, bool) {
	if !strings.HasPrefix(name, "mcp__") || !strings.Contains(strings.ToLower(name), "switchyard") {
		return "", false
	}
	i := strings.LastIndex(name, "__")
	return name[i+2:], true
}

// safeLabel limits what may be printed from a transcript field to short
// identifier-shaped values, so a field that unexpectedly held prose is never
// echoed.
func safeLabel(s string) string {
	if s == "" {
		return ""
	}
	if len(s) > 48 {
		return "(redacted)"
	}
	for _, r := range s {
		ok := r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '_' || r == '-' || r == '.' || r == ':'
		if !ok {
			return "(redacted)"
		}
	}
	return s
}
