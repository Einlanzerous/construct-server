package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Everything below reads transcript lines and keeps only counters and
// identifiers. No prompt, tool input or tool output is ever stored beyond the
// few bytes needed to decide a boolean, and none of it is printed.

type usageTokens struct{ In, Out, CacheRead, CacheWrite int64 }

func (u usageTokens) total() int64 { return u.In + u.Out + u.CacheRead + u.CacheWrite }

type entry struct {
	Type             string          `json:"type"`
	Timestamp        string          `json:"timestamp"`
	SessionID        string          `json:"sessionId"`
	UUID             string          `json:"uuid"`
	IsSidechain      bool            `json:"isSidechain"`
	IsMeta           bool            `json:"isMeta"`
	IsCompactSummary bool            `json:"isCompactSummary"`
	PermDecision     json.RawMessage `json:"permissionDecision"`
	Origin           json.RawMessage `json:"origin"`
	Message          struct {
		ID      string          `json:"id"`
		Model   string          `json:"model"`
		Content json.RawMessage `json:"content"`
		Usage   struct {
			In         int64 `json:"input_tokens"`
			Out        int64 `json:"output_tokens"`
			CacheRead  int64 `json:"cache_read_input_tokens"`
			CacheWrite int64 `json:"cache_creation_input_tokens"`
		} `json:"usage"`
	} `json:"message"`
}

type block struct {
	Type      string          `json:"type"`
	ID        string          `json:"id"`
	Name      string          `json:"name"`
	Text      string          `json:"text"`
	Input     json.RawMessage `json:"input"`
	ToolUseID string          `json:"tool_use_id"`
	IsError   bool            `json:"is_error"`
	Content   json.RawMessage `json:"content"`
}

type permDecision struct {
	Decision           string `json:"decision"`
	Source             string `json:"source"`
	ReasonType         string `json:"reasonType"`
	ClassifierCategory string `json:"classifierCategory"`
}

type session struct {
	Dir  string
	Kind string

	PRCreate bool // ran `gh pr create` (main thread or subagent)
	Attach   bool // called attach_external_ref
	Prompts  int
	FileTkt  int
	DontSee  int
}

type msgKey struct {
	sid string
	mid string
}

type msgRec struct {
	model string
	dir   string
	side  bool
	u     usageTokens
}

type dirAgg struct {
	Sessions int
	Turns    int
	Tokens   int64
}

type Stats struct {
	Since, Until string

	Files     int
	Lines     int
	Malformed int

	sessions map[string]*session
	msgs     map[msgKey]*msgRec

	// Spawns of the Agent/Task tool, by whether they named a model.
	SpawnNamed   int
	SpawnUnnamed int
	SpawnByModel map[string]int
	SpawnByKind  map[string][2]int // kind -> [named, unnamed]

	PlanCalls     map[string]int
	PlanCallsKind map[string]map[string]int
	GetPlanErrors int // result flagged is_error
	// GetPlanUnflagged counts results whose text starts with "Error" although
	// is_error is unset: in the baseline window these are the client refusing
	// an oversize plan, a different failure from the server erroring.
	GetPlanUnflagged int

	Denials map[string]int

	seenUse    map[string]struct{}
	seenPerm   map[string]struct{}
	seenPrompt map[string]struct{}
}

func newStats(since, until string) *Stats {
	return &Stats{
		Since: since, Until: until,
		sessions:      map[string]*session{},
		msgs:          map[msgKey]*msgRec{},
		SpawnByModel:  map[string]int{},
		SpawnByKind:   map[string][2]int{},
		PlanCalls:     map[string]int{},
		PlanCallsKind: map[string]map[string]int{},
		Denials:       map[string]int{},
		seenUse:       map[string]struct{}{},
		seenPerm:      map[string]struct{}{},
		seenPrompt:    map[string]struct{}{},
	}
}

// Scan reads every *.jsonl under root (subagent transcripts included) and
// aggregates events whose UTC date lies in [since, until].
func Scan(root, since, until string) (*Stats, error) {
	st := newStats(since, until)
	cutoff, _ := time.Parse("2006-01-02", since)
	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			if path == root {
				return err
			}
			return nil // unreadable subtree: skip, do not abort the audit
		}
		if d.IsDir() || !strings.HasSuffix(path, ".jsonl") {
			return nil
		}
		// A file last written before the window cannot hold an event inside it.
		if info, ierr := d.Info(); ierr == nil && info.ModTime().Before(cutoff) {
			return nil
		}
		rel, rerr := filepath.Rel(root, path)
		if rerr != nil {
			return nil
		}
		parts := strings.Split(filepath.ToSlash(rel), "/")
		sub := false
		for _, p := range parts[:len(parts)-1] {
			if p == "subagents" {
				sub = true
			}
		}
		if len(parts) < 2 {
			return nil // not <project-dir>/<file>
		}
		st.Files++
		return st.scanFile(path, parts[0], sub)
	})
	return st, err
}

var (
	needAssistant = []byte(`"type":"assistant"`)
	needUser      = []byte(`"type":"user"`)
)

// scanFile streams one transcript. Lines are read with ReadBytes, which grows
// to the line length, because a single line can be megabytes (embedded tool
// output) and bufio.Scanner's default 64 KiB token limit would stop at the
// first one.
func (st *Stats) scanFile(path, dir string, sub bool) error {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()
	return st.scanReader(f, dir, sub)
}

func (st *Stats) scanReader(r io.Reader, dir string, sub bool) error {
	br := bufio.NewReaderSize(r, 1<<20)
	fst := &fileState{names: map[string]string{}}
	for {
		line, err := br.ReadBytes('\n')
		if len(line) > 0 {
			st.line(line, dir, sub, fst)
		}
		if err != nil {
			if errors.Is(err, io.EOF) {
				return nil
			}
			return err
		}
	}
}

// fileState is per transcript file: a tool_result only ever follows its call
// in the same file.
type fileState struct {
	names map[string]string // tool_use id -> name, for results we care about
}

func (st *Stats) line(line []byte, dir string, sub bool, fst *fileState) {
	line = bytes.TrimSpace(line)
	if len(line) == 0 {
		return
	}
	st.Lines++
	if line[0] != '{' {
		st.Malformed++
		return
	}
	if !bytes.Contains(line, needAssistant) && !bytes.Contains(line, needUser) {
		return // other event kinds carry nothing this tool measures
	}
	var e entry
	if err := json.Unmarshal(line, &e); err != nil {
		st.Malformed++
		return
	}
	if (e.Type != "assistant" && e.Type != "user") || len(e.Timestamp) < 10 || e.SessionID == "" {
		return
	}
	day := e.Timestamp[:10]
	if day < st.Since || day > st.Until {
		return
	}
	s := st.sessions[e.SessionID]
	if s == nil {
		s = &session{Dir: dir, Kind: classify(dir)}
		st.sessions[e.SessionID] = s
	}
	side := e.IsSidechain || sub
	if e.Type == "assistant" {
		st.assistant(&e, s, dir, side, fst)
	} else {
		st.user(&e, s, side, fst)
	}
}

func (st *Stats) assistant(e *entry, s *session, dir string, side bool, fst *fileState) {
	m := &e.Message
	if m.ID != "" && m.Model != "<synthetic>" {
		k := msgKey{e.SessionID, m.ID}
		u := usageTokens{m.Usage.In, m.Usage.Out, m.Usage.CacheRead, m.Usage.CacheWrite}
		// One API message is written once per streamed content block; the
		// last copy carries the final output count, so keep the largest. A
		// forked subagent's file also replays its parent's history, so the same
		// message can sit in a main and a subagent file: it is one API call, and
		// the main-thread copy is the one that counts.
		old := st.msgs[k]
		if old == nil || (old.side && !side) || (old.side == side && u.Out >= old.u.Out) {
			st.msgs[k] = &msgRec{model: m.Model, dir: dir, side: side, u: u}
		}
	}
	for _, b := range blocks(m.Content) {
		if b.Type != "tool_use" || b.ID == "" {
			continue
		}
		if short, ok := switchyardTool(b.Name); ok && short == "get_plan" {
			fst.names[b.ID] = short // results pair within a file even when the call was counted in another
		}
		// tool_use ids are unique, so key the dedupe on the session: the same
		// call can be replayed in a subagent file that inherited the history.
		if !st.firstSightID(e.SessionID+"/use/"+b.ID, st.seenUse) {
			continue
		}
		st.toolUse(&b, s)
	}
}

func (st *Stats) toolUse(b *block, s *session) {
	var in struct {
		Command json.RawMessage `json:"command"`
		Model   json.RawMessage `json:"model"`
	}
	_ = json.Unmarshal(b.Input, &in) // a mistyped input just yields empty fields
	switch b.Name {
	case "Bash":
		if cmd := rawString(in.Command); cmd != "" && ghPRCreate.MatchString(cmd) {
			s.PRCreate = true
		}
	case "Agent", "Task":
		pair := st.SpawnByKind[s.Kind]
		if model := rawString(in.Model); model != "" {
			st.SpawnNamed++
			pair[0]++
			st.SpawnByModel[safeLabel(model)]++
		} else {
			st.SpawnUnnamed++
			pair[1]++
		}
		st.SpawnByKind[s.Kind] = pair
	}
	if short, ok := switchyardTool(b.Name); ok {
		if short == "attach_external_ref" {
			s.Attach = true
		}
		for _, p := range planTools {
			if short == p {
				st.PlanCalls[p]++
				if st.PlanCallsKind[s.Kind] == nil {
					st.PlanCallsKind[s.Kind] = map[string]int{}
				}
				st.PlanCallsKind[s.Kind][p]++
			}
		}
	}
}

func (st *Stats) user(e *entry, s *session, side bool, fst *fileState) {
	if len(e.PermDecision) > 0 && e.PermDecision[0] == '{' {
		var pd permDecision
		if json.Unmarshal(e.PermDecision, &pd) == nil && pd.Decision == "reject" && st.firstSight(e, st.seenPerm) {
			st.Denials[ruleLabel(pd)]++
		}
	}
	content := e.Message.Content
	if len(content) == 0 {
		return
	}
	var text string
	if content[0] == '"' {
		_ = json.Unmarshal(content, &text)
	} else {
		bs := blocks(content)
		hasResult := false
		var parts []string
		for _, b := range bs {
			switch b.Type {
			case "tool_result":
				hasResult = true
				if fst.names[b.ToolUseID] == "get_plan" {
					delete(fst.names, b.ToolUseID)
					if !st.firstSightID(e.SessionID+"/res/"+b.ToolUseID, st.seenUse) {
						continue
					}
					if b.IsError {
						st.GetPlanErrors++
					} else if leadsWithError(b.Content) {
						st.GetPlanUnflagged++
					}
				}
			case "text":
				parts = append(parts, b.Text)
			}
		}
		if hasResult {
			return
		}
		text = strings.Join(parts, " ")
	}
	// An operator prompt is a typed main-thread user turn: not a subagent
	// brief (sidechain), not injected context (meta), not a compaction summary.
	if side || e.IsMeta || e.IsCompactSummary || nonHumanOrigin(e.Origin) || text == "" || !st.firstSight(e, st.seenPrompt) {
		return
	}
	s.Prompts++
	if hasPhrase(text, PhraseFileTicket) {
		s.FileTkt++
	}
	if hasPhrase(text, PhraseDontSee) {
		s.DontSee++
	}
}

// firstSight dedupes user events by (session, uuid): a resumed session copies
// earlier turns into a new file, and each copy must count once.
func (st *Stats) firstSight(e *entry, seen map[string]struct{}) bool {
	if e.UUID == "" {
		return true
	}
	k := e.SessionID + "/" + e.UUID
	if _, dup := seen[k]; dup {
		return false
	}
	seen[k] = struct{}{}
	return true
}

// firstSightID reports whether key is new in seen, recording it.
func (st *Stats) firstSightID(key string, seen map[string]struct{}) bool {
	if _, dup := seen[key]; dup {
		return false
	}
	seen[key] = struct{}{}
	return true
}

func ruleLabel(pd permDecision) string {
	cat := safeLabel(pd.ClassifierCategory)
	if cat == "" {
		cat = "-"
	}
	src, rt := safeLabel(pd.Source), safeLabel(pd.ReasonType)
	if src == "" {
		src = "-"
	}
	if rt == "" {
		rt = "-"
	}
	return src + "/" + rt + "/" + cat
}

func blocks(raw json.RawMessage) []block {
	if len(raw) == 0 || raw[0] != '[' {
		return nil
	}
	var rawBlocks []json.RawMessage
	if json.Unmarshal(raw, &rawBlocks) != nil {
		return nil
	}
	out := make([]block, 0, len(rawBlocks))
	for _, rb := range rawBlocks {
		var b block
		if json.Unmarshal(rb, &b) == nil { // skip a block that does not fit, keep the rest
			out = append(out, b)
		}
	}
	return out
}

func rawString(raw json.RawMessage) string {
	if len(raw) == 0 || raw[0] != '"' {
		return ""
	}
	var s string
	_ = json.Unmarshal(raw, &s)
	return s
}

// leadsWithError reports whether a tool result's text starts with "Error",
// the shape some failures take without is_error being set. Only the
// boolean leaves this function.
func leadsWithError(raw json.RawMessage) bool {
	if len(raw) == 0 {
		return false
	}
	var t string
	if raw[0] == '"' {
		_ = json.Unmarshal(raw, &t)
	} else {
		for _, b := range blocks(raw) {
			if b.Text != "" {
				t = b.Text
				break
			}
		}
	}
	return strings.HasPrefix(t, "Error")
}

// nonHumanOrigin is true when the entry says it came from something other
// than the operator (for example a task-notification). Entries with no origin
// are older or untagged and are kept.
func nonHumanOrigin(raw json.RawMessage) bool {
	if len(raw) == 0 || raw[0] != '{' {
		return false
	}
	var o struct {
		Kind string `json:"kind"`
	}
	return json.Unmarshal(raw, &o) == nil && o.Kind != "" && o.Kind != "human"
}
