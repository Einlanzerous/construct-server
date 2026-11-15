package main

import (
	"fmt"
	"io"
	"sort"
	"text/tabwriter"
)

type UsageReport struct {
	Window    Window                  `json:"window"`
	Files     int                     `json:"files"`
	Lines     int                     `json:"lines"`
	Malformed int                     `json:"malformed_lines"`
	Sessions  int                     `json:"sessions"`
	ByKind    map[string]KindUsage    `json:"by_kind"`
	Tokens    TokenSplit              `json:"tokens"`
	Families  map[string]FamilyTokens `json:"by_model_family"`
	Spawns    Spawns                  `json:"subagent_spawns"`
	ByDir     []DirUsage              `json:"by_directory"`
}

type Window struct {
	Since string `json:"since"`
	Until string `json:"until"`
}

type KindUsage struct {
	Sessions int   `json:"sessions"`
	Turns    int   `json:"turns"`
	Tokens   int64 `json:"tokens"`
}

type TokenSplit struct {
	Total         int64   `json:"total"`
	Main          int64   `json:"main_thread"`
	Subagent      int64   `json:"subagent"`
	SubagentShare float64 `json:"subagent_share"`
}

type FamilyTokens struct {
	Main          int64   `json:"main_thread"`
	Subagent      int64   `json:"subagent"`
	Total         int64   `json:"total"`
	ShareOfAll    float64 `json:"share_of_all_tokens"`
	SubagentOfAll float64 `json:"subagent_share_of_all_tokens"`
	SubagentTurns int     `json:"subagent_turns"`
}

type Spawns struct {
	Total      int               `json:"total"`
	NamedModel int               `json:"named_model"`
	NoModel    int               `json:"no_model"`
	NamedShare float64           `json:"named_share"`
	ByModel    map[string]int    `json:"by_model"`
	ByKind     map[string][2]int `json:"by_kind_named_unnamed"`
}

type DirUsage struct {
	Dir      string  `json:"dir"`
	Kind     string  `json:"kind"`
	Sessions int     `json:"sessions"`
	Turns    int     `json:"turns"`
	Tokens   int64   `json:"tokens"`
	Share    float64 `json:"share"`
}

func ratio(a, b int64) float64 {
	if b == 0 {
		return 0
	}
	return float64(a) / float64(b)
}

func (st *Stats) Usage() UsageReport {
	r := UsageReport{
		Window:    Window{st.Since, st.Until},
		Files:     st.Files,
		Lines:     st.Lines,
		Malformed: st.Malformed,
		Sessions:  len(st.sessions),
		ByKind:    map[string]KindUsage{},
		Families:  map[string]FamilyTokens{},
	}
	dirs := map[string]*dirAgg{}
	dirKind := map[string]string{}
	for _, s := range st.sessions {
		k := r.ByKind[s.Kind]
		k.Sessions++
		r.ByKind[s.Kind] = k
		d := dirs[s.Dir]
		if d == nil {
			d = &dirAgg{}
			dirs[s.Dir] = d
		}
		d.Sessions++
		dirKind[s.Dir] = s.Kind
	}
	for _, m := range st.msgs {
		t := m.u.total()
		r.Tokens.Total += t
		ft := r.Families[family(m.model)]
		ft.Total += t
		if m.side {
			r.Tokens.Subagent += t
			ft.Subagent += t
			ft.SubagentTurns++
		} else {
			r.Tokens.Main += t
			ft.Main += t
		}
		r.Families[family(m.model)] = ft
		k := classify(m.dir)
		ku := r.ByKind[k]
		ku.Turns++
		ku.Tokens += t
		r.ByKind[k] = ku
		d := dirs[m.dir]
		if d == nil {
			d = &dirAgg{}
			dirs[m.dir] = d
			dirKind[m.dir] = k
		}
		d.Turns++
		d.Tokens += t
	}
	r.Tokens.SubagentShare = ratio(r.Tokens.Subagent, r.Tokens.Total)
	for f, ft := range r.Families {
		ft.ShareOfAll = ratio(ft.Total, r.Tokens.Total)
		ft.SubagentOfAll = ratio(ft.Subagent, r.Tokens.Total)
		r.Families[f] = ft
	}
	r.Spawns = Spawns{
		Total: st.SpawnNamed + st.SpawnUnnamed, NamedModel: st.SpawnNamed, NoModel: st.SpawnUnnamed,
		ByModel: st.SpawnByModel, ByKind: st.SpawnByKind,
	}
	r.Spawns.NamedShare = ratio(int64(st.SpawnNamed), int64(r.Spawns.Total))
	for dir, d := range dirs {
		r.ByDir = append(r.ByDir, DirUsage{dir, dirKind[dir], d.Sessions, d.Turns, d.Tokens, ratio(d.Tokens, r.Tokens.Total)})
	}
	sort.Slice(r.ByDir, func(i, j int) bool {
		if r.ByDir[i].Tokens != r.ByDir[j].Tokens {
			return r.ByDir[i].Tokens > r.ByDir[j].Tokens
		}
		return r.ByDir[i].Dir < r.ByDir[j].Dir
	})
	return r
}

func pct(f float64) string { return fmt.Sprintf("%.1f%%", 100*f) }

// WriteText renders the usage report. topDirs <= 0 prints every directory.
func (r UsageReport) WriteText(w io.Writer, topDirs int) {
	fmt.Fprintf(w, "transcript-audit usage  %s .. %s (UTC, inclusive)\n", r.Window.Since, r.Window.Until)
	fmt.Fprintf(w, "files %d, lines %d, malformed lines skipped %d\n\n", r.Files, r.Lines, r.Malformed)
	fmt.Fprintf(w, "## SESSIONS %d\n", r.Sessions)
	tw := tabwriter.NewWriter(w, 0, 2, 2, ' ', 0)
	fmt.Fprintln(tw, "kind\tsessions\tturns\ttokens")
	for _, k := range Kinds {
		u := r.ByKind[k]
		fmt.Fprintf(tw, "%s\t%d\t%d\t%d\n", k, u.Sessions, u.Turns, u.Tokens)
	}
	tw.Flush()
	fmt.Fprintf(w, "\n## TOKENS total %d  main %d  subagent %d  subagent share %s\n", r.Tokens.Total, r.Tokens.Main, r.Tokens.Subagent, pct(r.Tokens.SubagentShare))
	tw = tabwriter.NewWriter(w, 0, 2, 2, ' ', 0)
	fmt.Fprintln(tw, "family\tmain\tsubagent\ttotal\tshare of all\tsubagent share of all")
	for _, f := range Families {
		ft, ok := r.Families[f]
		if !ok {
			continue
		}
		fmt.Fprintf(tw, "%s\t%d\t%d\t%d\t%s\t%s\n", f, ft.Main, ft.Subagent, ft.Total, pct(ft.ShareOfAll), pct(ft.SubagentOfAll))
	}
	tw.Flush()
	fmt.Fprintf(w, "\n## SUBAGENT SPAWNS %d  named a model %d (%s)  named none %d\n", r.Spawns.Total, r.Spawns.NamedModel, pct(r.Spawns.NamedShare), r.Spawns.NoModel)
	for _, m := range sortedKeys(r.Spawns.ByModel) {
		fmt.Fprintf(w, "  model %s: %d\n", m, r.Spawns.ByModel[m])
	}
	n := len(r.ByDir)
	if topDirs > 0 && n > topDirs {
		n = topDirs
	}
	fmt.Fprintf(w, "\n## TOKENS BY STARTING DIRECTORY (top %d of %d)\n", n, len(r.ByDir))
	tw = tabwriter.NewWriter(w, 0, 2, 2, ' ', 0)
	fmt.Fprintln(tw, "directory\tkind\tsessions\tturns\ttokens\tshare")
	for _, d := range r.ByDir[:n] {
		fmt.Fprintf(tw, "%s\t%s\t%d\t%d\t%d\t%s\n", d.Dir, d.Kind, d.Sessions, d.Turns, d.Tokens, pct(d.Share))
	}
	tw.Flush()
}

type ComplianceReport struct {
	Window    Window `json:"window"`
	Files     int    `json:"files"`
	Lines     int    `json:"lines"`
	Malformed int    `json:"malformed_lines"`
	Sessions  int    `json:"sessions"`

	PR      map[string]PRCompliance `json:"pr_sessions_by_kind"`
	Prompts map[string]PromptCounts `json:"operator_prompts_by_kind"`

	PlanTools        map[string]int            `json:"plan_tool_calls"`
	PlanByKind       map[string]map[string]int `json:"plan_tool_calls_by_kind"`
	GetPlanErr       int                       `json:"get_plan_errors"`
	GetPlanRate      float64                   `json:"get_plan_error_rate"`
	GetPlanUnflagged int                       `json:"get_plan_unflagged_error_text"`
	Denials          DenialReport              `json:"permission_denials"`
}

type PRCompliance struct {
	Sessions   int     `json:"sessions"`
	PRSessions int     `json:"pr_sessions"`
	WithAttach int     `json:"with_attach_external_ref"`
	Share      float64 `json:"share"`
}

type PromptCounts struct {
	Prompts  int `json:"prompts"`
	FileATkt int `json:"file_a_ticket"`
	IDontSee int `json:"i_dont_see"`
}

type DenialReport struct {
	Total  int            `json:"total"`
	ByRule map[string]int `json:"by_rule"`
}

func (st *Stats) Compliance() ComplianceReport {
	r := ComplianceReport{
		Window: Window{st.Since, st.Until}, Files: st.Files, Lines: st.Lines, Malformed: st.Malformed,
		Sessions: len(st.sessions),
		PR:       map[string]PRCompliance{}, Prompts: map[string]PromptCounts{},
		PlanTools: map[string]int{}, PlanByKind: st.PlanCallsKind, GetPlanErr: st.GetPlanErrors, GetPlanUnflagged: st.GetPlanUnflagged,
		Denials: DenialReport{ByRule: st.Denials},
	}
	for _, p := range planTools {
		r.PlanTools[p] = st.PlanCalls[p]
	}
	r.GetPlanRate = ratio(int64(st.GetPlanErrors), int64(st.PlanCalls["get_plan"]))
	for _, s := range st.sessions {
		pr := r.PR[s.Kind]
		pr.Sessions++
		if s.PRCreate {
			pr.PRSessions++
			if s.Attach {
				pr.WithAttach++
			}
		}
		r.PR[s.Kind] = pr
		pc := r.Prompts[s.Kind]
		pc.Prompts += s.Prompts
		pc.FileATkt += s.FileTkt
		pc.IDontSee += s.DontSee
		r.Prompts[s.Kind] = pc
	}
	for k, pr := range r.PR {
		pr.Share = ratio(int64(pr.WithAttach), int64(pr.PRSessions))
		r.PR[k] = pr
	}
	for _, n := range st.Denials {
		r.Denials.Total += n
	}
	return r
}

func (r ComplianceReport) WriteText(w io.Writer) {
	fmt.Fprintf(w, "transcript-audit compliance  %s .. %s (UTC, inclusive)\n", r.Window.Since, r.Window.Until)
	fmt.Fprintf(w, "files %d, lines %d, malformed lines skipped %d, sessions %d\n\n", r.Files, r.Lines, r.Malformed, r.Sessions)
	fmt.Fprintln(w, "## PR SESSIONS (ran `gh pr create`) THAT CALLED attach_external_ref")
	tw := tabwriter.NewWriter(w, 0, 2, 2, ' ', 0)
	fmt.Fprintln(tw, "kind\tsessions\tPR sessions\twith attach\tshare")
	for _, k := range Kinds {
		p := r.PR[k]
		fmt.Fprintf(tw, "%s\t%d\t%d\t%d\t%s\n", k, p.Sessions, p.PRSessions, p.WithAttach, pct(p.Share))
	}
	tw.Flush()
	fmt.Fprintln(w, "\n## OPERATOR PROMPTS (typed main-thread turns, case-insensitive phrase match)")
	tw = tabwriter.NewWriter(w, 0, 2, 2, ' ', 0)
	fmt.Fprintln(tw, "kind\tprompts\t\"file a ticket\"\t\"I don't see\"")
	for _, k := range Kinds {
		p := r.Prompts[k]
		fmt.Fprintf(tw, "%s\t%d\t%d\t%d\n", k, p.Prompts, p.FileATkt, p.IDontSee)
	}
	tw.Flush()
	fmt.Fprintln(w, "\n## PLAN TOOL CALLS (Switchyard MCP, both server prefixes)")
	for _, p := range planTools {
		fmt.Fprintf(w, "  %s: %d\n", p, r.PlanTools[p])
	}
	fmt.Fprintf(w, "  get_plan errors (is_error): %d of %d (%s)\n", r.GetPlanErr, r.PlanTools["get_plan"], pct(r.GetPlanRate))
	fmt.Fprintf(w, "  get_plan results starting \"Error\" with is_error unset: %d\n", r.GetPlanUnflagged)
	fmt.Fprintf(w, "\n## PERMISSION DENIALS (permissionDecision=reject) %d, by source/reasonType/classifierCategory\n", r.Denials.Total)
	for _, k := range sortedKeys(r.Denials.ByRule) {
		fmt.Fprintf(w, "  %s: %d\n", k, r.Denials.ByRule[k])
	}
}

func sortedKeys(m map[string]int) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool {
		if m[keys[i]] != m[keys[j]] {
			return m[keys[i]] > m[keys[j]]
		}
		return keys[i] < keys[j]
	})
	return keys
}
