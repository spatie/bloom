package gateway

import (
	"bufio"
	"context"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"path/filepath"
	"strings"
	"time"

	"github.com/gorilla/websocket"
)

type terminalFrame struct {
	Kind    string `json:"kind"`
	Data    []byte `json:"data,omitempty"`
	Columns int    `json:"columns,omitempty"`
	Rows    int    `json:"rows,omitempty"`
}

func requestID() string {
	var value [16]byte
	if _, err := rand.Read(value[:]); err != nil {
		panic("system random source unavailable")
	}
	value[6] = (value[6] & 0x0f) | 0x40
	value[8] = (value[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", value[:4], value[4:6], value[6:8], value[8:10], value[10:])
}

func (server *Server) terminal(writer http.ResponseWriter, request *http.Request, config Config) {
	query := request.URL.Query()
	if request.Method != "GET" || len(query) != 2 || len(query["workspace_id"]) != 1 || len(query["name"]) != 1 || len(query.Get("workspace_id")) > 128 || len(query.Get("name")) > 64 || query.Get("workspace_id") == "" || query.Get("name") == "" {
		http.Error(writer, "Invalid terminal request", 400)
		return
	}
	id := requestID()
	operation, _ := json.Marshal(map[string]string{"workspaceID": query.Get("workspace_id"), "name": query.Get("name")})
	input := rpcRequest{Version: protocolVersion, ID: id, Operation: map[string]json.RawMessage{"terminalStream": operation}}
	body, _ := json.Marshal(input)
	ctx, cancel := context.WithTimeout(request.Context(), 15*time.Second)
	reply, err := runtimeRequest(ctx, config.RuntimeSocket, body, input)
	cancel()
	if err != nil {
		http.Error(writer, "Terminal unavailable", 502)
		return
	}
	var decoded struct {
		Result struct {
			Text struct {
				Value string `json:"_0"`
			} `json:"text"`
		} `json:"result"`
	}
	if json.Unmarshal(reply, &decoded) != nil {
		http.Error(writer, "Terminal unavailable", 502)
		return
	}
	path := decoded.Result.Text.Value
	if filepath.Dir(path) != "/tmp" || !strings.HasPrefix(filepath.Base(path), "bloom-terminal-") || !strings.HasSuffix(path, ".sock") {
		http.Error(writer, "Terminal unavailable", 502)
		return
	}
	connection, err := (&net.Dialer{Timeout: 5 * time.Second}).DialContext(request.Context(), "unix", path)
	if err != nil {
		http.Error(writer, "Terminal unavailable", 502)
		return
	}
	defer connection.Close()
	// The outer handler already checked the exact origin and control audience.
	upgrader := websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }, HandshakeTimeout: 5 * time.Second}
	socket, err := upgrader.Upgrade(writer, request, nil)
	if err != nil {
		return
	}
	defer socket.Close()
	socket.SetReadLimit(16_384)
	stop := context.AfterFunc(request.Context(), func() { socket.Close(); connection.Close() })
	defer stop()
	done := make(chan struct{})
	go func() {
		defer close(done)
		defer socket.Close()
		defer connection.Close()
		reader := bufio.NewScanner(connection)
		reader.Buffer(make([]byte, 4096), 100_000)
		for reader.Scan() {
			var frame terminalFrame
			if json.Unmarshal(reader.Bytes(), &frame) != nil || frame.Kind != "output" || len(frame.Data) > 65536 {
				return
			}
			socket.SetWriteDeadline(time.Now().Add(10 * time.Second))
			if socket.WriteMessage(websocket.BinaryMessage, frame.Data) != nil {
				return
			}
		}
		if reader.Err() == nil && request.Context().Err() == nil {
			// A terminal ending normally is different from a broken WebSocket. Native
			// clients use this close code to show a settled session instead of an error.
			_ = socket.WriteControl(websocket.CloseMessage,
				websocket.FormatCloseMessage(websocket.CloseNormalClosure, "Session ended"), time.Now().Add(time.Second))
		}
	}()
	for {
		kind, data, err := socket.ReadMessage()
		if err != nil {
			break
		}
		var frame terminalFrame
		switch kind {
		case websocket.BinaryMessage:
			if len(data) == 0 {
				continue
			}
			frame = terminalFrame{Kind: "input", Data: data}
		case websocket.TextMessage:
			if json.Unmarshal(data, &frame) != nil || frame.Kind != "resize" || frame.Data != nil || frame.Columns < 2 || frame.Columns > 500 || frame.Rows < 2 || frame.Rows > 300 {
				socket.Close()
				connection.Close()
				<-done
				return
			}
		default:
			continue
		}
		encoded, err := json.Marshal(frame)
		if err != nil {
			break
		}
		connection.SetWriteDeadline(time.Now().Add(10 * time.Second))
		if _, err = connection.Write(append(encoded, '\n')); err != nil {
			break
		}
	}
	connection.Close()
	socket.Close()
	<-done
}
