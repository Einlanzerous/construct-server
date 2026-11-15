// transcript-audit re-runs the SERV-320 measures of Claude Code usage and
// workflow compliance from the transcripts under ~/.claude/projects, so the
// numbers can be taken again later and compared with the baseline in the
// README. It prints counts, shares and project directory names only; it never
// prints a prompt, a tool input or a tool output (transcripts contain
// credentials).
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"
)

const usageText = `usage:
  transcript-audit usage      --since YYYY-MM-DD --until YYYY-MM-DD [--root DIR] [--top N] [--json]
  transcript-audit compliance --since YYYY-MM-DD --until YYYY-MM-DD [--root DIR] [--json]
`

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

func run(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprint(stderr, usageText)
		return 2
	}
	cmd := args[0]
	if cmd != "usage" && cmd != "compliance" {
		fmt.Fprintf(stderr, "unknown subcommand %q\n%s", cmd, usageText)
		return 2
	}
	fl := flag.NewFlagSet(cmd, flag.ContinueOnError)
	fl.SetOutput(stderr)
	home, _ := os.UserHomeDir()
	since := fl.String("since", "", "first day, YYYY-MM-DD (UTC, inclusive)")
	until := fl.String("until", "", "last day, YYYY-MM-DD (UTC, inclusive)")
	root := fl.String("root", filepath.Join(home, ".claude", "projects"), "transcript root")
	asJSON := fl.Bool("json", false, "emit JSON instead of text")
	top := fl.Int("top", 15, "usage: directories to list in text output (0 = all)")
	if err := fl.Parse(args[1:]); err != nil {
		return 2
	}
	for name, v := range map[string]string{"--since": *since, "--until": *until} {
		if _, err := time.Parse("2006-01-02", v); err != nil {
			fmt.Fprintf(stderr, "%s must be YYYY-MM-DD, got %q\n", name, v)
			return 2
		}
	}
	if *since > *until {
		fmt.Fprintln(stderr, "--since is after --until")
		return 2
	}
	st, err := Scan(*root, *since, *until)
	if err != nil {
		fmt.Fprintf(stderr, "scan %s: %v\n", *root, err)
		return 1
	}
	if cmd == "usage" {
		r := st.Usage()
		if *asJSON {
			return emit(stdout, stderr, r)
		}
		r.WriteText(stdout, *top)
		return 0
	}
	r := st.Compliance()
	if *asJSON {
		return emit(stdout, stderr, r)
	}
	r.WriteText(stdout)
	return 0
}

func emit(stdout, stderr io.Writer, v any) int {
	enc := json.NewEncoder(stdout)
	enc.SetIndent("", "  ")
	if err := enc.Encode(v); err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	return 0
}
