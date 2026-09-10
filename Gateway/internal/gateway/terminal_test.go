package gateway

import (
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

func TestTerminalEOFUsesNormalWebSocketCloseButMalformedOutputDoesNot(t *testing.T) {
	for _, malformed := range []bool{false, true} {
		name := "normal process exit"
		if malformed {
			name = "malformed terminal output"
		}
		t.Run(name, func(t *testing.T) {
			f := newFixture(t)
			path := filepath.Join("/tmp", "bloom-terminal-"+requestID()+".sock")
			listener, err := net.Listen("unix", path)
			if err != nil {
				t.Fatal(err)
			}
			defer listener.Close()
			defer os.Remove(path)
			go func() {
				connection, err := listener.Accept()
				if err != nil {
					return
				}
				defer connection.Close()
				if malformed {
					_, _ = connection.Write([]byte("invalid frame\n"))
				} else {
					_ = json.NewEncoder(connection).Encode(terminalFrame{Kind: "output", Data: []byte("done\r\n")})
				}
			}()
			runtimeFixture(t, f, func(connection net.Conn, request rpcRequest) {
				_ = json.NewEncoder(connection).Encode(map[string]any{"version": protocolVersion, "id": request.ID,
					"result": map[string]any{"text": map[string]string{"_0": path}}})
			})
			server := httptest.NewServer(f.server)
			defer server.Close()
			address := "ws" + strings.TrimPrefix(server.URL, "http") + "/v1/terminal?workspace_id=workspace-a&name=eof-check"
			header := http.Header{"Host": []string{f.config.APIHost}, "Authorization": []string{"Bearer " + f.token(t, "control", nil)}}
			connection, _, err := websocket.DefaultDialer.Dial(address, header)
			if err != nil {
				t.Fatal(err)
			}
			defer connection.Close()
			_ = connection.SetReadDeadline(time.Now().Add(3 * time.Second))
			if !malformed {
				_, data, err := connection.ReadMessage()
				if err != nil || string(data) != "done\r\n" {
					t.Fatal("missing final output", string(data), err)
				}
			}
			_, _, err = connection.ReadMessage()
			if err == nil || websocket.IsCloseError(err, websocket.CloseNormalClosure) == malformed {
				t.Fatal("incorrect terminal close status", err)
			}
		})
	}
}
