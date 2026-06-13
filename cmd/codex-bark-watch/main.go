package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

type config struct {
	BarkConfigPath  string   `json:"barkConfigPath"`
	Title           string   `json:"title"`
	Message         string   `json:"message"`
	OriginalCommand string   `json:"originalCommand"`
	OriginalArgs    []string `json:"originalArgs"`
	LogPath         string   `json:"logPath"`
	SessionsRoot    string   `json:"sessionsRoot"`
	StatePath       string   `json:"statePath"`
	PollIntervalMS  int      `json:"pollIntervalMs"`
	ApprovalTitle   string   `json:"approvalTitle"`
	ApprovalMessage string   `json:"approvalMessage"`
}

type barkConfig struct {
	BaseURL  string `json:"baseUrl"`
	Token    string `json:"token"`
	Method   string `json:"method"`
	URL      string `json:"url"`
	IsSecure int    `json:"issecure"`
	Sender   string `json:"sender"`
}

func main() {
	if err := run(); err != nil {
		logBestEffort("", "fatal: "+err.Error())
	}
	os.Exit(0)
}

func run() error {
	exe, err := os.Executable()
	if err != nil {
		return err
	}

	mode := "notify"
	args := os.Args[1:]
	if len(args) > 0 && !strings.HasSuffix(strings.ToLower(args[0]), ".json") {
		mode = args[0]
		args = args[1:]
	}

	configPath := filepath.Join(filepath.Dir(exe), "codex-bark-watch.json")
	if len(args) > 0 && strings.TrimSpace(args[0]) != "" {
		configPath = args[0]
	}

	cfg, err := readConfig(configPath)
	if err != nil {
		return err
	}

	if mode == "watch-approvals" {
		return watchApprovals(cfg)
	}

	input, _ := io.ReadAll(os.Stdin)
	if err := sendBark(cfg); err != nil {
		logBestEffort(cfg.LogPath, "bark failed: "+err.Error())
	} else {
		logBestEffort(cfg.LogPath, "bark sent")
	}

	if len(bytes.TrimSpace(input)) == 0 || cfg.OriginalCommand == "" {
		logBestEffort(cfg.LogPath, "original skipped")
		return nil
	}

	cmd := exec.Command(cfg.OriginalCommand, cfg.OriginalArgs...)
	cmd.Stdin = bytes.NewReader(input)
	output, err := cmd.CombinedOutput()
	if err != nil {
		logBestEffort(cfg.LogPath, fmt.Sprintf("original failed: %v output=%s", err, limit(string(output), 400)))
		return nil
	}
	logBestEffort(cfg.LogPath, "original invoked")
	return nil
}

func readConfig(path string) (config, error) {
	var cfg config
	data, err := os.ReadFile(path)
	if err != nil {
		return cfg, err
	}
	data = bytes.TrimPrefix(data, []byte{0xEF, 0xBB, 0xBF})
	if err := json.Unmarshal(data, &cfg); err != nil {
		return cfg, err
	}
	if cfg.LogPath == "" {
		cfg.LogPath = filepath.Join(filepath.Dir(path), "codex-bark-watch.log")
	}
	if cfg.Title == "" {
		cfg.Title = "Codex turn complete"
	}
	if cfg.Message == "" {
		cfg.Message = "The current Codex turn has ended."
	}
	if cfg.PollIntervalMS <= 0 {
		cfg.PollIntervalMS = 1500
	}
	return cfg, nil
}

func sendBark(cfg config) error {
	data, err := os.ReadFile(cfg.BarkConfigPath)
	if err != nil {
		return err
	}
	data = bytes.TrimPrefix(data, []byte{0xEF, 0xBB, 0xBF})

	var bark barkConfig
	if err := json.Unmarshal(data, &bark); err != nil {
		return err
	}
	if bark.BaseURL == "" || bark.Token == "" {
		return fmt.Errorf("missing bark baseUrl or token")
	}
	if bark.Sender == "" {
		bark.Sender = "Codex Bark Watch"
	}
	if bark.Method == "" {
		bark.Method = "POST"
	}
	if !strings.EqualFold(bark.Method, "POST") {
		return fmt.Errorf("unsupported bark method: %s", bark.Method)
	}

	payload := map[string]any{
		"token":    bark.Token,
		"title":    cfg.Title,
		"msg":      cfg.Message,
		"url":      bark.URL,
		"issecure": bark.IsSecure,
		"sender":   bark.Sender,
	}
	body, err := json.Marshal(payload)
	if err != nil {
		return err
	}

	client := http.Client{Timeout: 12 * time.Second}
	resp, err := client.Post(bark.BaseURL, "application/json", bytes.NewReader(body))
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	respBody, _ := io.ReadAll(io.LimitReader(resp.Body, 1024))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("http %d: %s", resp.StatusCode, limit(string(respBody), 300))
	}
	logBestEffort(cfg.LogPath, "bark response: "+limit(string(respBody), 300))
	return nil
}

func sendBarkMessage(cfg config, title, message string) error {
	cfg.Title = title
	cfg.Message = message
	return sendBark(cfg)
}

type approvalState struct {
	Files map[string]int64 `json:"files"`
	Sent  map[string]bool  `json:"sent"`
}

type sessionEvent struct {
	Timestamp string          `json:"timestamp"`
	Type      string          `json:"type"`
	Payload   json.RawMessage `json:"payload"`
}

type responsePayload struct {
	Type      string `json:"type"`
	Name      string `json:"name"`
	Arguments string `json:"arguments"`
	CallID    string `json:"call_id"`
}

type shellArgs struct {
	Command            string `json:"command"`
	Justification      string `json:"justification"`
	SandboxPermissions string `json:"sandbox_permissions"`
}

func watchApprovals(cfg config) error {
	if cfg.SessionsRoot == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return err
		}
		cfg.SessionsRoot = filepath.Join(home, ".codex", "sessions")
	}
	if cfg.StatePath == "" {
		cfg.StatePath = filepath.Join(filepath.Dir(cfg.LogPath), "approval-watcher-state.json")
	}

	state := loadApprovalState(cfg.StatePath)
	if state.Files == nil {
		state.Files = map[string]int64{}
	}
	if state.Sent == nil {
		state.Sent = map[string]bool{}
	}

	logBestEffort(cfg.LogPath, "approval watcher started sessionsRoot="+cfg.SessionsRoot)
	ticker := time.NewTicker(time.Duration(cfg.PollIntervalMS) * time.Millisecond)
	defer ticker.Stop()
	for {
		if err := scanApprovalSessions(cfg, state); err != nil {
			logBestEffort(cfg.LogPath, "approval scan failed: "+err.Error())
		}
		saveApprovalState(cfg.StatePath, state)
		<-ticker.C
	}
}

func loadApprovalState(path string) approvalState {
	var state approvalState
	data, err := os.ReadFile(path)
	if err != nil {
		return state
	}
	data = bytes.TrimPrefix(data, []byte{0xEF, 0xBB, 0xBF})
	_ = json.Unmarshal(data, &state)
	return state
}

func saveApprovalState(path string, state approvalState) {
	data, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		return
	}
	_ = os.MkdirAll(filepath.Dir(path), 0o755)
	_ = os.WriteFile(path, append(data, '\n'), 0o644)
}

func scanApprovalSessions(cfg config, state approvalState) error {
	candidates, err := recentSessionFiles(cfg.SessionsRoot, 20)
	if err != nil {
		return err
	}
	for _, path := range candidates {
		if err := scanApprovalFile(cfg, state, path); err != nil {
			logBestEffort(cfg.LogPath, "approval file scan failed path="+path+" error="+err.Error())
		}
	}
	return nil
}

func recentSessionFiles(root string, maxFiles int) ([]string, error) {
	type fileInfo struct {
		path    string
		modTime time.Time
	}
	var files []fileInfo
	err := filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() || !strings.HasSuffix(strings.ToLower(path), ".jsonl") {
			return nil
		}
		info, err := d.Info()
		if err != nil {
			return nil
		}
		files = append(files, fileInfo{path: path, modTime: info.ModTime()})
		return nil
	})
	if err != nil {
		return nil, err
	}
	sort.Slice(files, func(i, j int) bool { return files[i].modTime.After(files[j].modTime) })
	if len(files) > maxFiles {
		files = files[:maxFiles]
	}
	paths := make([]string, 0, len(files))
	for _, file := range files {
		paths = append(paths, file.path)
	}
	return paths, nil
}

func scanApprovalFile(cfg config, state approvalState, path string) error {
	file, err := os.Open(path)
	if err != nil {
		return err
	}
	defer file.Close()

	info, err := file.Stat()
	if err != nil {
		return err
	}
	offset, seen := state.Files[path]
	if offset > info.Size() {
		offset = 0
	}
	if !seen {
		state.Files[path] = info.Size()
		return nil
	}
	if _, err := file.Seek(offset, io.SeekStart); err != nil {
		return err
	}
	data, err := io.ReadAll(file)
	if err != nil {
		return err
	}
	state.Files[path] = info.Size()
	for _, line := range bytes.Split(data, []byte{'\n'}) {
		line = bytes.TrimSpace(line)
		if len(line) > 0 {
			handleApprovalLine(cfg, state, line)
		}
	}
	return nil
}

func handleApprovalLine(cfg config, state approvalState, line []byte) {
	var event sessionEvent
	if err := json.Unmarshal(line, &event); err != nil || event.Type != "response_item" {
		return
	}
	var payload responsePayload
	if err := json.Unmarshal(event.Payload, &payload); err != nil {
		return
	}
	if payload.Type != "function_call" || payload.Name != "shell_command" || payload.Arguments == "" {
		return
	}
	var args shellArgs
	if err := json.Unmarshal([]byte(payload.Arguments), &args); err != nil {
		return
	}
	if args.SandboxPermissions != "require_escalated" {
		return
	}

	key := payload.CallID
	if key == "" {
		key = event.Timestamp + ":" + limit(args.Command, 120)
	}
	if state.Sent[key] {
		return
	}

	title := cfg.ApprovalTitle
	if strings.TrimSpace(title) == "" {
		title = "Codex approval needed"
	}
	message := cfg.ApprovalMessage
	if strings.TrimSpace(message) == "" {
		message = args.Justification
		if strings.TrimSpace(message) == "" {
			message = "Codex is waiting for permission approval."
		}
		if strings.TrimSpace(args.Command) != "" {
			message += "\nCommand: " + limit(args.Command, 220)
		}
	}

	if err := sendBarkMessage(cfg, title, message); err != nil {
		logBestEffort(cfg.LogPath, "approval bark failed callID="+key+" error="+err.Error())
		return
	}
	state.Sent[key] = true
	logBestEffort(cfg.LogPath, "approval bark sent callID="+key)
}

func logBestEffort(path, message string) {
	if path == "" {
		exe, err := os.Executable()
		if err == nil {
			path = filepath.Join(filepath.Dir(exe), "codex-bark-watch.log")
		}
	}
	if path == "" {
		return
	}
	_ = os.MkdirAll(filepath.Dir(path), 0o755)
	line := fmt.Sprintf("[%s] %s\n", time.Now().Format("2006-01-02 15:04:05"), message)
	file, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return
	}
	defer file.Close()
	_, _ = file.WriteString(line)
}

func limit(value string, max int) string {
	value = strings.TrimSpace(value)
	if max <= 0 {
		return ""
	}
	runes := []rune(value)
	if len(runes) <= max {
		return value
	}
	return string(runes[:max]) + "..."
}
