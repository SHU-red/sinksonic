package main

import (
	"embed"
	"fmt"
	"io/fs"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

//go:embed static/*
var staticFS embed.FS

func main() {
	addr := getEnv("LISTEN_ADDR", "0.0.0.0")
	port := getEnv("LISTEN_PORT", "8080")
	listenAddr := fmt.Sprintf("%s:%s", addr, port)

	// Strip /static prefix for embedded files
	staticSub, err := fs.Sub(staticFS, "static")
	if err != nil {
		log.Fatalf("Failed to create static sub FS: %v", err)
	}

	mux := http.NewServeMux()

	// Static files
	mux.Handle("/", http.FileServer(http.FS(staticSub)))

	// API endpoints
	mux.HandleFunc("/api/status", apiStatus)
	mux.HandleFunc("/api/streams", apiStreams)
	mux.HandleFunc("/api/stream/set-volume", apiSetVolume)
	mux.HandleFunc("/api/stream/set-mute", apiSetMute)
	mux.HandleFunc("/api/stream/flush", apiFlushStreams)
	mux.HandleFunc("/api/hosts", apiHosts)
	mux.HandleFunc("/api/custom.css", apiCustomCSS)
	mux.HandleFunc("/api/version", versionHandler)
	mux.HandleFunc("/api/logs", apiLogs)
	mux.HandleFunc("/api/reboot", apiReboot)
	mux.HandleFunc("/api/poweroff", apiPoweroff)
	mux.HandleFunc("/api/config", apiConfig)
	mux.HandleFunc("/api/reload", apiReload)
	mux.HandleFunc("/api/services", apiServices)
	mux.HandleFunc("/api/service/restart", apiServiceRestart)
	mux.HandleFunc("/api/apply-settings", apiApplySettings)
	mux.HandleFunc("/api/setup", apiSetup)
	mux.HandleFunc("/api/hostname", apiHostname)
	mux.HandleFunc("/api/setup/linux/script", apiLinuxSetupScript)
	mux.HandleFunc("/api/sinks", apiSinks)
	mux.HandleFunc("/api/sink/default", apiDefaultSink)
	mux.HandleFunc("/api/volume", apiSetMasterVolume)
	mux.HandleFunc("/api/levels", apiLevels)

	server := &http.Server{
		Addr:         listenAddr,
		Handler:      mux,
		ReadTimeout:  5 * time.Second,
		WriteTimeout: 10 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	// Graceful shutdown
	go func() {
		sigCh := make(chan os.Signal, 1)
		signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
		<-sigCh
		log.Println("Shutting down...")
		server.Close()
	}()

	log.Printf("Web UI listening on %s", listenAddr)
	if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatalf("Server error: %v", err)
	}
}

func getEnv(key, fallback string) string {
	if value, ok := os.LookupEnv(key); ok {
		return value
	}
	return fallback
}

// buildVersion is set at compile time via ldflags -X
var buildVersion = "dev"

func versionHandler(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, map[string]string{
		"version": buildVersion,
		"image":   getEnv("IMAGE_LABEL", "unknown"),
	})
}
