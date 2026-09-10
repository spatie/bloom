package main

import "net/http"

// HTTP serving stops accepting connections before Shutdown finishes draining active requests.
func serveHTTP(serve func() error, shutdownDone <-chan struct{}) error {
	if err := serve(); err != http.ErrServerClosed {
		return err
	}
	<-shutdownDone
	return nil
}
