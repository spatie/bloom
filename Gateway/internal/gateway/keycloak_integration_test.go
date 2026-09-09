package gateway

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/coreos/go-oidc/v3/oidc"
	"github.com/gorilla/websocket"
)

func TestConfiguredIdentityProviderIntegration(t *testing.T) {
	directory := os.Getenv("BLOOM_HTTPS_FIXTURE")
	if directory == "" {
		t.Skip("set BLOOM_HTTPS_FIXTURE to a running isolated identity fixture")
	}
	config, err := LoadConfig(filepath.Join(directory, "gateway.json"))
	if err != nil {
		t.Fatal(err)
	}
	pem, err := os.ReadFile(filepath.Join(directory, "cert.pem"))
	if err != nil {
		t.Fatal(err)
	}
	roots := x509.NewCertPool()
	roots.AppendCertsFromPEM(pem)
	client := &http.Client{Timeout: 5 * time.Second, Transport: &http.Transport{TLSClientConfig: &tls.Config{RootCAs: roots, MinVersion: tls.VersionTLS12}}}
	ctx := VerifierContext(context.Background(), client)
	raw, err := os.ReadFile(filepath.Join(directory, "access-token.txt"))
	if err != nil {
		t.Fatal(err)
	}
	// Include the library's diagnostic in test failures; never print the credential.
	_, err = oidc.NewVerifier(config.Access.Issuer, oidc.NewRemoteKeySet(ctx, config.Access.JWKSURL), &oidc.Config{ClientID: config.Access.Audience}).Verify(ctx, string(raw))
	if err != nil {
		t.Fatal(err)
	}
	_, err = NewVerifier(ctx).Verify(ctx, string(raw), config.Access)
	if err != nil {
		t.Fatal(err)
	}
}

func TestLiveRuntimeTerminalIntegration(t *testing.T) {
	directory := os.Getenv("BLOOM_HTTPS_FIXTURE")
	if directory == "" {
		t.Skip("set BLOOM_HTTPS_FIXTURE to a running isolated identity fixture")
	}
	config, err := LoadConfig(filepath.Join(directory, "gateway.json"))
	if err != nil {
		t.Fatal(err)
	}
	pem, _ := os.ReadFile(filepath.Join(directory, "cert.pem"))
	roots := x509.NewCertPool()
	roots.AppendCertsFromPEM(pem)
	transport := &http.Transport{TLSClientConfig: &tls.Config{RootCAs: roots, MinVersion: tls.VersionTLS12}}
	client := &http.Client{Transport: transport, Timeout: 10 * time.Second}
	var created struct {
		Workspace struct {
			ID string `json:"id"`
		} `json:"workspace"`
	}
	data, err := os.ReadFile(filepath.Join(directory, "created.json"))
	if err != nil {
		t.Fatal(err)
	}
	if err = json.Unmarshal(data, &created); err != nil {
		t.Fatal(err)
	}
	token := func() string {
		data, err := os.ReadFile(filepath.Join(directory, "access-token.txt"))
		if err != nil {
			t.Fatal(err)
		}
		return string(data)
	}
	rpc := func(operation map[string]any) map[string]json.RawMessage {
		body, _ := json.Marshal(map[string]any{"version": 10, "id": requestID(), "operation": operation})
		request, _ := http.NewRequest("POST", "https://"+config.APIHost+"/v1/rpc", bytes.NewReader(body))
		request.Header.Set("Content-Type", "application/json")
		request.Header.Set("Authorization", "Bearer "+token())
		response, err := client.Do(request)
		if err != nil {
			t.Fatal(err)
		}
		defer response.Body.Close()
		if response.StatusCode != 200 {
			t.Fatal(response.StatusCode)
		}
		var reply struct {
			Result map[string]json.RawMessage `json:"result"`
		}
		if err = json.NewDecoder(response.Body).Decode(&reply); err != nil {
			t.Fatal(err)
		}
		return reply.Result
	}
	readFile := func(path string) string {
		result := rpc(map[string]any{"file": map[string]string{"workspaceID": created.Workspace.ID, "path": path}})
		var file struct {
			Value struct {
				Text string `json:"text"`
			} `json:"_0"`
		}
		json.Unmarshal(result["file"], &file)
		return file.Value.Text
	}
	dial := func() *websocket.Conn {
		dialer := websocket.Dialer{TLSClientConfig: transport.TLSClientConfig, HandshakeTimeout: 10 * time.Second}
		connection, response, err := dialer.Dial("wss://"+config.APIHost+"/v1/terminal?workspace_id="+url.QueryEscape(created.Workspace.ID)+"&name=https-e2e", http.Header{"Authorization": []string{"Bearer " + token()}})
		if err != nil {
			if response != nil {
				t.Log("HTTP status", response.StatusCode)
			}
			t.Fatal(err)
		}
		return connection
	}
	first := dial()
	first.SetReadDeadline(time.Now().Add(10 * time.Second))
	_, output, err := first.ReadMessage()
	if err != nil || len(output) == 0 {
		t.Fatal("terminal produced no screen", err)
	}
	if err = first.WriteMessage(websocket.BinaryMessage, []byte("printf 'first\\n' > e2e-terminal.txt\r")); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for readFile("e2e-terminal.txt") != "first\n" && time.Now().Before(deadline) {
		time.Sleep(50 * time.Millisecond)
	}
	if readFile("e2e-terminal.txt") != "first\n" {
		t.Fatal("terminal input was not executed")
	}
	first.Close()
	second := dial()
	defer second.Close()
	if err = second.WriteMessage(websocket.TextMessage, []byte(`{"kind":"resize","columns":120,"rows":35}`)); err != nil {
		t.Fatal(err)
	}
	if err = second.WriteMessage(websocket.BinaryMessage, []byte("printf 'second\\n' >> e2e-terminal.txt; stty size > e2e-size.txt\r")); err != nil {
		t.Fatal(err)
	}
	deadline = time.Now().Add(5 * time.Second)
	for readFile("e2e-size.txt") == "" && time.Now().Before(deadline) {
		time.Sleep(50 * time.Millisecond)
	}
	if readFile("e2e-terminal.txt") != "first\nsecond\n" {
		t.Fatal("reconnection replayed or lost input")
	}
	if strings.TrimSpace(readFile("e2e-size.txt")) != "35 120" {
		t.Fatal("terminal resize was not applied")
	}
	t.Log("PASS: real TLS WebSocket, terminal input, persistent shell reconnection and resize")
	rpc(map[string]any{"workspace": map[string]any{"workspaceID": created.Workspace.ID, "action": map[string]any{"closeTerminal": map[string]string{"name": "https-e2e"}}}})
}
