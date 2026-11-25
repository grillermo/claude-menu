package main

import (
	"path/filepath"
	"reflect"
	"testing"
)

func f(v float64) *float64 { return &v }

func TestPct(t *testing.T) {
	cases := []struct {
		in   *float64
		want string
	}{
		{nil, "--"},
		{f(0), "0%"},
		{f(6), "6%"},
		{f(99.9), "99%"}, // floor
		{f(100), "100%"},
	}
	for _, c := range cases {
		if got := pct(c.in); got != c.want {
			t.Errorf("pct(%v) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestMaxed(t *testing.T) {
	cases := []struct {
		a    account
		want bool
	}{
		{account{Five: f(50), Weekly: f(50)}, false},
		{account{Five: f(100), Weekly: f(10)}, true},
		{account{Five: f(10), Weekly: f(100)}, true},
		{account{Five: nil, Weekly: nil}, false}, // unknown is not maxed
		{account{Five: f(100)}, true},
	}
	for i, c := range cases {
		if got := c.a.maxed(); got != c.want {
			t.Errorf("case %d: maxed() = %v, want %v", i, got, c.want)
		}
	}
}

func TestBest(t *testing.T) {
	accts := []account{
		{Email: "a", Five: f(28), Weekly: f(41)},
		{Email: "b", Five: f(8), Weekly: f(40)},                // lowest 5h → winner
		{Email: "c", Five: f(0), Weekly: f(0), Disabled: true}, // skipped: disabled
	}
	if got := best(accts); got != "b" {
		t.Errorf("best() = %q, want b", got)
	}

	// Tie on 5h: lowest 7d wins.
	tie := []account{
		{Email: "x", Five: f(10), Weekly: f(60)},
		{Email: "y", Five: f(10), Weekly: f(30)},
	}
	if got := best(tie); got != "y" {
		t.Errorf("best(tie) = %q, want y", got)
	}

	// Maxed and unknown-usage accounts don't qualify.
	none := []account{
		{Email: "m", Five: f(100), Weekly: f(10)},
		{Email: "u", Five: nil, Weekly: nil},
	}
	if got := best(none); got != "" {
		t.Errorf("best(none) = %q, want empty", got)
	}
}

func TestMenuRowsSectionsAndOrder(t *testing.T) {
	accts := []account{
		{Email: "a", Five: f(28), Weekly: f(41)},
		{Email: "b", Five: f(8), Weekly: f(40)}, // most headroom → floated first
		{Email: "d", Disabled: true},
	}
	rows := menuRows(accts)
	if len(rows) != 3 {
		t.Fatalf("got %d rows, want 3", len(rows))
	}
	if rows[0].Key != "b" {
		t.Errorf("row[0] = %q, want b (floated to top)", rows[0].Key)
	}
	if rows[0].Section != "Accounts" || rows[2].Section != "Disabled" {
		t.Errorf("sections = %q/%q, want Accounts/Disabled", rows[0].Section, rows[2].Section)
	}
	if rows[2].Key != "d" {
		t.Errorf("disabled row = %q, want d", rows[2].Key)
	}
}

func TestMenuRowsSingleSectionWhenNoneDisabled(t *testing.T) {
	rows := menuRows([]account{
		{Email: "a", Five: f(10), Weekly: f(10)},
		{Email: "b", Five: f(20), Weekly: f(20)},
	})
	for _, r := range rows {
		if r.Section != "Accounts" {
			t.Errorf("section = %q, want all Accounts (so chicle draws no heading)", r.Section)
		}
	}
}

func TestDisabledRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "nested", "disabled")

	// Missing file reads as empty.
	if got := readDisabled(path); len(got) != 0 {
		t.Errorf("readDisabled(missing) = %v, want empty", got)
	}

	set := map[string]bool{"hola@grillermo.com": true, "x@y.com": true}
	if err := writeDisabled(path, set); err != nil {
		t.Fatalf("writeDisabled: %v", err)
	}
	got := readDisabled(path)
	if !reflect.DeepEqual(got, set) {
		t.Errorf("round trip = %v, want %v", got, set)
	}

	// Enabling the last one leaves an empty (but valid) set.
	if err := writeDisabled(path, map[string]bool{}); err != nil {
		t.Fatalf("writeDisabled(empty): %v", err)
	}
	if got := readDisabled(path); len(got) != 0 {
		t.Errorf("readDisabled after clearing = %v, want empty", got)
	}
}

func TestBuildAccounts(t *testing.T) {
	live := []string{"a", "b", "c"}
	usage := map[string]usageRow{
		"a": {Email: "a", Five: f(5), Weekly: f(10)},
		"c": {Email: "c", Five: f(50), Weekly: f(60)},
	}
	disabled := map[string]bool{"b": true}

	accts := buildAccounts(live, usage, disabled)
	if len(accts) != 3 {
		t.Fatalf("got %d accounts, want 3", len(accts))
	}
	if accts[0].Five == nil || *accts[0].Five != 5 {
		t.Errorf("a.Five = %v, want 5", accts[0].Five)
	}
	if !accts[1].Disabled {
		t.Errorf("b should be disabled")
	}
	if accts[1].Five != nil {
		t.Errorf("b has no usage, want nil Five")
	}
}
