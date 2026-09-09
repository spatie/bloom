package main

import (
	"context"
	"flag"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/spatie/bloom/gateway/internal/gateway"
)

func main() {
	path := flag.String("config", "", "absolute path to the administrator-owned gateway configuration")
	flag.Parse()
	if *path == "" {
		log.Fatal("--config is required")
	}
	config, err := gateway.LoadConfig(*path)
	if err != nil {
		log.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	client := &http.Client{Timeout: 5 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	verifier := gateway.NewVerifier(gateway.VerifierContext(ctx, client))
	handler, err := gateway.New(config, verifier)
	if err != nil {
		log.Fatal(err)
	}
	server := &http.Server{Addr: config.Listen, Handler: handler, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 20 * time.Second, IdleTimeout: 30 * time.Second, MaxHeaderBytes: 32 << 10}
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP)
	go func() {
		for sig := range signals {
			if sig == syscall.SIGHUP {
				fresh, err := gateway.LoadConfig(*path)
				if err == nil {
					err = handler.Reload(fresh)
				}
				if err != nil {
					log.Printf("Configuration reload refused: %v", err)
				} else {
					log.Print("Configuration reloaded; existing connections will reauthenticate")
				}
				continue
			}
			cancel()
			ctx, stop := context.WithTimeout(context.Background(), 5*time.Second)
			server.Shutdown(ctx)
			stop()
			return
		}
	}()
	log.Printf("Bloom gateway listening on %s", config.Listen)
	if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatal(err)
	}
}
