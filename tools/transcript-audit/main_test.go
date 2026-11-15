package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestClassify(t *testing.T) {
	for _, tc := range []struct{ dir, want string }{
		{"-home-magos-projects-switchyard", KindInteractive},
		{"-home-magos", KindInteractive},
		{"-home-magos-runners-catenary--work-catenary-catenary", KindRunner},
		{"-home-magos-dispatch-work-switchyard-SWY-205", KindDispatch},
		{"-home-magos--drydock-worktrees-chrn-66-plan", KindDispatch},
		{"-home-magos-projects-drydock", KindInteractive}, // a project named drydock is not a drydock worktree
		{"-home-magos-runners", KindInteractive},          // prefix needs the trailing dash
	} {
		if got := classify(tc.dir); got != tc.want {
			t.Errorf("classify(%q) = %q, want %q", tc.dir, got, tc.want)
		}
	}
}

func TestFamily(t *testing.T) {
	for in, want := range map[string]string{
		"claude-opus-5-5":   FamilyOpus,
		"claude-opus-9-9":   FamilyOpus,
		"claude-sonnet-5-5": FamilySonnet,
		"claude-fable-5-2":  FamilyFable,
		"CLAUDE-HAIKU-5-5":  FamilyHaiku,
		"gpt-x":             FamilyOther,
		"":                  FamilyOther,
	} {
		if got := family(in); got != want {
			t.Errorf("family(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestHasPhrase(t *testing.T) {
	for _, tc := range []struct {
		text, phrase string
		want         bool
	}{
		{"please File a Ticket for this", PhraseFileTicket, true},
		{"FILE A TICKET", PhraseFileTicket, true},
		{"file  a ticket", PhraseFileTicket, false}, // two spaces: no fuzzy matching
		{"file a new ticket", PhraseFileTicket, false},
		{"I don't see the PR", PhraseDontSee, true},
		{"i DON'T SEE a plan", PhraseDontSee, true},
		{"I don’t see it", PhraseDontSee, true}, // curly apostrophe
		{"I do not see it", PhraseDontSee, false},
		{"", PhraseDontSee, false},
	} {
		if got := hasPhrase(tc.text, tc.phrase); got != tc.want {
			t.Errorf("hasPhrase(%q, %q) = %v, want %v", tc.text, tc.phrase, got, tc.want)
		}
	}
}

func TestSwitchyardTool(t *testing.T) {
	for name, want := range map[string]string{
		"mcp__switchyard__get_plan":              "get_plan",
		"mcp__claude_ai_Switchyard__submit_plan": "submit_plan",
		"mcp__other__get_plan":                   "",
		"get_plan":                               "",
		"Bash":                                   "",
	} {
		got, ok := switchyardTool(name)
		if got != want || ok != (want != "") {
			t.Errorf("switchyardTool(%q) = %q,%v want %q", name, got, ok, want)
		}
	}
}

func TestSafeLabel(t *testing.T) {
	if got := safeLabel("production_deploy"); got != "production_deploy" {
		t.Errorf("identifier altered: %q", got)
	}
	for _, in := range []string{"has a space", strings.Repeat("a", 49), "semi;colon"} {
		if got := safeLabel(in); got != "(redacted)" {
			t.Errorf("safeLabel(%q) = %q, want (redacted)", in, got)
		}
	}
}

// ---- fixtures: small synthetic transcripts, written fresh for each test ----

type fx struct {
	root string
	t    *testing.T
}

func newFx(t *testing.T) *fx { return &fx{root: t.TempDir(), t: t} }

func (f *fx) write(rel string, lines ...string) {
	f.t.Helper()
	p := filepath.Join(f.root, filepath.FromSlash(rel))
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		f.t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(strings.Join(lines, "\n")+"\n"), 0o644); err != nil {
		f.t.Fatal(err)
	}
}

func asst(ts, sid, mid, model string, in, out, cr, cw int, side bool, blocks ...string) string {
	return fmt.Sprintf(`{"type":"assistant","timestamp":%q,"sessionId":%q,"isSidechain":%v,"message":{"id":%q,"model":%q,"usage":{"input_tokens":%d,"output_tokens":%d,"cache_read_input_tokens":%d,"cache_creation_input_tokens":%d},"content":[%s]}}`,
		ts, sid, side, mid, model, in, out, cr, cw, strings.Join(blocks, ","))
}

func toolUse(id, name, input string) string {
	return fmt.Sprintf(`{"type":"tool_use","id":%q,"name":%q,"input":%s}`, id, name, input)
}

func userText(ts, sid, uuid, text string, extra string) string {
	b, _ := json.Marshal(text)
	return fmt.Sprintf(`{"type":"user","timestamp":%q,"sessionId":%q,"uuid":%q%s,"message":{"content":%s}}`, ts, sid, uuid, extra, b)
}

func toolResult(ts, sid, uuid, id, text string, isErr bool) string {
	b, _ := json.Marshal(text)
	return fmt.Sprintf(`{"type":"user","timestamp":%q,"sessionId":%q,"uuid":%q,"message":{"content":[{"type":"tool_result","tool_use_id":%q,"is_error":%v,"content":%s}]}}`, ts, sid, uuid, id, isErr, b)
}

func scan(t *testing.T, f *fx, since, until string) *Stats {
	t.Helper()
	st, err := Scan(f.root, since, until)
	if err != nil {
		t.Fatal(err)
	}
	return st
}

const day = "2026-11-01T10:00:00.000Z"

func TestTokenAccounting(t *testing.T) {
	f := newFx(t)
	const dir = "-home-magos-projects-demo"
	f.write(dir+"/s1.jsonl",
		// Streamed message m1: two copies, the later one has the final output count.
		asst(day, "s1", "m1", "claude-opus-5-5", 10, 5, 100, 20, false),
		asst(day, "s1", "m1", "claude-opus-5-5", 10, 50, 100, 20, false),
		// Synthetic messages and messages with no id carry no usage.
		asst(day, "s1", "m2", "<synthetic>", 999, 999, 999, 999, false),
		asst(day, "s1", "", "claude-opus-5-5", 999, 999, 999, 999, false),
		// Outside the window.
		asst("2026-10-01T00:00:00Z", "s1", "m3", "claude-opus-5-5", 999, 999, 999, 999, false),
		asst("2026-11-03T00:00:00Z", "s1", "m4", "claude-opus-5-5", 999, 999, 999, 999, false),
		// Sidechain within the main file.
		asst(day, "s1", "m5", "claude-sonnet-5-5", 1, 2, 3, 4, true),
	)
	// Subagent file: same sessionId, same message id as a main message is a
	// different (side) message, not a duplicate.
	f.write(dir+"/s1/subagents/agent-a.jsonl",
		asst(day, "s1", "m1", "claude-haiku-5-5", 1, 1, 1, 1, false),
	)
	st := scan(t, f, "2026-11-01", "2026-11-02")
	r := st.Usage()
	if want := int64(180 + 10 + 4); r.Tokens.Total != want {
		t.Errorf("total = %d, want %d", r.Tokens.Total, want)
	}
	if r.Tokens.Main != 180 || r.Tokens.Subagent != 14 {
		t.Errorf("main/sub = %d/%d, want 180/14", r.Tokens.Main, r.Tokens.Subagent)
	}
	if r.Sessions != 1 || r.ByKind[KindInteractive].Turns != 3 {
		t.Errorf("sessions %d turns %d, want 1 and 3", r.Sessions, r.ByKind[KindInteractive].Turns)
	}
	if got := r.Families[FamilySonnet].Subagent; got != 10 {
		t.Errorf("sonnet subagent = %d, want 10", got)
	}
	if got := r.Families[FamilyHaiku].SubagentOfAll; got < 0.0206 || got > 0.0207 {
		t.Errorf("haiku subagent share of all = %v, want ~4/194", got)
	}
	if len(r.ByDir) != 1 || r.ByDir[0].Dir != dir || r.ByDir[0].Tokens != 194 {
		t.Errorf("by dir = %+v", r.ByDir)
	}
}

func TestSessionKindsAndWindowBounds(t *testing.T) {
	f := newFx(t)
	f.write("-home-magos-projects-a/i.jsonl", asst(day, "i", "m", "claude-opus-5-5", 1, 1, 0, 0, false))
	f.write("-home-magos-runners-a--work-a-a/r.jsonl", asst(day, "r", "m", "claude-opus-5-5", 1, 1, 0, 0, false))
	f.write("-home-magos-dispatch-work-x-1/d.jsonl", asst(day, "d", "m", "claude-opus-5-5", 1, 1, 0, 0, false))
	// since and until are both inclusive days.
	f.write("-home-magos-projects-b/edge.jsonl",
		asst("2026-11-01T00:00:00Z", "e1", "m", "claude-opus-5-5", 1, 1, 0, 0, false),
		asst("2026-11-01T23:59:59Z", "e2", "m", "claude-opus-5-5", 1, 1, 0, 0, false),
		asst("2026-11-02T00:00:00Z", "e3", "m", "claude-opus-5-5", 1, 1, 0, 0, false),
	)
	r := scan(t, f, "2026-11-01", "2026-11-01").Usage()
	if r.Sessions != 5 {
		t.Errorf("sessions = %d, want 5 (e3 is outside)", r.Sessions)
	}
	for k, want := range map[string]int{KindInteractive: 3, KindRunner: 1, KindDispatch: 1} {
		if got := r.ByKind[k].Sessions; got != want {
			t.Errorf("%s sessions = %d, want %d", k, got, want)
		}
	}
}

func TestSpawnsNamedModel(t *testing.T) {
	f := newFx(t)
	use := func(id, name, in string) string { return toolUse(id, name, in) }
	f.write("-home-magos-projects-a/s.jsonl",
		asst(day, "s", "m1", "claude-opus-5-5", 1, 1, 0, 0, false,
			use("t1", "Agent", `{"model":"sonnet","prompt":"SECRET-BRIEF"}`),
			use("t2", "Agent", `{"prompt":"x"}`),
			use("t3", "Task", `{"model":""}`),
			use("t4", "Agent", `{"model":7}`),
		),
		// The same tool_use streamed again must not count twice.
		asst(day, "s", "m1", "claude-opus-5-5", 1, 2, 0, 0, false, use("t1", "Agent", `{"model":"sonnet"}`)),
		asst(day, "s", "m2", "claude-opus-5-5", 1, 1, 0, 0, false, use("t5", "Agent", `{"model":"has spaces and prose"}`)),
	)
	r := scan(t, f, "2026-11-01", "2026-11-01").Usage()
	if r.Spawns.Total != 5 || r.Spawns.NamedModel != 2 || r.Spawns.NoModel != 3 {
		t.Errorf("spawns = %+v, want total 5, named 2, none 3", r.Spawns)
	}
	if r.Spawns.ByModel["sonnet"] != 1 || r.Spawns.ByModel["(redacted)"] != 1 {
		t.Errorf("by model = %v", r.Spawns.ByModel)
	}
}

func TestComplianceAndPrompts(t *testing.T) {
	f := newFx(t)
	bash := func(id, cmd string) string {
		b, _ := json.Marshal(map[string]string{"command": cmd})
		return toolUse(id, "Bash", string(b))
	}
	// Interactive, PR and attach.
	f.write("-home-magos-projects-a/ok.jsonl",
		asst(day, "ok", "m1", "claude-opus-5-5", 1, 1, 0, 0, false, bash("b1", "cd x && gh pr create --title t")),
		asst(day, "ok", "m2", "claude-opus-5-5", 1, 1, 0, 0, false, toolUse("a1", "mcp__switchyard__attach_external_ref", `{}`)),
	)
	// PR in a subagent file, attach in the main thread of the same session.
	f.write("-home-magos-projects-a/split.jsonl",
		asst(day, "split", "m1", "claude-opus-5-5", 1, 1, 0, 0, false, toolUse("a1", "mcp__claude_ai_Switchyard__attach_external_ref", `{}`)),
	)
	f.write("-home-magos-projects-a/split/subagents/agent-1.jsonl",
		asst(day, "split", "m9", "claude-opus-5-5", 1, 1, 0, 0, true, bash("b1", "gh   pr\tcreate")),
	)
	// PR, no attach; and a near-miss command that is not a PR creation.
	f.write("-home-magos-projects-a/bad.jsonl",
		asst(day, "bad", "m1", "claude-opus-5-5", 1, 1, 0, 0, false, bash("b1", "gh pr create")),
	)
	f.write("-home-magos-projects-a/none.jsonl",
		asst(day, "none", "m1", "claude-opus-5-5", 1, 1, 0, 0, false, bash("b1", "gh pr view 3; echo gh-pr-create")),
	)
	// A runner PR session does not count toward the interactive share.
	f.write("-home-magos-runners-a--work-a-a/run.jsonl",
		asst(day, "run", "m1", "claude-opus-5-5", 1, 1, 0, 0, false, bash("b1", "gh pr create")),
	)
	r := scan(t, f, "2026-11-01", "2026-11-01").Compliance()
	pr := r.PR[KindInteractive]
	if pr.Sessions != 4 || pr.PRSessions != 3 || pr.WithAttach != 2 {
		t.Errorf("interactive = %+v, want 4 sessions, 3 PR, 2 attach", pr)
	}
	if pr.Share < 0.66 || pr.Share > 0.67 {
		t.Errorf("share = %v, want 2/3", pr.Share)
	}
	if rp := r.PR[KindRunner]; rp.PRSessions != 1 || rp.WithAttach != 0 {
		t.Errorf("runner = %+v", rp)
	}
}

func TestOperatorPrompts(t *testing.T) {
	f := newFx(t)
	const sid = "p"
	f.write("-home-magos-projects-a/p.jsonl",
		userText(day, sid, "u1", "Please FILE A TICKET for that", ""),
		userText(day, sid, "u1", "Please FILE A TICKET for that", ""), // resumed copy, same uuid
		userText(day, sid, "u2", "I don’t see the PR", ""),
		userText(day, sid, "u3", "file a ticket and I don't see it", `,"origin":{"kind":"human"}`),
		userText(day, sid, "u4", "file a ticket", `,"isMeta":true`),
		userText(day, sid, "u5", "This session continues: file a ticket", `,"isCompactSummary":true`),
		userText(day, sid, "u6", "file a ticket", `,"origin":{"kind":"task-notification"}`),
		userText(day, sid, "u7", "file a ticket", `,"isSidechain":true`),
		userText(day, sid, "u8", "nothing relevant", ""),
		toolResult(day, sid, "u9", "x", "file a ticket I don't see", false),
		// Content as text blocks.
		`{"type":"user","timestamp":"`+day+`","sessionId":"p","uuid":"u10","message":{"content":[{"type":"text","text":"file"},{"type":"text","text":"a ticket"}]}}`,
	)
	pc := scan(t, f, "2026-11-01", "2026-11-01").Compliance().Prompts[KindInteractive]
	if pc.FileATkt != 3 || pc.IDontSee != 2 {
		t.Errorf("file a ticket %d (want 3), I don't see %d (want 2)", pc.FileATkt, pc.IDontSee)
	}
	if pc.Prompts != 5 {
		t.Errorf("prompts = %d, want 5", pc.Prompts)
	}
}

func TestPlanToolsAndGetPlanErrors(t *testing.T) {
	f := newFx(t)
	sw := "mcp__switchyard__"
	f.write("-home-magos-projects-a/s.jsonl",
		asst(day, "s", "m1", "claude-opus-5-5", 1, 1, 0, 0, false,
			toolUse("g1", sw+"get_plan", `{}`), toolUse("g2", sw+"get_plan", `{}`),
			toolUse("g3", "mcp__claude_ai_Switchyard__get_plan", `{}`), toolUse("g4", sw+"get_plan", `{}`),
			toolUse("o1", sw+"open_plan_draft", `{}`), toolUse("s1", sw+"submit_plan", `{}`),
			toolUse("r1", sw+"revise_plan", `{}`), toolUse("r2", sw+"revise_plan", `{}`),
			toolUse("f1", sw+"get_plan_feedback", `{}`), toolUse("x1", "mcp__other__get_plan", `{}`),
		),
		toolResult(day, "s", "r1", "g1", "plan not found", true),
		toolResult(day, "s", "r2", "g2", "{ok}", false),
		toolResult(day, "s", "r3", "g3", "Error: result too large", false), // unflagged, counted apart
		toolResult(day, "s", "r4", "g4", "boom", true),
		toolResult(day, "s", "r5", "r1", "boom", true), // an error on another tool is not a get_plan error
	)
	r := scan(t, f, "2026-11-01", "2026-11-01").Compliance()
	want := map[string]int{"open_plan_draft": 1, "submit_plan": 1, "revise_plan": 2, "get_plan": 4, "get_plan_feedback": 1}
	for k, v := range want {
		if r.PlanTools[k] != v {
			t.Errorf("%s = %d, want %d", k, r.PlanTools[k], v)
		}
	}
	if r.GetPlanErr != 2 || r.GetPlanUnflagged != 1 {
		t.Errorf("get_plan errors %d (want 2), unflagged %d (want 1)", r.GetPlanErr, r.GetPlanUnflagged)
	}
	if r.GetPlanRate != 0.5 {
		t.Errorf("rate = %v, want 0.5", r.GetPlanRate)
	}
}

func TestPermissionDenials(t *testing.T) {
	f := newFx(t)
	pd := func(uuid, body string) string {
		return fmt.Sprintf(`{"type":"user","timestamp":%q,"sessionId":"s","uuid":%q,"permissionDecision":%s,"message":{"content":[{"type":"tool_result","tool_use_id":"z","content":"x"}]}}`, day, uuid, body)
	}
	f.write("-home-magos-projects-a/s.jsonl",
		pd("1", `{"decision":"reject","source":"config","reasonType":"classifier","classifierCategory":"production_deploy"}`),
		pd("1", `{"decision":"reject","source":"config","reasonType":"classifier","classifierCategory":"production_deploy"}`), // duplicate
		pd("2", `{"decision":"reject","source":"config","reasonType":"classifier"}`),
		pd("3", `{"decision":"reject","source":"hook","classifierCategory":"a prose value that must not be echoed"}`),
		pd("4", `{"decision":"accept","source":"config","reasonType":"classifier"}`),
		pd("5", `"reject"`), // not an object
	)
	r := scan(t, f, "2026-11-01", "2026-11-01").Compliance().Denials
	if r.Total != 3 {
		t.Fatalf("total = %d, want 3: %v", r.Total, r.ByRule)
	}
	for _, k := range []string{"config/classifier/production_deploy", "config/classifier/-", "hook/-/(redacted)"} {
		if r.ByRule[k] != 1 {
			t.Errorf("rule %q = %d, want 1 (%v)", k, r.ByRule[k], r.ByRule)
		}
	}
}

func TestMalformedAndLongLines(t *testing.T) {
	f := newFx(t)
	// 3 MiB of tool output in one line: far over bufio.Scanner's default limit.
	big := strings.Repeat("x", 3<<20)
	f.write("-home-magos-projects-a/s.jsonl",
		`{"type":"assistant","timestamp":"`+day+`","sessionId":"s","message":{"id":"m0","model":"claude-opus-5-5","usage":{"output_tokens":1},"content":[{"type":"text","text":"`+big+`"}]}}`,
		`{"type":"assistant","timestamp": TRUNCATED`,
		`not json at all`,
		``,
		asst(day, "s", "m1", "claude-opus-5-5", 0, 7, 0, 0, false),
	)
	st := scan(t, f, "2026-11-01", "2026-11-01")
	r := st.Usage()
	if r.Tokens.Total != 8 {
		t.Errorf("total = %d, want 8: the line after the long one must still be read", r.Tokens.Total)
	}
	if st.Malformed != 2 {
		t.Errorf("malformed = %d, want 2", st.Malformed)
	}
}

// The reports are counts and identifiers only. A canary planted in every kind
// of content must not appear in text or JSON output of either subcommand.
func TestNoTranscriptContentInOutput(t *testing.T) {
	const canary = "CANARY-sk-live-0123456789"
	f := newFx(t)
	f.write("-home-magos-projects-a/s.jsonl",
		userText(day, "s", "u1", "file a ticket "+canary, ""),
		asst(day, "s", "m1", "claude-opus-5-5", 1, 1, 0, 0, false,
			toolUse("t1", "Bash", `{"command":"gh pr create --body `+canary+`"}`),
			toolUse("t2", "Agent", `{"model":"sonnet","prompt":"`+canary+`"}`),
			toolUse("t3", "mcp__switchyard__get_plan", `{"id":"`+canary+`"}`)),
		toolResult(day, "s", "u2", "t3", "Error "+canary, false),
		`{"type":"user","timestamp":"`+day+`","sessionId":"s","uuid":"u3","permissionDecision":{"decision":"reject","source":"config","reasonType":"classifier"},"message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"`+canary+`"}]}}`,
	)
	for _, args := range [][]string{
		{"usage"}, {"usage", "--json"}, {"compliance"}, {"compliance", "--json"},
	} {
		var out, errb bytes.Buffer
		full := append(append([]string{}, args...), "--since", "2026-11-01", "--until", "2026-11-01", "--root", f.root)
		if code := run(full, &out, &errb); code != 0 {
			t.Fatalf("%v exited %d: %s", args, code, errb.String())
		}
		if strings.Contains(out.String(), canary) || strings.Contains(errb.String(), canary) {
			t.Errorf("%v leaked transcript content", args)
		}
		if strings.Contains(strings.Join(args, " "), "--json") && !json.Valid(out.Bytes()) {
			t.Errorf("%v produced invalid JSON", args)
		}
	}
}

func TestRunRejectsBadArgs(t *testing.T) {
	for _, args := range [][]string{
		{}, {"bogus"}, {"usage"}, {"usage", "--since", "2026-11-01"},
		{"usage", "--since", "11/01/2026", "--until", "2026-11-02"},
		{"usage", "--since", "2026-11-05", "--until", "2026-11-02"},
	} {
		var out, errb bytes.Buffer
		if code := run(args, &out, &errb); code != 2 {
			t.Errorf("run(%v) = %d, want 2", args, code)
		}
	}
}
