package gateway

import (
	"bufio"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

func runtimeFixture(t *testing.T, f *fixture, handle func(net.Conn, rpcRequest)) *atomic.Int32 {
	t.Helper()
	listener, err := net.Listen("unix", f.config.RuntimeSocket)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })
	count := new(atomic.Int32)
	go func() {
		for {
			connection, err := listener.Accept()
			if err != nil {
				return
			}
			go func() {
				defer connection.Close()
				line, err := bufio.NewReader(connection).ReadBytes('\n')
				if err != nil {
					return
				}
				var request rpcRequest
				if json.Unmarshal(line, &request) != nil {
					return
				}
				count.Add(1)
				handle(connection, request)
			}()
		}
	}()
	return count
}

func TestRPCRequiresAuthenticationBeforeConnectingAndPreservesIDs(t *testing.T) {
	f := newFixture(t)
	count := runtimeFixture(t, f, func(connection net.Conn, request rpcRequest) {
		json.NewEncoder(connection).Encode(map[string]any{"version": 9, "id": request.ID, "result": map[string]any{"hello": map[string]string{"name": "test"}}})
	})
	body := `{"version":9,"id":"00000000-0000-0000-0000-000000000001","operation":{"hello":{}}}`
	if response := f.request("POST", f.config.APIHost, "/v1/rpc", "", "", body); response.Code != 401 {
		t.Fatal(response.Code)
	}
	if count.Load() != 0 {
		t.Fatal("unauthenticated request reached runtime")
	}
	response := f.request("POST", f.config.APIHost, "/v1/rpc", f.token(t, "control", nil), "", body)
	if response.Code != 200 || !strings.Contains(response.Body.String(), "00000000-0000-0000-0000-000000000001") {
		t.Fatal(response.Code, response.Body.String())
	}
	if count.Load() != 1 {
		t.Fatal(count.Load())
	}
}

func TestRPCRejectsMalformedAndOversizedBodies(t *testing.T) {
	f := newFixture(t)
	token := f.token(t, "control", nil)
	for _, body := range []string{
		`{}`, `{"version":8,"id":"00000000-0000-0000-0000-000000000001","operation":{"hello":{}}}`,
		`{"version":9,"id":"00000000-0000-0000-0000-000000000001","operation":{"hello":{},"catalogue":{}}}`,
		`{"version":9,"id":"00000000-0000-0000-0000-000000000001","operation":{"hello":{}}}{"extra":true}`,
	} {
		if response := f.request("POST", f.config.APIHost, "/v1/rpc", token, "", body); response.Code != 400 {
			t.Fatal(response.Code)
		}
	}
	if response := f.request("POST", f.config.APIHost, "/v1/rpc", token, "", strings.Repeat("x", maxBody+1)); response.Code != 413 {
		t.Fatal(response.Code)
	}
}

func TestConfigurationCannotOpenPublicListenersOrCrossWorkspacePreviews(t *testing.T) {
	f := newFixture(t)
	for _, listen := range []string{"0.0.0.0:18000", "[::]:18000", "localhost:18000"} {
		config := f.config
		config.Listen = listen
		if config.Validate() == nil {
			t.Fatal(listen)
		}
	}
	config := f.config
	config.Previews = append([]Preview(nil), config.Previews...)
	config.Previews[0].Port = 18880
	if config.Validate() == nil {
		t.Fatal("recursive gateway proxy allowed")
	}
	config.Previews[0].Port = 18000
	config.Previews[0].Access.Audience = "control"
	if config.Validate() == nil {
		t.Fatal("preview control audience allowed")
	}
	config = f.config
	config.Previews = append([]Preview(nil), config.Previews...)
	other := config.Previews[0]
	other.Host = "other.preview.example.com"
	other.WorkspaceID = "workspace-b"
	other.Port = 18001
	config.Previews = append(config.Previews, other)
	if config.Validate() == nil {
		t.Fatal("shared audience across workspaces allowed")
	}
	config.Previews[1].Access.Audience = "workspace-b"
	config.Previews[0].AllowedOrigins = []string{"https://other.preview.example.com"}
	if config.Validate() == nil {
		t.Fatal("cross-workspace origin allowed")
	}
}

func TestTerminalStreamRequiresControlAccessAndRelaysBinaryInput(t *testing.T) {
	f := newFixture(t)
	path := filepath.Join("/tmp", "bloom-terminal-"+requestID()+".sock")
	listener, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	defer os.Remove(path)
	input := make(chan terminalFrame, 1)
	go func() {
		connection, err := listener.Accept()
		if err != nil {
			return
		}
		defer connection.Close()
		json.NewEncoder(connection).Encode(terminalFrame{Kind: "output", Data: []byte("\x1b[31mready\xff")})
		var frame terminalFrame
		json.NewDecoder(connection).Decode(&frame)
		input <- frame
		io.Copy(io.Discard, connection)
	}()
	count := runtimeFixture(t, f, func(connection net.Conn, request rpcRequest) {
		if _, ok := request.Operation["terminalStream"]; !ok {
			t.Error("wrong operation")
		}
		json.NewEncoder(connection).Encode(map[string]any{"version": 9, "id": request.ID, "result": map[string]any{"text": map[string]string{"_0": path}}})
	})
	server := httptest.NewServer(f.server)
	defer server.Close()
	address := "ws" + strings.TrimPrefix(server.URL, "http") + "/v1/terminal?workspace_id=workspace-a&name=main"
	header := http.Header{"Host": []string{f.config.APIHost}, "Authorization": []string{"Bearer " + f.token(t, "workspace-a", nil)}}
	if connection, response, err := websocket.DefaultDialer.Dial(address, header); err == nil {
		connection.Close()
		t.Fatal("preview token opened terminal")
	} else if response.StatusCode != 401 {
		t.Fatal(response.StatusCode)
	}
	if count.Load() != 0 {
		t.Fatal("preview token reached terminal runtime")
	}
	header.Set("Authorization", "Bearer "+f.token(t, "control", nil))
	connection, _, err := websocket.DefaultDialer.Dial(address, header)
	if err != nil {
		t.Fatal(err)
	}
	defer connection.Close()
	connection.SetReadDeadline(time.Now().Add(3 * time.Second))
	_, data, err := connection.ReadMessage()
	if err != nil || string(data) != "\x1b[31mready\xff" {
		t.Fatal(data, err)
	}
	if err = connection.WriteMessage(websocket.BinaryMessage, []byte("echo test\r")); err != nil {
		t.Fatal(err)
	}
	select {
	case frame := <-input:
		if frame.Kind != "input" || string(frame.Data) != "echo test\r" {
			t.Fatal(frame)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("terminal input was not delivered")
	}
	connection.Close()
}
