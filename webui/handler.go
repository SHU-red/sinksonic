package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"gopkg.in/yaml.v3"
)

// configPath is the path to the persistent config file.
var configPath string

// --- Persistent config (sinksonic.yaml) ---

type AudioConfig struct {
	ResampleQuality  int    `yaml:"resample_quality"`
	BufferSize       int    `yaml:"buffer_size"`
	LatencyTargetMs  int    `yaml:"latency_target_ms"`
	DefaultSink      string `yaml:"default_sink"`
	MasterVolume     int    `yaml:"master_volume"`
}

type AppConfig struct {
	Audio AudioConfig `yaml:"audio"`
}

func defaultAppConfig() *AppConfig {
	return &AppConfig{
		Audio: AudioConfig{
			ResampleQuality: 14,
			BufferSize:      2048,
			LatencyTargetMs: 10,
		},
	}
}

func loadAppConfig() *AppConfig {
	content, err := os.ReadFile(configPath)
	if err != nil {
		return defaultAppConfig()
	}
	var cfg AppConfig
	if err := yaml.Unmarshal(content, &cfg); err != nil {
		log.Printf("Failed to parse config: %v, using defaults", err)
		return defaultAppConfig()
	}
	return &cfg
}

func saveAppConfig(cfg *AppConfig) error {
	// Read existing config to preserve unknown keys (frontend may have set other fields)
	existing, err := os.ReadFile(configPath)
	existingStr := string(existing)
	if err != nil {
		// File doesn't exist yet — write full struct
		fullData, marshalErr := yaml.Marshal(cfg)
		if marshalErr != nil {
			return marshalErr
		}
		return os.WriteFile(configPath, fullData, 0644)
	}

	// Normalize line endings
	existingStr = strings.NewReplacer("\r\n", "\n").Replace(existingStr)

	lines := strings.Split(existingStr, "\n")

	// Config keys we manage (key -> value)
	managedKeys := map[string]string{
		"default_sink":  cfg.Audio.DefaultSink,
		"master_volume": strconv.Itoa(cfg.Audio.MasterVolume),
	}

	// First pass: replace existing keys, preserving indentation
	for i, line := range lines {
		trimmed := strings.TrimSpace(line)
		for key, val := range managedKeys {
			if val == "" {
				continue
			}
			if strings.HasPrefix(trimmed, key+":") {
				// Preserve original indentation
				indent := ""
				for _, c := range line {
					if c == ' ' || c == '	' {
						indent += string(c)
					} else {
						break
					}
				}
				lines[i] = indent + key + ": " + val
				delete(managedKeys, key)
			}
		}
	}

	// Second pass: add remaining keys under audio: block
	if len(managedKeys) > 0 {
		audioIndex := -1
		insertAt := -1
		for i, line := range lines {
			trim := strings.TrimSpace(line)
			if trim == "audio:" {
				audioIndex = i
				insertAt = i
			} else if audioIndex >= 0 && (strings.HasPrefix(line, " ") || strings.HasPrefix(line, "	") || line == "") {
				if line != "" {
					insertAt = i
				}
			} else if audioIndex >= 0 && !strings.HasPrefix(line, " ") && !strings.HasPrefix(line, "	") && line != "" {
				insertAt = i - 1
				break
			}
		}
		if audioIndex >= 0 {
			newLines := make([]string, 0, len(lines)+len(managedKeys))
			newLines = append(newLines, lines[:insertAt+1]...)
			for key, val := range managedKeys {
				if val != "" {
					newLines = append(newLines, "    "+key+": "+val)
				}
			}
			newLines = append(newLines, lines[insertAt+1:]...)
			lines = newLines
		} else if len(managedKeys) > 0 {
			lines = append(lines, "audio:")
			for key, val := range managedKeys {
				if val != "" {
					lines = append(lines, "    "+key+": "+val)
				}
			}
		}
	}
	return os.WriteFile(configPath, []byte(strings.Join(lines, "\n")+"\n"), 0644)
}

// --- Sink types ---

type SinkInfo struct {
	ID          int    `json:"id"`
	Name        string `json:"name"`
	Description string `json:"description"`
	Active      bool   `json:"active"`
	State       string `json:"state"`
}

func init() {
	configPath = os.Getenv("CONFIG_PATH")
	if configPath == "" {
		configPath = "/data/sinksonic.yaml"
	}
	// Apply default sink from config on startup
	applyDefaultSinkFromConfig()
}

// applyDefaultSinkFromConfig reads the config and sets the default sink if configured.
func applyDefaultSinkFromConfig() {
	cfg := loadAppConfig()
	if cfg.Audio.DefaultSink == "" {
		return
	}
	// Find the node ID for this sink name from pw-dump
	sinks := parseSinksFromPwDump()
	for _, s := range sinks {
		if s.Name == cfg.Audio.DefaultSink {
			log.Printf("Applying default sink: %s (id %d)", cfg.Audio.DefaultSink, s.ID)
			runCmd(3*time.Second, "wpctl", "set-default", strconv.Itoa(s.ID))
			// Apply master volume if configured
			if cfg.Audio.MasterVolume > 0 && cfg.Audio.MasterVolume <= 255 {
				volStr := fmt.Sprintf("%.2f", float64(cfg.Audio.MasterVolume)/255.0)
				runCmd(3*time.Second, "wpctl", "set-volume", strconv.Itoa(s.ID), volStr)
			}
			return
		}
	}
	log.Printf("Default sink '%s' not found among available sinks", cfg.Audio.DefaultSink)
}

// --- Hosts management ---

type HostConfig struct {
	ID     string `json:"id"`
	Label  string `json:"label"`
	Volume int    `json:"volume"`
	Muted  bool   `json:"muted"`
}

type HostsFile struct {
	Version int          `json:"version"`
	Hosts   []HostConfig `json:"hosts"`
}

const hostsPath = "/data/hosts.json"

func loadHosts() *HostsFile {
	content, err := os.ReadFile(hostsPath)
	if err != nil {
		return &HostsFile{Version: 1, Hosts: []HostConfig{}}
	}
	var hf HostsFile
	if err := json.Unmarshal(content, &hf); err != nil {
		return &HostsFile{Version: 1, Hosts: []HostConfig{}}
	}
	if hf.Hosts == nil {
		hf.Hosts = []HostConfig{}
	}
	return &hf
}

func saveHosts(hf *HostsFile) error {
	data, err := json.MarshalIndent(hf, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(hostsPath, data, 0644)
}

func findHost(hf *HostsFile, id string) *HostConfig {
	for i := range hf.Hosts {
		if hf.Hosts[i].ID == id {
			return &hf.Hosts[i]
		}
	}
	return nil
}

func applyStreamVolume(nodeID string, hc *HostConfig) {
	volStr := fmt.Sprintf("%.2f", float64(hc.Volume)/255.0)
	runCmd(3*time.Second, "wpctl", "set-volume", nodeID, volStr)
	if hc.Muted {
		runCmd(3*time.Second, "wpctl", "set-mute", nodeID, "1")
	} else {
		runCmd(3*time.Second, "wpctl", "set-mute", nodeID, "0")
	}
}

// findPrimarySinkId returns the node ID of the first non-tunnel ALSA sink from wpctl status.
// Used for level monitoring.
func findPrimarySinkId() string {
	out, err := runCmd(3*time.Second, "wpctl", "status")
	if err != nil {
		return ""
	}
	inSinks := false
	for _, line := range strings.Split(out, "\n") {
		trimmed := strings.TrimSpace(line)
		if strings.Contains(trimmed, "Sinks:") || (strings.Contains(trimmed, "Sinks") && len(trimmed) < 20) {
			inSinks = true
			continue
		}
		if inSinks && (trimmed == "" || strings.HasPrefix(trimmed, "├─") || strings.HasPrefix(trimmed, "└─") || strings.HasPrefix(trimmed, "│")) == false {
			inSinks = false
			continue
		}
		if !inSinks || trimmed == "" {
			continue
		}
		// Skip box-drawing chars and default marker
		cleaned := strings.NewReplacer("│", "", "├", "", "└", "", "─", "", "*", "").Replace(trimmed)
		cleaned = strings.TrimSpace(cleaned)
		parts := strings.Fields(cleaned)
		if len(parts) < 2 {
			continue
		}
		nodeID := strings.TrimRight(parts[0], ".")
		if _, err := strconv.Atoi(nodeID); err != nil {
			continue
		}
		// Check if this is a tunnel sink (skip those)
		name := strings.Join(parts[1:], " ")
		if strings.Contains(name, "tunnel") || strings.Contains(name, "Tunnel") {
			continue
		}
		return nodeID
	}
	return ""
}

// --- Response types ---

type StatusResponse struct {
	Uptime          int     `json:"uptime"`
	RAMUsed         string  `json:"ram_used"`
	CPULoad         string  `json:"cpu_load"`
	Temperature     string  `json:"temperature"`
	SampleRate      int     `json:"sample_rate"`
	BufferSize      int     `json:"buffer_size"`
	LatencyMs       float64 `json:"latency_ms"`
	Channels        string  `json:"channels"`
	PipeWireRunning bool    `json:"pipewire_running"`
	Levels          []int   `json:"levels"`
}

type StreamResponse struct {
	Index       int     `json:"index"`
	Name        string  `json:"name"`
	NodeName    string  `json:"node_name"`
	NodeID      string  `json:"node_id"`
	Volume      int     `json:"volume"`
	Muted       bool    `json:"muted"`
	Connected   bool    `json:"connected"`
	HostID      string  `json:"host_id"`
	HostLabel   string  `json:"host_label"`
	Known       bool    `json:"known"`
	State       string  `json:"state"`       // "active", "idle", "corked"
	Format      string  `json:"format"`      // e.g. "s16le 2ch 48000Hz"
	Health      string  `json:"health"`      // "good", "fair", "poor"
	AppName     string  `json:"app_name"`    // application.name (e.g. "Firefox")
	HostName    string  `json:"host_name"`   // host identity (e.g. "shured@fedora")
	SampleRate  int     `json:"sample_rate"` // Hz
	Channels    int     `json:"channels"`
	AudioFormat string  `json:"audio_format"` // e.g. "S16LE", "F32"
	BitDepth    int     `json:"bit_depth"`    // bits per sample
	LatencyMs   float64 `json:"latency_ms"`
	BitrateKbps int     `json:"bitrate_kbps"`
	ResampleQ   int     `json:"resample_quality"`
}

type VolumeRequest struct {
	Index  int `json:"index"`
	Volume int `json:"volume"`
}

type MuteRequest struct {
	Index int `json:"index"`
}

// --- Utilities ---

func runCmd(timeout time.Duration, name string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, name, args...)
	out, err := cmd.CombinedOutput()
	return strings.TrimSpace(string(out)), err
}

func parseInt(s string, fallback int) int {
	v, err := strconv.Atoi(strings.TrimSpace(s))
	if err != nil {
		return fallback
	}
	return v
}

func parseFloat(s string, fallback float64) float64 {
	v, err := strconv.ParseFloat(strings.TrimSpace(s), 64)
	if err != nil {
		return fallback
	}
	return v
}

func getUptime() int {
	content, err := os.ReadFile("/proc/uptime")
	if err != nil {
		return 0
	}
	return int(parseFloat(strings.Fields(string(content))[0], 0))
}

func getRAM() string {
	content, err := os.ReadFile("/proc/meminfo")
	if err != nil {
		return "--"
	}
	var total, available int64
	for _, line := range strings.Split(string(content), "\n") {
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		val := parseInt(fields[1], 0) * 1024
		switch fields[0] {
		case "MemTotal:":
			total = int64(val)
		case "MemAvailable:":
			available = int64(val)
		}
	}
	if total == 0 {
		return "--"
	}
	usedPct := float64(total-available) / float64(total) * 100
	usedMB := (total - available) / 1024 / 1024
	totalMB := total / 1024 / 1024
	return fmt.Sprintf("%d/%d MB (%.0f%%)", usedMB, totalMB, usedPct)
}

func getCPULoad() string {
	content, err := os.ReadFile("/proc/loadavg")
	if err != nil {
		return "--"
	}
	fields := strings.Fields(string(content))
	if len(fields) < 3 {
		return "--"
	}
	return fmt.Sprintf("%.1f / %.1f / %.1f",
		parseFloat(fields[0], 0),
		parseFloat(fields[1], 0),
		parseFloat(fields[2], 0))
}

func getTemp() string {
	content, err := os.ReadFile("/sys/class/thermal/thermal_zone0/temp")
	if err != nil {
		return "--"
	}
	millideg := parseInt(string(content), 0)
	if millideg == 0 {
		return "--"
	}
	return fmt.Sprintf("%.1f °C", float64(millideg)/1000.0)
}

func getPipeWireInfo() (int, int, int) {
	sampleRate := 48000
	bufferSize := 512
	channels := 2

	// Get real buffer size from pw-metadata settings
	metaOut, metaErr := runCmd(3*time.Second, "pw-metadata", "-n", "settings")
	if metaErr == nil {
		for _, line := range strings.Split(metaOut, "\n") {
			// format: "update: id:0 key:'clock.rate' value:'48000' type:''"
			if strings.Contains(line, "clock.rate") {
				if v := extractMetaValue(line); v != "" {
					if r := parseInt(v, 0); r > 0 {
						sampleRate = r
					}
				}
			}
			if strings.Contains(line, "clock.force-quantum") {
				if v := extractMetaValue(line); v != "" {
					if b := parseInt(v, 0); b > 0 {
						bufferSize = b
					}
				}
			}
			if strings.Contains(line, "clock.quantum") && !strings.Contains(line, "force") && !strings.Contains(line, "min") && !strings.Contains(line, "max") {
				if v := extractMetaValue(line); v != "" {
					if b := parseInt(v, 0); b > 0 && bufferSize == 512 {
						// Only use if force-quantum wasn't set
						bufferSize = b
					}
				}
			}
		}
	}

	// Get channels from the first active sink
	out, err := runCmd(5*time.Second, "pactl", "list", "sinks")
	if err == nil {
		for _, line := range strings.Split(out, "\n") {
			t := strings.TrimSpace(line)
			if strings.Contains(t, "Sample Specification") {
				parts := strings.Fields(t)
				for _, p := range parts {
					if strings.HasSuffix(p, "ch") && len(p) > 2 {
						channels = parseInt(p[:len(p)-2], 2)
					}
				}
			}
		}
	}

	return sampleRate, bufferSize, channels
}

// extractMetaValue extracts the value from pw-metadata output line
// Input: "update: id:0 key:'clock.rate' value:'48000' type:''"
// Output: "48000"
func extractMetaValue(line string) string {
	// Match value:'...' or value:"..."
	start := strings.Index(line, "value:'")
	if start < 0 {
		start = strings.Index(line, `value:"`)
		if start < 0 {
			return ""
		}
		start += 7
		end := strings.Index(line[start:], `"`)
		if end < 0 {
			return ""
		}
		return line[start : start+end]
	}
	start += 7
	end := strings.Index(line[start:], "'")
	if end < 0 {
		return ""
	}
	return line[start : start+end]
}

func isPipeWireRunning() bool {
	out, err := runCmd(3*time.Second, "pw-cli", "info", "all")
	if err != nil {
		// Fallback: check via pactl in case pw-cli isn't in PATH
		_, err2 := runCmd(2*time.Second, "pactl", "-s", os.Getenv("XDG_RUNTIME_DIR")+"/pulse/native", "info")
		return err2 == nil
	}
	// pw-cli info all output: type: PipeWire:Interface:Core/4, name: "pipewire-0"
	return strings.Contains(out, "PipeWire:Interface:Core") || strings.Contains(out, "host-name:")
}

// --- Stream parsing ---

// getStreamNodeInfo calls pw-dump once and returns a map of nodeID -> node info
// This replaces N individual wpctl inspect calls with one fast JSON call.
type streamNodeInfo struct {
	nodeName     string
	state        string
	sinkFormat   string // combined format from ALSA sink, e.g. "S16LE 2ch 48000Hz"
	appName      string // application.name (e.g. "Firefox")
	hostName     string // host identifier (e.g. "shured@fedora")
	sampleRate   int    // Hz
	channels     int
	audioFormat  string // e.g. "S16LE", "F32"
	bitDepth     int    // bits per sample
	latencyMs    float64
	bufferFrames int
	bitrateKbps  int
	resampleQ    int
}

func getStreamNodeInfo() map[string]streamNodeInfo {
	dump, err := runCmd(5*time.Second, "pw-dump")
	if err != nil {
		return nil
	}

	var objects []struct {
		ID   int    `json:"id"`
		Type string `json:"type"`
		Info *struct {
			Props  map[string]interface{}            `json:"props"`
			Params map[string]interface{}            `json:"params"`
		} `json:"info"`
	}
	if err := json.Unmarshal([]byte(dump), &objects); err != nil {
		return nil
	}

	result := make(map[string]streamNodeInfo)
	for _, obj := range objects {
		if obj.Info == nil || obj.Info.Props == nil {
			continue
		}
		props := obj.Info.Props

		// Only audio stream nodes (sink-inputs from remote clients)
		mediaClass, _ := props["media.class"].(string)
		if !strings.Contains(mediaClass, "Stream/Output/Audio") {
			continue
		}

		nodeID := strconv.Itoa(obj.ID)
		info := streamNodeInfo{}

		if n, ok := props["node.name"].(string); ok {
			info.nodeName = n
		}
		if info.nodeName == "" {
			if n, ok := props["application.name"].(string); ok {
				info.nodeName = n
			}
		}

		// Extract application name for display
		if a, ok := props["application.name"].(string); ok {
			info.appName = a
		}
		if info.appName == "" {
			if n, ok := props["media.name"].(string); ok {
				info.appName = n
			}
		}

		// Extract host identity from media.name or application.process.host/user
		if mn, ok := props["media.name"].(string); ok && strings.Contains(mn, "Tunnel for ") {
			// "Tunnel for shured@fedora" → "shured@fedora"
			info.hostName = strings.TrimPrefix(mn, "Tunnel for ")
		}
		if info.hostName == "" {
			host, _ := props["application.process.host"].(string)
			user, _ := props["application.process.user"].(string)
			if host != "" && user != "" {
				info.hostName = user + "@" + host
			} else if host != "" {
				info.hostName = host
			} else {
				// Fallback: use a shortened node name as host identity
				info.hostName = info.nodeName
			}
		}

		// --- Quality metrics ---
		// Extract audio format from params.Format (negotiated format)
		if obj.Info.Params != nil {
			if formatList, ok := obj.Info.Params["Format"].([]interface{}); ok && len(formatList) > 0 {
				if fmtMap, ok := formatList[0].(map[string]interface{}); ok {
					if f, ok := fmtMap["format"].(string); ok {
						info.audioFormat = f
					}
					if r, ok := fmtMap["rate"].(float64); ok {
						info.sampleRate = int(r)
					}
					if c, ok := fmtMap["channels"].(float64); ok {
						info.channels = int(c)
					}
				}
			}
			// Fallback: try EnumFormat (same structure)
			if info.sampleRate == 0 {
				if efList, ok := obj.Info.Params["EnumFormat"].([]interface{}); ok && len(efList) > 0 {
					if efMap, ok := efList[0].(map[string]interface{}); ok {
						if r, ok := efMap["rate"].(float64); ok {
							info.sampleRate = int(r)
						}
						if c, ok := efMap["channels"].(float64); ok {
							info.channels = int(c)
						}
					}
				}
			}
		}

		// Also check props for format info
		if info.sampleRate == 0 || info.channels == 0 {
			if nr, ok := props["node.rate"].(string); ok {
				parts := strings.Split(nr, "/")
				if len(parts) == 2 {
					info.sampleRate = parseInt(parts[1], 0)
				}
			}
			if c, ok := props["audio.channels"].(float64); ok && info.channels == 0 {
				info.channels = int(c)
			}
		}

		// Bit depth from format string: S16LE=16, S24=24, S32=32, F32=32, F64=64
		if info.audioFormat != "" {
			f := strings.ToUpper(info.audioFormat)
			if strings.Contains(f, "F64") {
				info.bitDepth = 64
			} else if strings.Contains(f, "F32") || strings.Contains(f, "FLOAT") {
				info.bitDepth = 32
			} else if strings.Contains(f, "S32") || strings.Contains(f, "U32") {
				info.bitDepth = 32
			} else if strings.Contains(f, "S24") || strings.Contains(f, "U24") {
				info.bitDepth = 24
			} else if strings.Contains(f, "S16") || strings.Contains(f, "U16") {
				info.bitDepth = 16
			} else if strings.Contains(f, "S8") || strings.Contains(f, "U8") {
				info.bitDepth = 8
			}
		}
		if info.bitDepth == 0 {
			info.bitDepth = 16 // safe default
		}

		// Calculate bitrate: sampleRate * bitDepth * channels
		if info.sampleRate > 0 && info.bitDepth > 0 && info.channels > 0 {
			info.bitrateKbps = info.sampleRate * info.bitDepth * info.channels / 1000
		}

		// Latency from node.latency prop ("1200/48000" = 25ms)
		if latStr, ok := props["node.latency"].(string); ok {
			parts := strings.Split(latStr, "/")
			if len(parts) == 2 {
				frames := parseFloat(parts[0], 0)
				rate := parseFloat(parts[1], 48000)
				if rate > 0 {
					info.latencyMs = frames / rate * 1000
				}
			}
		}

		// Resample quality from props
		if rq, ok := props["resample.quality"].(float64); ok {
			info.resampleQ = int(rq)
		}

		// State: pulse.corked = false → running, true → corked
		if corked, ok := props["pulse.corked"].(bool); ok {
			if !corked {
				info.state = "running"
			} else {
				info.state = "corked"
			}
		} else {
			info.state = "unknown"
		}

		result[nodeID] = info
	}

	// Also check the ALSA sink for audio format info
	for _, obj := range objects {
		if obj.Info == nil || obj.Info.Props == nil {
			continue
		}
		props := obj.Info.Props
		mediaClass, _ := props["media.class"].(string)
		if mediaClass != "Audio/Sink" {
			continue
		}
		// Found the audio sink — extract format if available
		formatStr := ""
		if f, ok := props["audio.format"].(string); ok && f != "" {
			formatStr = f
		}
		if c, ok := props["audio.channels"].(float64); ok && c > 0 {
			if formatStr != "" {
				formatStr += fmt.Sprintf(" %.0fch", c)
			} else {
				formatStr = fmt.Sprintf("%.0fch", c)
			}
		}
		if r, ok := props["audio.rate"].(float64); ok && r > 0 {
			if formatStr != "" {
				formatStr += fmt.Sprintf(" %.0fHz", r)
			} else {
				formatStr = fmt.Sprintf("%.0fHz", r)
			}
		}
		// If we found sink format, apply to all stream nodes
		if formatStr != "" {
			for id := range result {
				entry := result[id]
				entry.sinkFormat = formatStr
				result[id] = entry
			}
		}
		break
	}

	return result
}

func parseWpctlStatus() []StreamResponse {
	out, err := runCmd(5*time.Second, "wpctl", "status")
	if err != nil {
		return nil
	}

	// One pw-dump call instead of N wpctl inspect calls
	nodeInfo := getStreamNodeInfo()

	hf := loadHosts()
	var streams []StreamResponse
	idx := 0
	inStreams := false

	for _, line := range strings.Split(out, "\n") {
		trimmed := strings.TrimSpace(line)

		// Detect Streams section (incoming audio streams/sink-inputs)
		if strings.Contains(trimmed, "Streams:") || (strings.Contains(trimmed, "Streams") && len(trimmed) < 20 && !strings.Contains(trimmed, "│  ")) {
			inStreams = true
			continue
		}
		// End of Streams section: blank line or next section header
		if inStreams && (trimmed == "" || strings.HasPrefix(trimmed, "Video") || strings.HasPrefix(trimmed, "Settings") || strings.HasPrefix(trimmed, "Audio") || strings.HasPrefix(trimmed, "├─") && !strings.Contains(trimmed, "│")) {
			inStreams = false
			continue
		}

		if !inStreams {
			continue
		}

		// Skip channel connection lines (contain ">")
		if strings.Contains(trimmed, ">") {
			continue
		}

		// Skip empty and box-drawing-only lines
		if trimmed == "" || trimmed == "│" {
			continue
		}

		// Parse: "│      NN. Name" or "│      NN. Name  [vol: X.XX]"
		cleaned := strings.NewReplacer("│", "").Replace(trimmed)
		cleaned = strings.TrimSpace(cleaned)
		parts := strings.Fields(cleaned)
		if len(parts) < 2 {
			continue
		}

		// First field should be NN. (number with trailing dot)
		nodeID := strings.TrimRight(parts[0], ".")
		if _, err := strconv.Atoi(nodeID); err != nil {
			continue
		}

		// Collect name (everything after node ID, before [vol: ...])
		var nameParts []string
		for _, p := range parts[1:] {
			if strings.HasPrefix(p, "[vol:") || strings.HasPrefix(p, "[") {
				break
			}
			nameParts = append(nameParts, p)
		}
		name := strings.Join(nameParts, " ")
		if name == "" {
			continue
		}

		// Get volume via wpctl get-volume
		volume := 128
		muted := false
		volOut, volErr := runCmd(3*time.Second, "wpctl", "get-volume", nodeID)
		if volErr == nil {
			volParts := strings.Fields(volOut)
			if len(volParts) >= 2 {
				v := parseFloat(volParts[1], 0.5)
				volume = int(v * 255)
				if volume > 255 {
					volume = 255
				}
			}
			// Check for [MUTED] suffix
			if strings.Contains(volOut, "MUTED") || strings.Contains(volOut, "[MUTED]") {
				muted = true
			}
		}

		// Look up node info from pw-dump (fast, one call instead of N)
		ni := nodeInfo[nodeID]
		nodeName := ni.nodeName
		state := ni.state
		formatStr := ni.sinkFormat  // combined format from ALSA sink
		appName := ni.appName
		hostName := ni.hostName
		if nodeName == "" {
			nodeName = name
		}
		if state == "" {
			state = "unknown"
		}

		// Compute health from node state
		// PipeWire node states derived from pulse.corked:
		//   running/active  = audio flowing normally     → good
		//   idle/suspended  = connected but silent       → fair
		//   corked/unknown  = disconnected or paused     → poor
		health := "good"
		switch state {
		case "running", "active":
			health = "good"
		case "idle", "suspended":
			health = "fair"
		default:
			health = "poor"
		}

		// Friendly state label
		friendlyState := state
		if state == "running" {
			friendlyState = "active"
		}

		// Use the real host identity for grouping
		// hostID is the stable host key (e.g. "shured@fedora")
		// hostLabel is the display name
		hostID := hostName
		if hostID == "" {
			hostID = nodeName
		}
		hostLabel := hostName
		if hostLabel == "" {
			hostLabel = name
		}
		known := false
		if hc := findHost(hf, hostID); hc != nil {
			hostLabel = hc.Label
			known = true
			// Apply stored settings for this stream
			applyStreamVolume(nodeID, hc)
			volume = hc.Volume
			muted = hc.Muted
		}

		// Build a display name from the application name
		displayName := name
		if appName != "" && appName != "PipeWire" {
			displayName = appName
		}

		streams = append(streams, StreamResponse{
			Index:       idx,
			Name:        displayName,
			NodeName:    nodeName,
			NodeID:      nodeID,
			Volume:      volume,
			Muted:       muted,
			Connected:   true,
			HostID:      hostID,
			HostLabel:   hostLabel,
			Known:       known,
			State:       friendlyState,
			Format:      formatStr,
			Health:      health,
			AppName:     appName,
			HostName:    hostName,
			SampleRate:  ni.sampleRate,
			Channels:    ni.channels,
			AudioFormat: ni.audioFormat,
			BitDepth:    ni.bitDepth,
			LatencyMs:   ni.latencyMs,
			BitrateKbps: ni.bitrateKbps,
			ResampleQ:   ni.resampleQ,
		})
		idx++
	}

	return streams
}

// parseSinksFromPwDump returns all Audio/Sink nodes from pw-dump.
// This is used for the sink selection dropdown in the web UI.
func parseSinksFromPwDump() []SinkInfo {
	dump, err := runCmd(5*time.Second, "pw-dump")
	if err != nil {
		return nil
	}

	var objects []struct {
		ID   int    `json:"id"`
		Type string `json:"type"`
		Info *struct {
			Props map[string]interface{} `json:"props"`
		} `json:"info"`
	}
	if err := json.Unmarshal([]byte(dump), &objects); err != nil {
		return nil
	}

	// Get the current default sink node ID from wpctl status
	currentDefault := getDefaultSinkID()

	var sinks []SinkInfo
	for _, obj := range objects {
		if obj.Info == nil || obj.Info.Props == nil {
			continue
		}
		props := obj.Info.Props

		mediaClass, _ := props["media.class"].(string)
		if mediaClass != "Audio/Sink" {
			continue
		}

		info := SinkInfo{
			ID: obj.ID,
		}

		if n, ok := props["node.name"].(string); ok {
			info.Name = n
		}
		if d, ok := props["node.nick"].(string); ok {
			info.Description = d
		}
		if info.Description == "" {
			if d, ok := props["node.description"].(string); ok {
				info.Description = d
			}
		}
		if info.Description == "" {
			info.Description = info.Name
		}

		if s, ok := props["state"].(string); ok {
			info.State = s
		}

		nodeIDStr := strconv.Itoa(obj.ID)
		info.Active = nodeIDStr == currentDefault || info.Name == currentDefault

		sinks = append(sinks, info)
	}
	return sinks
}

// getDefaultSinkID returns the node ID of the current default sink from wpctl status.
func getDefaultSinkID() string {
	out, err := runCmd(3*time.Second, "wpctl", "status")
	if err != nil {
		return ""
	}
	// Look for the line with the asterisk (*) under Sinks section
	inSinks := false
	for _, line := range strings.Split(out, "\n") {
		trimmed := strings.TrimSpace(line)
		if strings.Contains(trimmed, "Sinks:") || (strings.Contains(trimmed, "Sinks") && len(trimmed) < 20) {
			inSinks = true
			continue
		}
		if inSinks && (trimmed == "" || strings.HasPrefix(trimmed, "├─") || strings.HasPrefix(trimmed, "└─") || strings.HasPrefix(trimmed, "│")) == false {
			inSinks = false
			continue
		}
		if !inSinks {
			continue
		}
		// Look for default marker *
		if strings.Contains(trimmed, "*") {
			cleaned := strings.NewReplacer("│", "", "├", "", "└", "", "─", "", "*", "").Replace(trimmed)
			cleaned = strings.TrimSpace(cleaned)
			parts := strings.Fields(cleaned)
			if len(parts) >= 1 {
				return strings.TrimRight(parts[0], ".")
			}
		}
	}
	// Fallback: try pactl info
	out2, err2 := runCmd(3*time.Second, "pactl", "info")
	if err2 == nil {
		for _, line := range strings.Split(out2, "\n") {
			if strings.Contains(line, "Default Sink:") {
				parts := strings.Split(line, ":")
				if len(parts) >= 2 {
					return strings.TrimSpace(parts[1])
				}
			}
		}
	}
	return ""
}

// moveStreamsToSink moves all active stream (sink-input) outputs
// to the specified sink using pw-link. This ensures existing audio
// streams are re-routed when the default sink changes.
func moveStreamsToSink(sinkName string) {
	// Get list of output ports (streams)
	out, err := runCmd(3*time.Second, "pw-link", "-o")
	if err != nil {
		log.Printf("moveStreamsToSink: pw-link -o failed: %v", err)
		return
	}

	// Get list of input ports on the target sink
	inOut, inErr := runCmd(3*time.Second, "pw-link", "-i")
	if inErr != nil {
		log.Printf("moveStreamsToSink: pw-link -i failed: %v", inErr)
		return
	}

	// Build set of target sink input ports
	targetLines := strings.Split(inOut, "\n")
	targetPorts := make(map[string]bool)
	for _, line := range targetLines {
		trimmed := strings.TrimSpace(line)
		if strings.Contains(trimmed, sinkName+":playback_") || strings.Contains(trimmed, sinkName+":monitor_") {
			targetPorts[trimmed] = true
		}
	}

	if len(targetPorts) == 0 {
		log.Printf("moveStreamsToSink: no target ports found for sink %s", sinkName)
		return
	}

	// Get current links
	linksOut, linksErr := runCmd(3*time.Second, "pw-link", "-l")
	if linksErr != nil {
		log.Printf("moveStreamsToSink: pw-link -l failed: %v", linksErr)
		return
	}

	// Parse links to find stream output -> sink connections
	// pw-link -l format:
	//   sink:port_FL
	//     |<- stream:output_FL
	//   sink:port_FR
	//     |<- stream:output_FR
	//   stream:output_FL
	//     |-> sink:port_FL
	//     |-> sink2:port_FL
	streamOutputs := strings.Split(out, "\n")
	links := strings.Split(linksOut, "\n")

	for _, so := range streamOutputs {
		soTrim := strings.TrimSpace(so)
		// Skip monitors and non-stream ports
		if strings.Contains(soTrim, "monitor_") {
			continue
		}
		if !strings.Contains(soTrim, ":output_") && !strings.Contains(soTrim, ":capture_") {
			continue
		}

		// Find all links from this stream output
		// Look for lines like "  |-> sink:port" below this output in pw-link -l
		var connectedTo []string
		inThisStream := false
		for _, linkLine := range links {
			l := strings.TrimSpace(linkLine)
			if l == soTrim {
				inThisStream = true
				continue
			}
			if inThisStream {
				if strings.HasPrefix(l, "|-") || strings.HasPrefix(l, "`-") || strings.HasPrefix(l, "|->") || strings.HasPrefix(l, "`->") {
					// Extract the target port (after "-> ")
					if idx := strings.Index(l, "-> "); idx >= 0 {
						target := strings.TrimSpace(l[idx+3:])
						connectedTo = append(connectedTo, target)
					}
				} else if l == "" || (!strings.HasPrefix(l, " ") && !strings.HasPrefix(l, "|") && !strings.HasPrefix(l, "`")) {
					inThisStream = false
				}
			}
		}

		for _, conn := range connectedTo {
			// Is this connected to a different sink?
			isTarget := false
			for tp := range targetPorts {
				if conn == tp {
					isTarget = true
					break
				}
			}

			if !isTarget {
				// Disconnect from the old sink
				runCmd(2*time.Second, "pw-link", "-d", soTrim, conn)
				log.Printf("moveStreamsToSink: disconnected %s from %s", soTrim, conn)
			}
		}

		// Connect to all target sink ports (if not already connected)
		for tp := range targetPorts {
			already := false
			for _, conn := range connectedTo {
				if conn == tp {
					already = true
					break
				}
			}
			if !already {
				runCmd(2*time.Second, "pw-link", soTrim, tp)
				log.Printf("moveStreamsToSink: connected %s to %s", soTrim, tp)
			}
		}
	}
}

// --- Sink API handlers ---

func apiSinks(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}
	sinks := parseSinksFromPwDump()
	if sinks == nil {
		sinks = []SinkInfo{}
	}
	writeJSON(w, sinks)
}

func apiDefaultSink(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		cfg := loadAppConfig()
		writeJSON(w, map[string]string{"default_sink": cfg.Audio.DefaultSink})

	case http.MethodPost:
		body, err := io.ReadAll(r.Body)
		if err != nil {
			http.Error(w, "Failed to read body", http.StatusBadRequest)
			return
		}
		var req struct {
			SinkID   string `json:"sink_id"`
			SinkName string `json:"sink_name"`
			Volume   int    `json:"volume"`
		}
		if err := json.Unmarshal(body, &req); err != nil {
			http.Error(w, "Invalid JSON", http.StatusBadRequest)
			return
		}

		sinkName := req.SinkName
		sinkID := req.SinkID

		// If we only have the ID, resolve to name
		if sinkName == "" && sinkID != "" {
			sinks := parseSinksFromPwDump()
			for _, s := range sinks {
				if strconv.Itoa(s.ID) == sinkID {
					sinkName = s.Name
					break
				}
			}
		}

		if sinkName == "" {
			http.Error(w, "Missing sink_name", http.StatusBadRequest)
			return
		}

		// Apply immediately via wpctl
		if sinkID != "" {
			runCmd(3*time.Second, "wpctl", "set-default", sinkID)
		} else {
			// Find the ID for the name
			sinks := parseSinksFromPwDump()
			for _, s := range sinks {
				if s.Name == sinkName {
					sinkID = strconv.Itoa(s.ID)
					runCmd(3*time.Second, "wpctl", "set-default", sinkID)
					break
				}
			}
		}

		// Move all active stream outputs to the selected sink
		moveStreamsToSink(sinkName)

		// Apply master volume if provided
		vol := req.Volume
		if vol > 0 && vol <= 255 {
			volStr := fmt.Sprintf("%.2f", float64(vol)/255.0)
			runCmd(3*time.Second, "wpctl", "set-volume", sinkID, volStr)
		}

		// Save to persistent config
		cfg := loadAppConfig()
		cfg.Audio.DefaultSink = sinkName
		if vol > 0 && vol <= 255 {
			cfg.Audio.MasterVolume = vol
		}
		if err := saveAppConfig(cfg); err != nil {
			log.Printf("Failed to save default sink to config: %v", err)
			writeJSON(w, map[string]string{"status": "applied", "warning": "config not saved"})
			return
		}

		log.Printf("Default sink set to: %s (vol: %d)", sinkName, vol)
		writeJSON(w, map[string]string{"status": "saved", "default_sink": sinkName, "volume": strconv.Itoa(vol)})

	default:
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
	}
}

// --- Master volume API ---

func apiSetMasterVolume(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req struct {
		Volume int `json:"volume"`
	}
	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "Failed to read body", http.StatusBadRequest)
		return
	}
	if err := json.Unmarshal(body, &req); err != nil {
		http.Error(w, "Invalid JSON", http.StatusBadRequest)
		return
	}

	vol := req.Volume
	if vol < 0 || vol > 255 {
		http.Error(w, "Volume must be 0-255", http.StatusBadRequest)
		return
	}

	// Find the active/default sink from wpctl
	sinkID := getDefaultSinkID()
	if sinkID != "" {
		volStr := fmt.Sprintf("%.2f", float64(vol)/255.0)
		runCmd(3*time.Second, "wpctl", "set-volume", sinkID, volStr)
		// Also try numeric ID
		if _, err := strconv.Atoi(sinkID); err != nil {
			// sinkID is a name string, try to find numeric ID
			for _, s := range parseSinksFromPwDump() {
				if s.Name == sinkID || strconv.Itoa(s.ID) == sinkID {
					runCmd(3*time.Second, "wpctl", "set-volume", strconv.Itoa(s.ID), volStr)
					break
				}
			}
		}
	} else {
		// Fallback: try setting volume on all sinks
		for _, s := range parseSinksFromPwDump() {
			volStr := fmt.Sprintf("%.2f", float64(vol)/255.0)
			runCmd(2*time.Second, "wpctl", "set-volume", strconv.Itoa(s.ID), volStr)
		}
	}

	// Save to config
	cfg := loadAppConfig()
	cfg.Audio.MasterVolume = vol
	if err := saveAppConfig(cfg); err != nil {
		log.Printf("Failed to save master volume: %v", err)
	}
	log.Printf("Master volume set to: %d", vol)

	writeJSON(w, map[string]string{"status": "saved", "volume": strconv.Itoa(vol)})
}

// --- Audio levels / VU meter API ---

type LevelsResponse struct {
	Running     bool    `json:"running"`
	Volume      int     `json:"volume"`
	Levels      []int   `json:"levels"`
	Channels    int     `json:"channels"`
	StreamCount int     `json:"stream_count"`
}

// captureRMS reads a short PCM sample from the sink's monitor port
// and returns per-channel RMS levels (0-100 scale) using parec.
func captureRMS(sinkName string) (float64, float64) {
	// Determine monitor source name
	monitor := sinkName + ".monitor"
	if sinkName == "" {
		// Fall back to headphones sink
		monitor = "alsa_output.platform-3f00b840.mailbox.2.stereo-fallback.monitor"
	}

	// Capture ~400ms of audio at low rate for speed
	ctx, cancel := context.WithTimeout(context.Background(), 1200*time.Millisecond)
	defer cancel()

	cmd := exec.CommandContext(ctx, "parec",
		"--device="+monitor,
		"--rate=120",
		"--channels=2",
		"--format=s16le",
		"--raw",
		"--latency=2",
	)
	out, err := cmd.Output()
	if err != nil || len(out) < 8 {
		return 0, 0
	}

	// Parse interleaved 16-bit samples: L R L R ...
	numSamples := len(out) / 4 // 2 channels * 2 bytes each
	if numSamples > 200 {
		numSamples = 200
	}

	var sumL, sumR int64
	for i := 0; i < numSamples; i++ {
		off := i * 4
		// Little-endian 16-bit signed
		sampleL := int16(int(out[off]) | int(out[off+1])<<8)
		sampleR := int16(int(out[off+2]) | int(out[off+3])<<8)
		sumL += int64(sampleL) * int64(sampleL)
		sumR += int64(sampleR) * int64(sampleR)
	}

	if numSamples == 0 {
		return 0, 0
	}

	// RMS = sqrt(mean(samples^2)), then scale to 0-100 (32767 = max 16-bit)
	rmsL := float64(sumL) / float64(numSamples)
	rmsR := float64(sumR) / float64(numSamples)
	levelL := (float64(1) - float64(1)/(rmsL/100000+1)) * 100
	levelR := (float64(1) - float64(1)/(rmsR/100000+1)) * 100
	if levelL > 100 {
		levelL = 100
	}
	if levelR > 100 {
		levelR = 100
	}
	return levelL, levelR
}

func apiLevels(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	res := LevelsResponse{
		Levels: make([]int, 32),
	}

	// Get stream count and running state from pw-dump (fast because cached or short)
	pwOut, _ := runCmd(3*time.Second, "pw-dump")
	streamCount := 0
	running := false
	activeSinkName := ""
	if pwOut != "" {
		var objects []struct {
			Info *struct {
				Props map[string]interface{} `json:"props"`
			} `json:"info"`
		}
		if err := json.Unmarshal([]byte(pwOut), &objects); err == nil {
			for _, obj := range objects {
				if obj.Info != nil && obj.Info.Props != nil {
					cls, _ := obj.Info.Props["media.class"].(string)
					if cls == "Audio/Sink" {
						// Track the active sink name
						if n, ok := obj.Info.Props["node.name"].(string); ok {
							// Use it if it matches our default or is active
							activeSinkName = n
						}
					}
					if strings.Contains(cls, "Stream/Output/Audio") {
						streamCount++
						if corked, ok := obj.Info.Props["pulse.corked"].(bool); ok && !corked {
							running = true
						}
					}
				}
			}
		}
	}

	res.Running = running
	res.StreamCount = streamCount

	// Get actual audio levels from PCM monitor capture
	lLevel := 0.0
	rLevel := 0.0
	if running && streamCount > 0 {
		// Find the active sink name from config
		cfg := loadAppConfig()
		sinkName := cfg.Audio.DefaultSink
		if sinkName == "" {
			sinkName = activeSinkName
		}
		lLevel, rLevel = captureRMS(sinkName)
	}

	// Get volume of the default/active sink
	vol := 255
	sinkID := getDefaultSinkID()
	if sinkID != "" {
		volOut, volErr := runCmd(2*time.Second, "wpctl", "get-volume", sinkID)
		if volErr == nil {
			volParts := strings.Fields(volOut)
			if len(volParts) >= 2 {
				v := parseFloat(volParts[1], 1.0)
				vol = int(v * 255)
				if vol > 255 {
					vol = 255
				}
				if vol < 0 {
					vol = 0
				}
			}
		}
	}
	res.Volume = vol

	// Scale levels by master volume
	volScale := float64(vol) / 255.0
	lLevel *= volScale
	rLevel *= volScale

	// Map to 32 bars with frequency-appropriate falloff
	// Bars 0-15 = left channel, 16-31 = right channel
	for i := 0; i < 32; i++ {
		var chLevel float64
		if i < 16 {
			chLevel = lLevel
		} else {
			chLevel = rLevel
		}
		// Apply frequency falloff: lower bars (bass) stronger
		barPos := i % 16
		falloff := 1.0 - float64(barPos)/20.0
		if falloff < 0.15 {
			falloff = 0.15
		}
		pct := int(chLevel * falloff)
		if pct < 1 {
			pct = 1
		}
		if pct > 100 {
			pct = 100
		}
		res.Levels[i] = pct
	}

	res.Channels = 2
	writeJSON(w, res)
}

// --- JSON response helper ---

func writeJSON(w http.ResponseWriter, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Access-Control-Allow-Origin", "*")
	json.NewEncoder(w).Encode(data)
}

// --- API handlers ---

func apiStatus(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	pwRunning := isPipeWireRunning()
	sr, bs, ch := getPipeWireInfo()
	chStr := fmt.Sprintf("%d", ch)
	latency := float64(bs) / float64(sr) * 1000

	// Read real output level from the primary ALSA sink
	levels := make([]int, 32)
	if pwRunning {
		if sinkID := findPrimarySinkId(); sinkID != "" {
			volOut, volErr := runCmd(3*time.Second, "wpctl", "get-volume", sinkID)
			if volErr == nil {
				volParts := strings.Fields(volOut)
				if len(volParts) >= 2 {
					v := parseFloat(volParts[1], 0.0)
					pct := int(v * 100)
					if pct > 100 {
						pct = 100
					}
					// Spread the primary level across 32 bars as a simple VU approximation
					for i := 0; i < 32; i++ {
						barPct := pct
						// Taper the higher bars to simulate a VU meter look
						if i > 24 {
							barPct = pct * (32 - i) / 8
						}
						if barPct > 100 {
							barPct = 100
						}
						if barPct < 2 {
							barPct = 2
						}
						levels[i] = barPct
					}
				}
			}
		}
	}

	status := StatusResponse{
		Uptime:          getUptime(),
		RAMUsed:         getRAM(),
		CPULoad:         getCPULoad(),
		Temperature:     getTemp(),
		SampleRate:      sr,
		BufferSize:      bs,
		LatencyMs:       latency,
		Channels:        chStr,
		PipeWireRunning: pwRunning,
		Levels:          levels,
	}

	writeJSON(w, status)
}

func apiStreams(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	streams := parseWpctlStatus()
	writeJSON(w, streams)
}

func apiHosts(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		hf := loadHosts()
		// Annotate each host with whether it's currently connected
		streams := parseWpctlStatus()
		connected := make(map[string]bool)
		for _, s := range streams {
			connected[s.HostID] = true
		}
		type HostWithStatus struct {
			HostConfig
			Connected bool `json:"connected"`
		}
		result := make([]HostWithStatus, 0, len(hf.Hosts))
		for _, h := range hf.Hosts {
			result = append(result, HostWithStatus{
				HostConfig: h,
				Connected:  connected[h.ID],
			})
		}
		writeJSON(w, result)

	case http.MethodPut:
		var hosts []HostConfig
		body, err := io.ReadAll(r.Body)
		if err != nil {
			http.Error(w, "Failed to read body", http.StatusBadRequest)
			return
		}
		if err := json.Unmarshal(body, &hosts); err != nil {
			http.Error(w, "Invalid JSON", http.StatusBadRequest)
			return
		}
		hf := &HostsFile{Version: 1, Hosts: hosts}
		if err := saveHosts(hf); err != nil {
			log.Printf("Failed to save hosts: %v", err)
			http.Error(w, "Failed to save", http.StatusInternalServerError)
			return
		}
		writeJSON(w, map[string]string{"status": "saved"})

	default:
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
	}
}

func apiSetVolume(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req VolumeRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "Invalid request", http.StatusBadRequest)
		return
	}

	// Re-parse to get fresh node IDs
	streams := parseWpctlStatus()
	if req.Index < 0 || req.Index >= len(streams) {
		http.Error(w, "Stream not found", http.StatusNotFound)
		return
	}

	stream := streams[req.Index]
	volStr := fmt.Sprintf("%.2f", float64(req.Volume)/255.0)
	log.Printf("Setting volume for %s to %.2f", stream.NodeName, float64(req.Volume)/255.0)
	runCmd(3*time.Second, "wpctl", "set-volume", stream.NodeID, volStr)

	// Save to hosts.json
	hf := loadHosts()
	if hc := findHost(hf, stream.HostID); hc != nil {
		hc.Volume = req.Volume
	} else {
		hf.Hosts = append(hf.Hosts, HostConfig{
			ID:     stream.HostID,
			Label:  stream.HostLabel,
			Volume: req.Volume,
			Muted:  stream.Muted,
		})
	}
	saveHosts(hf)

	writeJSON(w, map[string]string{"status": "ok"})
}

func apiSetMute(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req MuteRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "Invalid request", http.StatusBadRequest)
		return
	}

	streams := parseWpctlStatus()
	if req.Index < 0 || req.Index >= len(streams) {
		http.Error(w, "Stream not found", http.StatusNotFound)
		return
	}

	stream := streams[req.Index]
	log.Printf("Toggling mute for %s (%s)", stream.Name, stream.NodeName)
	runCmd(3*time.Second, "wpctl", "set-mute", stream.NodeID, "toggle")

	// Toggle mute and save to hosts.json
	hf := loadHosts()
	newMuted := !stream.Muted
	if hc := findHost(hf, stream.HostID); hc != nil {
		hc.Muted = newMuted
	} else {
		hf.Hosts = append(hf.Hosts, HostConfig{
			ID:     stream.HostID,
			Label:  stream.HostLabel,
			Volume: stream.Volume,
			Muted:  newMuted,
		})
	}
	saveHosts(hf)

	writeJSON(w, map[string]string{"status": "ok", "muted": fmt.Sprintf("%v", newMuted)})
}

func apiFlushStreams(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}
	runCmd(5*time.Second, "wpctl", "reload-config")
	writeJSON(w, map[string]string{"status": "refreshed"})
}

func apiConfig(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		content, err := os.ReadFile(configPath)
		if err != nil {
			http.Error(w, "Config not found", http.StatusNotFound)
			return
		}
		w.Header().Set("Content-Type", "text/yaml")
		io.WriteString(w, string(content))

	case http.MethodPut:
		body, err := io.ReadAll(r.Body)
		if err != nil {
			http.Error(w, "Failed to read body", http.StatusBadRequest)
			return
		}
		if err := os.WriteFile(configPath, body, 0644); err != nil {
			log.Printf("Failed to write config: %v", err)
			http.Error(w, "Failed to save config", http.StatusInternalServerError)
			return
		}
		log.Printf("Config saved to %s (%d bytes)", configPath, len(body))
		writeJSON(w, map[string]string{"status": "saved"})

	default:
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
	}
}

func apiReload(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}
	runCmd(5*time.Second, "wpctl", "reload-config")
	writeJSON(w, map[string]string{"status": "reloading"})
}

// apiCustomCSS serves /data/style.css if it exists, for user theming.
func apiCustomCSS(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}
	content, err := os.ReadFile("/data/style.css")
	if err != nil {
		w.Header().Set("Content-Type", "text/css")
		w.Write([]byte("/* no custom style.css on /data */"))
		return
	}
	w.Header().Set("Content-Type", "text/css")
	w.Write(content)
}

// apiLogs returns recent system journal logs relevant to SinkSonic.
func apiLogs(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}
	out, err := runCmd(10*time.Second, "journalctl", "--no-pager", "-n", "200",
		"-u", "pipewire", "-u", "pipewire-pulse", "-u", "wireplumber",
		"-u", "sinksonic-webui",
		"--output=short-precise")
	if err != nil {
		// Fallback: try without user units
		out2, err2 := runCmd(10*time.Second, "journalctl", "--no-pager", "-n", "100",
			"--output=short-precise")
		if err2 != nil {
			http.Error(w, "Failed to read logs", http.StatusInternalServerError)
			return
		}
		out = out2
	}
	w.Header().Set("Content-Type", "text/plain")
	w.Write([]byte(out))
}

// --- Service management ---

type ServiceStatus struct {
	Name   string `json:"name"`
	Active bool   `json:"active"`
	PID    int    `json:"pid"`
	Uptime string `json:"uptime"`
}

func getServiceStatus(name string) ServiceStatus {
	s := ServiceStatus{Name: name}
	// For PipeWire services, use CLI checks that traverse the Unix socket
	// (works across container/host PID namespace boundary).
	switch name {
	case "pipewire":
		_, err := runCmd(2*time.Second, "pw-cli", "info", "all")
		s.Active = err == nil
		if s.Active {
			s.PID = 1
			s.Uptime = "via pw-cli"
		}
		return s
	case "wireplumber":
		out, err := runCmd(2*time.Second, "wpctl", "status")
		s.Active = err == nil && strings.Contains(out, "WirePlumber")
		if s.Active {
			s.PID = 1
			s.Uptime = "via wpctl"
		}
		return s
	case "pipewire-pulse":
		// Connect directly to the pulse socket (bypasses UID check when
		// container runs as root but socket is owned by user 1000/1001)
		sockPath := os.Getenv("XDG_RUNTIME_DIR")
		if sockPath == "" {
			sockPath = "/run/user/1001"
		}
		_, err := runCmd(2*time.Second, "pactl", "-s", sockPath+"/pulse/native", "info")
		s.Active = err == nil
		if s.Active {
			s.PID = 1
			s.Uptime = "via pactl"
		}
		return s
	}
	// Fallback: pgrep for non-PipeWire processes
	out, _ := runCmd(2*time.Second, "pgrep", "-x", name)
	s.Active = strings.TrimSpace(out) != ""
	if s.Active {
		if pid, err := strconv.Atoi(strings.TrimSpace(out)); err == nil {
			s.PID = pid
		}
		if s.PID > 0 {
			startOut, _ := os.ReadFile(fmt.Sprintf("/proc/%d/stat", s.PID))
			if len(startOut) > 0 {
				fields := strings.Fields(string(startOut))
				if len(fields) >= 22 {
					s.Uptime = fmt.Sprintf("PID %d", s.PID)
				}
			}
		}
	}
	return s
}

func apiServices(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}
	services := []ServiceStatus{
		getServiceStatus("pipewire"),
		getServiceStatus("wireplumber"),
		getServiceStatus("pipewire-pulse"),
	}
	// SinkSonic web UI — check ourselves (we ARE the server)
	services = append(services, ServiceStatus{
		Name:   "sinksonic-webui",
		Active: true,
		PID:    os.Getpid(),
		Uptime: fmt.Sprintf("PID %d", os.Getpid()),
	})
	writeJSON(w, services)
}

func apiServiceRestart(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}
	name := r.URL.Query().Get("name")
	if name == "" {
		http.Error(w, "Missing 'name' query param", http.StatusBadRequest)
		return
	}
	valid := map[string]bool{"pipewire": true, "wireplumber": true, "pipewire-pulse": true}
	if !valid[name] {
		http.Error(w, "Invalid service name", http.StatusBadRequest)
		return
	}
	log.Printf("Restarting service: %s", name)
	// Send SIGHUP to restart via PID (works in container or on host)
	pidOut, _ := runCmd(2*time.Second, "pidof", name)
	pidStr := strings.TrimSpace(pidOut)
	if pidStr == "" {
		writeJSON(w, map[string]string{"status": "failed", "error": "service not found"})
		return
	}
	pidParts := strings.Fields(pidStr)
	_, err := runCmd(3*time.Second, "kill", "-HUP", pidParts[0])
	if err != nil {
		log.Printf("Failed to restart %s: %v", name, err)
		writeJSON(w, map[string]string{"status": "failed", "error": err.Error()})
		return
	}
	writeJSON(w, map[string]string{"status": "restarted", "service": name})
}

// apiApplySettings applies audio settings at runtime (buffer, latency)
func apiApplySettings(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}
	buffer := r.URL.Query().Get("buffer")
	latency := r.URL.Query().Get("latency")
	log.Printf("Applying audio settings: buffer=%s latency=%s", buffer, latency)

	if buffer != "" {
		runCmd(5*time.Second, "pw-metadata", "-n", "settings", "0", "clock.force-quantum", buffer)
	}
	if latency != "" {
		// Convert ms to rate as target
		runCmd(5*time.Second, "pw-metadata", "-n", "settings", "0", "clock.force-quantum", "0")
		runCmd(5*time.Second, "pw-metadata", "-n", "settings", "0", "clock.force-rate", "0")
	}

	writeJSON(w, map[string]string{"status": "applied"})
}

// apiSetup returns setup scripts for various client OSes.
func apiSetup(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}
	hostname := getHostname()
	type setupEntry struct {
		OS          string `json:"os"`
		Label       string `json:"label"`
		Script      string `json:"script"`
		Shell       string `json:"shell"`
		Description string `json:"description"`
	}
	entries := []setupEntry{
		{
			OS: "linux", Label: "Linux (PipeWire)", Shell: "bash",
			Description: "Creates a persistent PulseAudio tunnel sink to SinkSonic. Audio appears as a selectable output device.",
			Script: fmt.Sprintf(`#!/bin/bash
# SinkSonic tunnel — Linux (PipeWire)
set -euo pipefail
PI_HOST="%[1]s"
# Remove stale modules
pactl list modules short 2>/dev/null | grep module-tunnel-sink | awk '{print $1}' | while read idx; do
  pactl unload-module "$$idx" 2>/dev/null || true
done 2>/dev/null || true
# Create tunnel
pactl load-module module-tunnel-sink \
  server=tcp:"$$PI_HOST":4713 \
  sink_name=sinksonic-tunnel \
  sink_properties=device.description=SinkSonic
sleep 1
pactl set-default-sink sinksonic-tunnel 2>/dev/null || true
echo "SinkSonic tunnel created → $$PI_HOST"`, hostname),
		},
		{
			OS: "macos", Label: "macOS (Homebrew)", Shell: "bash",
			Description: "Requires PulseAudio from Homebrew. Tunnel sink forwards audio to SinkSonic.",
			Script: fmt.Sprintf(`#!/bin/bash
# SinkSonic tunnel — macOS (Homebrew PulseAudio)
brew install pulseaudio 2>/dev/null || true
brew services start pulseaudio 2>/dev/null || true
sleep 2
PI_HOST="%[1]s"
pactl load-module module-tunnel-sink \
  server=tcp:"$$PI_HOST":4713 \
  sink_name=sinksonic-tunnel \
  sink_properties=device.description=SinkSonic
echo "SinkSonic tunnel created → $$PI_HOST"`, hostname),
		},
		{
			OS: "windows", Label: "Windows (PulseAudio/WSL)", Shell: "powershell",
			Description: "Use PulseAudio for Windows or follow the WSL2 approach.",
			Script: fmt.Sprintf(`# SinkSonic tunnel — Windows (WSL2)
# 1. Add Pi to WSL2 hosts file:
echo "%[1]s sinksonic.local" | sudo tee -a /etc/hosts

# 2. Run the Linux setup inside WSL2:
#    Follow the linux tab instructions`, "192.168.178.160"),
		},
		{
			OS: "android", Label: "Android (AudioRelay)", Shell: "",
			Description: "Use AudioRelay app to stream Android audio to a desktop server that feeds SinkSonic.",
			Script: "See setup.sinksonic.local/setup for full instructions",
		},
		{
			OS: "ios", Label: "iOS (AirPlay)", Shell: "",
			Description: "If Shairport Sync is running on the Pi, select SinkSonic from AirPlay in Control Center.",
			Script: "See setup.sinksonic.local/setup for full instructions",
		},
	}
	writeJSON(w, entries)
}

// apiHostname returns the Pi's hostname for setup pages.
func apiHostname(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}
	writeJSON(w, map[string]string{"hostname": getHostname()})
}

// apiLinuxSetupScript returns a raw shell script for Linux desktop setup.
func apiLinuxSetupScript(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}
	hostname := getHostname()
	script := fmt.Sprintf(`#!/bin/bash
# SinkSonic persistent tunnel — Linux (PipeWire)
# Run this once, then select "SinkSonic" in your sound settings.
set -euo pipefail
PI_HOST="%[1]s"

# Remove stale modules
pactl list modules short 2>/dev/null | grep module-tunnel-sink | awk '{print $1}' | while read idx; do
  pactl unload-module "$$idx" 2>/dev/null || true
done 2>/dev/null || true

# Create tunnel sink
pactl load-module module-tunnel-sink \
  server=tcp:"$$PI_HOST":4713 \
  sink_name=sinksonic-tunnel \
  sink_properties=device.description=SinkSonic

sleep 1

# Set as default
pactl set-default-sink sinksonic-tunnel 2>/dev/null || true
echo "SinkSonic tunnel active → $$PI_HOST"
`, hostname)
	w.Header().Set("Content-Type", "text/plain")
	w.Write([]byte(script))
}

func getHostname() string {
	out, err := runCmd(2*time.Second, "hostname")
	if err != nil || out == "" {
		return "sinksonic.local"
	}
	return out + ".local"
}

// apiReboot triggers a system reboot.
func apiReboot(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}
	log.Printf("Reboot requested via web UI")
	writeJSON(w, map[string]string{"status": "rebooting"})
	go func() {
		runCmd(30*time.Second, "sudo", "/sbin/reboot")
	}()
}

// apiPoweroff triggers a system poweroff.
func apiPoweroff(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}
	log.Printf("Poweroff requested via web UI")
	writeJSON(w, map[string]string{"status": "powering_off"})
	go func() {
		runCmd(30*time.Second, "sudo", "/sbin/poweroff")
	}()
}
