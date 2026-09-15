package main

import (
	"context"
	"errors"
	"io"
	"net"
	"net/http"
	"sync"
	"testing"
	"time"
)

type observedListener struct {
	net.Listener
	closed chan struct{}
	once   sync.Once
}

func (listener *observedListener) Close() error {
	err := listener.Listener.Close()
	listener.once.Do(func() { close(listener.closed) })
	return err
}

func TestServeWaitsForActiveRequestsDuringShutdown(t *testing.T) {
	connection, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	listener := &observedListener{Listener: connection, closed: make(chan struct{})}
	defer listener.Close()
	started := make(chan struct{})
	finishRequest := make(chan struct{})
	var release sync.Once
	defer release.Do(func() { close(finishRequest) })
	server := &http.Server{Handler: http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		close(started)
		<-finishRequest
		_, _ = io.WriteString(writer, "completed")
	})}
	defer server.Close()
	shutdownDone := make(chan struct{})
	served := make(chan error, 1)
	go func() { served <- serveHTTP(func() error { return server.Serve(listener) }, shutdownDone) }()
	response := make(chan string, 1)
	client := &http.Client{Timeout: 3 * time.Second}
	go func() {
		result, err := client.Get("http://" + listener.Addr().String())
		if err != nil {
			response <- err.Error()
			return
		}
		defer result.Body.Close()
		body, _ := io.ReadAll(result.Body)
		response <- string(body)
	}()
	select {
	case <-started:
	case <-time.After(3 * time.Second):
		t.Fatal("request did not start")
	}
	go func() {
		defer close(shutdownDone)
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		_ = server.Shutdown(ctx)
	}()
	<-listener.closed
	select {
	case err := <-served:
		t.Fatalf("serving returned before the active request finished: %v", err)
	case <-time.After(50 * time.Millisecond):
	}
	release.Do(func() { close(finishRequest) })
	if body := <-response; body != "completed" {
		t.Fatalf("active request was interrupted: %s", body)
	}
	select {
	case err := <-served:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("serving did not return after shutdown")
	}
}

func TestServeReportsStartupFailureWithoutWaitingForShutdown(t *testing.T) {
	failure := errors.New("fixture listen failure")
	if err := serveHTTP(func() error { return failure }, make(chan struct{})); !errors.Is(err, failure) {
		t.Fatal("startup failure was lost", err)
	}
}
