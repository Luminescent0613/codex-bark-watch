package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
)

func TestHandleApprovalLineSendsOnce(t *testing.T) {
	var count int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&count, 1)
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"code":"ok"}`))
	}))
	defer server.Close()

	cfg := testConfig(t, server.URL)
	state := approvalState{
		Files: map[string]int64{},
		Sent:  map[string]bool{},
	}
	line := approvalJSONL(t, "call-1")

	handleApprovalLine(cfg, state, line)
	handleApprovalLine(cfg, state, line)

	if got := atomic.LoadInt32(&count); got != 1 {
		t.Fatalf("expected one Bark request, got %d", got)
	}
	if !state.Sent["call-1"] {
		t.Fatal("expected call id to be marked sent")
	}
}

func TestScanApprovalFileStartsAtEOFThenReadsAppendedLines(t *testing.T) {
	var count int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&count, 1)
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"code":"ok"}`))
	}))
	defer server.Close()

	dir := t.TempDir()
	sessionPath := filepath.Join(dir, "session.jsonl")
	if err := os.WriteFile(sessionPath, append(approvalJSONL(t, "old-call"), '\n'), 0o644); err != nil {
		t.Fatal(err)
	}

	cfg := testConfig(t, server.URL)
	state := approvalState{
		Files: map[string]int64{},
		Sent:  map[string]bool{},
	}

	if err := scanApprovalFile(cfg, state, sessionPath); err != nil {
		t.Fatal(err)
	}
	if got := atomic.LoadInt32(&count); got != 0 {
		t.Fatalf("expected existing content to be skipped, got %d requests", got)
	}

	file, err := os.OpenFile(sessionPath, os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := file.Write(append(approvalJSONL(t, "new-call"), '\n')); err != nil {
		_ = file.Close()
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}

	if err := scanApprovalFile(cfg, state, sessionPath); err != nil {
		t.Fatal(err)
	}
	if got := atomic.LoadInt32(&count); got != 1 {
		t.Fatalf("expected one appended approval request, got %d", got)
	}
	if state.Sent["old-call"] {
		t.Fatal("old call should not be replayed")
	}
	if !state.Sent["new-call"] {
		t.Fatal("new call should be marked sent")
	}
}

func TestLimitIsUnicodeSafe(t *testing.T) {
	if got := limit("abcdef", 3); got != "abc..." {
		t.Fatalf("unexpected ASCII limit: %q", got)
	}
}

func testConfig(t *testing.T, baseURL string) config {
	t.Helper()
	dir := t.TempDir()
	barkPath := filepath.Join(dir, "bark.json")
	data, err := json.Marshal(barkConfig{
		BaseURL: baseURL,
		Token:   "test-token",
		Sender:  "test",
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(barkPath, data, 0o644); err != nil {
		t.Fatal(err)
	}
	return config{
		BarkConfigPath:  barkPath,
		LogPath:         filepath.Join(dir, "test.log"),
		ApprovalTitle:   "approval",
		ApprovalMessage: "needed",
	}
}

func approvalJSONL(t *testing.T, callID string) []byte {
	t.Helper()
	args, err := json.Marshal(shellArgs{
		Command:            "go test ./...",
		Justification:      "test approval",
		SandboxPermissions: "require_escalated",
	})
	if err != nil {
		t.Fatal(err)
	}
	payload, err := json.Marshal(responsePayload{
		Type:      "function_call",
		Name:      "shell_command",
		Arguments: string(args),
		CallID:    callID,
	})
	if err != nil {
		t.Fatal(err)
	}
	event, err := json.Marshal(sessionEvent{
		Timestamp: "2026-01-01T00:00:00Z",
		Type:      "response_item",
		Payload:   payload,
	})
	if err != nil {
		t.Fatal(err)
	}
	return event
}
