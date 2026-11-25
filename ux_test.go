package main

// These tests drive the real chicle picker the way a user would — feeding it
// keystrokes and reading back the rendered frame (View) and the final answer
// (Result) — without a terminal. chicle's Model is terminal-free: Run() only
// adds the /dev/tty wiring, so New(cfg) + Update(key) reproduces the whole UX
// deterministically, Reload included (it runs synchronously inside Update).

import (
	"path/filepath"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/grillermo/chicle"
)

// key turns a short name into the KeyMsg chicle sees for it.
func key(name string) tea.KeyMsg {
	switch name {
	case "enter":
		return tea.KeyMsg{Type: tea.KeyEnter}
	case "tab":
		return tea.KeyMsg{Type: tea.KeyTab}
	case "down":
		return tea.KeyMsg{Type: tea.KeyDown}
	case "up":
		return tea.KeyMsg{Type: tea.KeyUp}
	default:
		return tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(name)}
	}
}

// drive feeds msgs into the model in order and returns the resulting Model.
func drive(m chicle.Model, msgs ...tea.Msg) chicle.Model {
	var tm tea.Model = m
	for _, msg := range msgs {
		tm, _ = tm.Update(msg)
	}
	return tm.(chicle.Model)
}

// a fixed set of accounts: c@x has the most headroom, so it floats to the top.
func fixtureUsage() map[string]usageRow {
	return map[string]usageRow{
		"a@x": {Email: "a@x", Five: f(10), Weekly: f(20)},
		"b@x": {Email: "b@x", Five: f(50), Weekly: f(60)},
		"c@x": {Email: "c@x", Five: f(5), Weekly: f(15)},
	}
}

func newMenu(t *testing.T, disabled map[string]bool) (chicle.Model, string) {
	t.Helper()
	dpath := filepath.Join(t.TempDir(), "disabled")
	cfg := buildConfig([]string{"a@x", "b@x", "c@x"}, fixtureUsage(), disabled, dpath, "")
	m := chicle.New(cfg)
	// A size is needed before the list has room to draw its rows.
	return drive(m, tea.WindowSizeMsg{Width: 80, Height: 24}), dpath
}

func TestUXInitialRenderAndDefault(t *testing.T) {
	m, _ := newMenu(t, map[string]bool{})
	view := m.View()

	for _, want := range []string{"ACCOUNT", "5H", "7D", "a@x", "b@x", "c@x", "open Claude", "disable account"} {
		if !strings.Contains(view, want) {
			t.Errorf("initial view missing %q\n---\n%s", want, view)
		}
	}
	// No disabled accounts → one section → chicle draws no "Disabled" heading.
	if strings.Contains(view, "Disabled") {
		t.Errorf("did not expect a Disabled heading with nothing disabled\n---\n%s", view)
	}
	// Most-headroom account is floated to the cursor's start row.
	if got := m.CursorRow().Key; got != "c@x" {
		t.Errorf("cursor starts on %q, want c@x (most headroom)", got)
	}
}

func TestUXOpenReturnsCursorAccount(t *testing.T) {
	m, _ := newMenu(t, map[string]bool{})
	// "open Claude" is the default focused action; Enter picks the cursor row.
	m = drive(m, key("enter"))
	if got := m.Result(); got != "c@x" {
		t.Errorf("Result = %q, want c@x", got)
	}
}

func TestUXDisableMovesRowAndPersists(t *testing.T) {
	m, dpath := newMenu(t, map[string]bool{})
	// Cursor starts on c@x. Tab to the "disable account" button, then run it.
	m = drive(m, key("tab"), key("enter"))

	view := m.View()
	if !strings.Contains(view, "disabled c@x") {
		t.Errorf("expected a 'disabled c@x' status line\n---\n%s", view)
	}
	if !strings.Contains(view, "Disabled") {
		t.Errorf("expected a Disabled section heading after disabling\n---\n%s", view)
	}
	// The picker stays open (no result yet) and the file now lists c@x.
	if m.Result() != "" {
		t.Errorf("Result = %q, want empty (picker still open)", m.Result())
	}
	if got := readDisabled(dpath); !got["c@x"] {
		t.Errorf("disabled file = %v, want c@x present", got)
	}
}

func TestUXEnableRestoresRow(t *testing.T) {
	// Start with c@x already disabled.
	m, dpath := newMenu(t, map[string]bool{"c@x": true})
	if got := m.View(); !strings.Contains(got, "Disabled") {
		t.Fatalf("fixture should show a Disabled section\n---\n%s", got)
	}

	// Enabled rows a@x,b@x come first (a@x best), c@x sits in Disabled at the
	// bottom. Move the cursor down onto c@x; the cursor skips the heading.
	// a@x(0) -> b@x(1) -> c@x(2).
	m = drive(m, key("down"), key("down"))
	if got := m.CursorRow().Key; got != "c@x" {
		t.Fatalf("cursor on %q, want c@x (the disabled row)", got)
	}
	// On a disabled row only "enable account" shows, so it is focused; Enter runs it.
	m = drive(m, key("enter"))

	if got := m.View(); !strings.Contains(got, "enabled c@x") {
		t.Errorf("expected an 'enabled c@x' status line\n---\n%s", got)
	}
	if got := readDisabled(dpath); got["c@x"] {
		t.Errorf("disabled file still has c@x after enabling: %v", got)
	}
}

func TestUXOpenHiddenOnDisabledRow(t *testing.T) {
	// With c@x disabled and the cursor on it, "open Claude" must be hidden so a
	// disabled account can't be launched; Enter runs "enable account" instead.
	m, _ := newMenu(t, map[string]bool{"c@x": true})
	m = drive(m, key("down"), key("down")) // onto c@x
	if got := m.CursorRow().Key; got != "c@x" {
		t.Fatalf("cursor on %q, want c@x", got)
	}
	m = drive(m, key("enter"))
	if m.Result() != "" {
		t.Errorf("Enter on a disabled row returned %q; it should enable, not open", m.Result())
	}
}
