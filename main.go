// Command claude-menu is the account picker behind the `claude` shell wrapper.
// It gathers the launchable accounts from `cswap list --json`, annotates them
// with live 5h/7d usage from the usage endpoint, hides the ones listed in the
// disabled state file, and draws a chicle list. It prints the chosen account's
// email on stdout (empty output / non-zero exit means "don't launch"); the
// shell wrapper does the actual cswap launch.
//
// Actions under the list:
//   - open Claude:     return the cursor account (what Enter does by default)
//   - disable account: add it to the disabled file and move it to the Disabled
//     section, keeping the picker open
//   - enable account:  the reverse, shown only on a disabled row
//
// With --auto it skips the UI and prints the account with the most headroom
// (lowest 5h, then lowest 7d, among enabled accounts under 100%). If none
// qualifies it shows the picker, unless --unattended, which prints the first
// enabled account instead. --args "<text>" is shown in the header only.
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"time"

	"github.com/grillermo/chicle"
)

const defaultUsageURL = "https://my-claude-usage.chiq.me"

type account struct {
	Email    string
	Five     *float64 // 5h usage percent, nil when unknown
	Weekly   *float64 // 7d usage percent, nil when unknown
	Disabled bool
}

// maxed reports whether either known usage window is at 100% or more, so the
// account should not be auto-picked as the default.
func (a account) maxed() bool {
	return (a.Five != nil && *a.Five >= 100) || (a.Weekly != nil && *a.Weekly >= 100)
}

func pct(v *float64) string {
	if v == nil {
		return "--"
	}
	return fmt.Sprintf("%d%%", int(*v)) // floor, like the old jq
}

// liveAccountEmails returns the accounts cswap can launch, in cswap's own
// order. An account missing here can't be launched, so this is the source of
// truth for what the menu may offer.
//
// It reads cswap's sequence.json straight off disk: `cswap list --json` costs
// a Python start (~170ms) and, for any account whose usage is stale, a network
// fetch on top (500ms+), all to hand back the same email list. The subprocess
// stays as the fallback for when the file is missing or its shape changed.
func liveAccountEmails() ([]string, error) {
	if emails, err := sequenceEmails(cswapSequencePath()); err == nil && len(emails) > 0 {
		return emails, nil
	}
	return cswapListEmails()
}

// cswapSequencePath mirrors cswap's get_backup_root (paths.py): the legacy
// ~/.claude-swap-backup on macOS, $XDG_DATA_HOME/claude-swap (default
// ~/.local/share/claude-swap) on Linux.
func cswapSequencePath() string {
	home, _ := os.UserHomeDir()
	root := filepath.Join(home, ".claude-swap-backup")
	if runtime.GOOS == "linux" {
		root = filepath.Join(home, ".local", "share", "claude-swap")
		if xdg := os.Getenv("XDG_DATA_HOME"); xdg != "" {
			if strings.HasPrefix(xdg, "~/") {
				xdg = filepath.Join(home, xdg[2:])
			}
			if filepath.IsAbs(xdg) {
				root = filepath.Join(xdg, "claude-swap")
			}
		}
	}
	return filepath.Join(root, "sequence.json")
}

// sequenceEmails lists the emails in sequence.json in its "sequence" order,
// the order cswap's own list walks (switcher._build_accounts_info).
func sequenceEmails(path string) ([]string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var seq struct {
		Sequence []json.Number `json:"sequence"`
		Accounts map[string]struct {
			Email string `json:"email"`
		} `json:"accounts"`
	}
	if err := json.Unmarshal(data, &seq); err != nil {
		return nil, err
	}
	emails := make([]string, 0, len(seq.Sequence))
	for _, n := range seq.Sequence {
		a, ok := seq.Accounts[n.String()]
		if !ok || a.Email == "" {
			return nil, fmt.Errorf("sequence.json: account %s has no email", n)
		}
		emails = append(emails, a.Email)
	}
	return emails, nil
}

func cswapListEmails() ([]string, error) {
	out, err := exec.Command("cswap", "list", "--json").Output()
	if err != nil {
		return nil, fmt.Errorf("cswap list --json: %w", err)
	}
	var parsed struct {
		Accounts []struct {
			Email string `json:"email"`
		} `json:"accounts"`
	}
	if err := json.Unmarshal(out, &parsed); err != nil {
		return nil, fmt.Errorf("parsing cswap list output: %w", err)
	}
	emails := make([]string, 0, len(parsed.Accounts))
	for _, a := range parsed.Accounts {
		if a.Email != "" {
			emails = append(emails, a.Email)
		}
	}
	return emails, nil
}

type usageRow struct {
	Email  string   `json:"account_email"`
	Five   *float64 `json:"five_hour_usage"`
	Weekly *float64 `json:"weekly_usage"`
}

// fetchUsage returns live usage keyed by email. Any failure (endpoint down,
// slow, malformed) yields an empty map so the menu degrades to bare emails
// rather than hanging or erroring.
func fetchUsage(url string) map[string]usageRow {
	client := &http.Client{Timeout: 3 * time.Second}
	resp, err := client.Get(url)
	if err != nil {
		return nil
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil
	}
	var rows []usageRow
	if err := json.Unmarshal(body, &rows); err != nil {
		return nil
	}
	m := make(map[string]usageRow, len(rows))
	for _, r := range rows {
		m[r.Email] = r
	}
	return m
}

func disabledPath() string {
	dir := os.Getenv("XDG_CONFIG_HOME")
	if dir == "" {
		home, _ := os.UserHomeDir()
		dir = filepath.Join(home, ".config")
	}
	return filepath.Join(dir, "claude-menu", "disabled")
}

func readDisabled(path string) map[string]bool {
	set := map[string]bool{}
	data, err := os.ReadFile(path)
	if err != nil {
		return set // missing file: nothing disabled
	}
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line != "" && !strings.HasPrefix(line, "#") {
			set[line] = true
		}
	}
	return set
}

func writeDisabled(path string, set map[string]bool) error {
	emails := make([]string, 0, len(set))
	for e := range set {
		emails = append(emails, e)
	}
	sort.Strings(emails)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	var b strings.Builder
	b.WriteString("# Accounts hidden from the claude menu (e.g. a lapsed subscription\n")
	b.WriteString("# you might renew). One email per line. Managed by the menu's\n")
	b.WriteString("# disable/enable actions; safe to edit by hand.\n")
	for _, e := range emails {
		b.WriteString(e)
		b.WriteByte('\n')
	}
	return os.WriteFile(path, []byte(b.String()), 0o644)
}

func buildAccounts(liveEmails []string, usage map[string]usageRow, disabled map[string]bool) []account {
	accts := make([]account, 0, len(liveEmails))
	for _, e := range liveEmails {
		a := account{Email: e, Disabled: disabled[e]}
		if u, ok := usage[e]; ok {
			a.Five, a.Weekly = u.Five, u.Weekly
		}
		accts = append(accts, a)
	}
	return accts
}

// best returns the enabled account with the most headroom: lowest 5h, then
// lowest 7d, among those whose both figures are known and under 100%. Empty
// string when nothing qualifies.
func best(accts []account) string {
	email := ""
	var bf, bw float64
	for _, a := range accts {
		if a.Disabled || a.Five == nil || a.Weekly == nil || a.maxed() {
			continue
		}
		if email == "" || *a.Five < bf || (*a.Five == bf && *a.Weekly < bw) {
			email, bf, bw = a.Email, *a.Five, *a.Weekly
		}
	}
	return email
}

func enabledAccounts(accts []account) []account {
	out := make([]account, 0, len(accts))
	for _, a := range accts {
		if !a.Disabled {
			out = append(out, a)
		}
	}
	return out
}

func find(accts []account, email string) account {
	for _, a := range accts {
		if a.Email == email {
			return a
		}
	}
	return account{Email: email}
}

// menuRows turns accounts into chicle rows: enabled ones first under the
// "Accounts" section (most-headroom floated to the top, where the cursor
// starts), then disabled ones under "Disabled". With no disabled accounts
// every row shares a section, so chicle draws no heading.
func menuRows(accts []account) []chicle.Row {
	var on, off []account
	for _, a := range accts {
		if a.Disabled {
			off = append(off, a)
		} else {
			on = append(on, a)
		}
	}
	if b := best(on); b != "" {
		ordered := make([]account, 0, len(on))
		for _, a := range on {
			if a.Email == b {
				ordered = append(ordered, a)
			}
		}
		for _, a := range on {
			if a.Email != b {
				ordered = append(ordered, a)
			}
		}
		on = ordered
	}
	rows := make([]chicle.Row, 0, len(accts))
	for _, a := range on {
		rows = append(rows, chicle.Row{
			Key:     a.Email,
			Section: "Accounts",
			Cols:    []string{a.Email, pct(a.Five), pct(a.Weekly)},
		})
	}
	for _, a := range off {
		rows = append(rows, chicle.Row{
			Key:     a.Email,
			Section: "Disabled",
			Cols:    []string{a.Email, pct(a.Five), pct(a.Weekly)},
		})
	}
	return rows
}

func main() {
	var auto, unattended bool
	var argsLabel string
	argv := os.Args[1:]
	for i := 0; i < len(argv); i++ {
		switch argv[i] {
		case "--auto":
			auto = true
		case "--unattended":
			unattended = true
		case "--args":
			if i+1 < len(argv) {
				i++
				argsLabel = argv[i]
			}
		}
	}

	usageURL := os.Getenv("CLAUDE_USAGE_URL")
	if usageURL == "" {
		usageURL = defaultUsageURL
	}

	// The usage endpoint is a network round trip (~300ms); start it now so it
	// overlaps reading the account list instead of following it.
	usageCh := make(chan map[string]usageRow, 1)
	go func() { usageCh <- fetchUsage(usageURL) }()

	liveEmails, err := liveAccountEmails()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if len(liveEmails) == 0 {
		fmt.Fprintln(os.Stderr, "No cswap accounts. Run: cswap add")
		os.Exit(1)
	}

	usage := <-usageCh
	dpath := disabledPath()
	disabled := readDisabled(dpath)
	accts := buildAccounts(liveEmails, usage, disabled)

	// --- headless selection (--auto) ---
	if auto {
		enabled := enabledAccounts(accts)
		if len(enabled) == 1 {
			fmt.Println(enabled[0].Email)
			return
		}
		if b := best(accts); b != "" {
			a := find(accts, b)
			fmt.Fprintf(os.Stderr, "Launching as %s (%s 5h, %s 7d)\n", b, pct(a.Five), pct(a.Weekly))
			fmt.Println(b)
			return
		}
		if len(enabled) == 0 {
			fmt.Fprintln(os.Stderr, "Every account is disabled; enable one first (claude menu → enable account).")
			os.Exit(1)
		}
		if unattended {
			fmt.Fprintf(os.Stderr, "No account has known usage below 100%%; launching as %s\n", enabled[0].Email)
			fmt.Println(enabled[0].Email)
			return
		}
		fmt.Fprintln(os.Stderr, "No account has known usage below 100%; pick one")
		// fall through to the interactive picker
	}

	// --- interactive picker ---
	choice, err := chicle.Run(buildConfig(liveEmails, usage, disabled, dpath, argsLabel))
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if choice == "" {
		os.Exit(1) // quit without choosing
	}
	fmt.Println(choice)
}

// buildConfig assembles the chicle picker: the account rows, the ACCOUNT/5H/7D
// columns, and the open/disable/enable actions. It takes everything it needs as
// arguments and has no terminal or network side effects of its own (the actions
// only touch the disabled file at dpath), so a test can drive the resulting
// Config through chicle.New and assert on View() and Result() — see ux_test.go.
func buildConfig(liveEmails []string, usage map[string]usageRow, disabled map[string]bool, dpath, argsLabel string) chicle.Config {
	// buildRows reads the live `disabled` map each time, so it reflects the
	// disable/enable actions on reload. Usage and the cswap listing are fetched
	// once and reused.
	buildRows := func() ([]chicle.Row, error) {
		return menuRows(buildAccounts(liveEmails, usage, disabled)), nil
	}

	wAcct := len("ACCOUNT")
	for _, e := range liveEmails {
		if len(e) > wAcct {
			wAcct = len(e)
		}
	}
	cols := []chicle.Column{
		{Title: "ACCOUNT", Width: wAcct},
		{Title: "5H", Width: 4},
		{Title: "7D"},
	}

	title := "Which Claude account?"
	if argsLabel != "" {
		title += "  (claude " + argsLabel + ")"
	}

	actions := []chicle.Action{
		{
			Label: "open Claude",
			Show:  func(s chicle.Selection) bool { return !disabled[s.Cursor.Key] },
			Run: func(s chicle.Selection) chicle.Outcome {
				return chicle.Outcome{Result: s.Cursor.Key, Done: true}
			},
		},
		{
			Label: "disable account",
			Show:  func(s chicle.Selection) bool { return !disabled[s.Cursor.Key] },
			Run: func(s chicle.Selection) chicle.Outcome {
				disabled[s.Cursor.Key] = true
				if err := writeDisabled(dpath, disabled); err != nil {
					delete(disabled, s.Cursor.Key)
					return chicle.Outcome{Status: "couldn't disable: " + err.Error()}
				}
				return chicle.Outcome{Status: "disabled " + s.Cursor.Key}
			},
		},
		{
			Label: "enable account",
			Show:  func(s chicle.Selection) bool { return disabled[s.Cursor.Key] },
			Run: func(s chicle.Selection) chicle.Outcome {
				delete(disabled, s.Cursor.Key)
				if err := writeDisabled(dpath, disabled); err != nil {
					disabled[s.Cursor.Key] = true
					return chicle.Outcome{Status: "couldn't enable: " + err.Error()}
				}
				return chicle.Outcome{Status: "enabled " + s.Cursor.Key}
			},
		},
	}

	initialRows, _ := buildRows()
	return chicle.Config{
		Title:   title,
		Columns: cols,
		Rows:    initialRows,
		Actions: actions,
		Reload:  buildRows,
	}
}
