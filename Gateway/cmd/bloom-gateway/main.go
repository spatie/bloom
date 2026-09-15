package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
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
	identityCA := flag.String("identity-ca-file", "", "optional PEM certificate authority for the configured identity provider")
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
	if *identityCA != "" {
		pem, err := os.ReadFile(*identityCA)
		if err != nil {
			log.Fatal(err)
		}
		roots, err := x509.SystemCertPool()
		if err != nil {
			log.Fatal(err)
		}
		if !roots.AppendCertsFromPEM(pem) {
			log.Fatal("identity CA file contains no certificates")
		}
		transport := http.DefaultTransport.(*http.Transport).Clone()
		transport.TLSClientConfig = &tls.Config{RootCAs: roots, MinVersion: tls.VersionTLS12}
		client.Transport = transport
	}
	verifier := gateway.NewVerifier(gateway.VerifierContext(ctx, client))
	handler, err := gateway.New(config, verifier)
	if err != nil {
		log.Fatal(err)
	}
	server := &http.Server{Addr: config.Listen, Handler: handler, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 20 * time.Second, IdleTimeout: 30 * time.Second, MaxHeaderBytes: 32 << 10}
	shutdownDone := make(chan struct{})
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP)
	defer signal.Stop(signals)
	go func() {
		defer close(shutdownDone)
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
			if err := server.Shutdown(ctx); err != nil {
				log.Printf("HTTP shutdown did not finish: %v", err)
			}
			stop()
			return
		}
	}()
	log.Printf("Bloom gateway listening on %s", config.Listen)
	if err := serveHTTP(server.ListenAndServe, shutdownDone); err != nil {
		log.Fatal(err)
	}
}
