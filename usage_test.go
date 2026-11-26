package main

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func share(fetched time.Time, email string, five float64) string {
	return fmt.Sprintf(`{"fetched_at": %f, "accounts": [{"account_email": %q, "five_hour_usage": %v, "weekly_usage": 1}]}`,
		float64(fetched.UnixNano())/1e9, email, five)
}

func serve(t *testing.T, body string, hits *int) string {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		*hits++
		fmt.Fprint(w, body)
	}))
	t.Cleanup(srv.Close)
	return srv.URL
}

func TestParseShare(t *testing.T) {
	now := time.Now()
	if m, ok := parseShare([]byte(share(now.Add(-time.Minute), "a@x", 10)), now); !ok || *m["a@x"].Five != 10 {
		t.Fatalf("fresh share: ok=%v m=%v", ok, m)
	}
	for name, body := range map[string]string{
		"stale":   share(now.Add(-16*time.Minute), "a@x", 10),
		"future":  share(now.Add(5*time.Minute), "a@x", 10),
		"garbage": "nope",
		"empty":   fmt.Sprintf(`{"fetched_at": %d, "accounts": []}`, now.Unix()),
		"no time": `{"accounts": [{"account_email": "a@x"}]}`,
	} {
		if _, ok := parseShare([]byte(body), now); ok {
			t.Errorf("%s: want unusable", name)
		}
	}
}

func TestUsageSourcesOrder(t *testing.T) {
	now := time.Now()
	var localHits, webHits int
	web := serve(t, `[{"account_email": "a@x", "five_hour_usage": 30, "weekly_usage": 1}]`, &webHits)
	cache := filepath.Join(t.TempDir(), "usage.json")
	down := "http://127.0.0.1:1/" // nothing listens on port 1

	five := func(m map[string]usageRow) float64 { return *m["a@x"].Five }

	// The running app wins, and the web isn't asked.
	local := serve(t, share(now, "a@x", 10), &localHits)
	os.WriteFile(cache, []byte(share(now, "a@x", 20)), 0o644)
	if got := five(usageSources{local, cache, web}.load(now)); got != 10 || webHits != 0 {
		t.Fatalf("app up: got %v from usage, web hits %d", got, webHits)
	}

	// App down: the cache file.
	if got := five(usageSources{down, cache, web}.load(now)); got != 20 || webHits != 0 {
		t.Fatalf("app down: got %v, web hits %d", got, webHits)
	}

	// App up but its poll is stale (offline): the cache, still fresh, beats it.
	stale := serve(t, share(now.Add(-time.Hour), "a@x", 10), &localHits)
	if got := five(usageSources{stale, cache, web}.load(now)); got != 20 {
		t.Fatalf("stale app: got %v", got)
	}

	// Both local copies stale: the web.
	os.WriteFile(cache, []byte(share(now.Add(-time.Hour), "a@x", 20)), 0o644)
	if got := five(usageSources{stale, cache, web}.load(now)); got != 30 || webHits != 1 {
		t.Fatalf("all stale: got %v, web hits %d", got, webHits)
	}

	// No cache file at all, app down: the web.
	if got := five(usageSources{down, filepath.Join(t.TempDir(), "missing"), web}.load(now)); got != 30 {
		t.Fatalf("nothing local: got %v", got)
	}
}
