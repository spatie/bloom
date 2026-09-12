package gateway

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"
)

type rpcRequest struct {
	Version   int                        `json:"version"`
	ID        string                     `json:"id"`
	Operation map[string]json.RawMessage `json:"operation"`
}

func runtimeRequest(ctx context.Context, socket string, body []byte, id string) ([]byte, error) {
	connection, err := (&net.Dialer{Timeout: 5 * time.Second}).DialContext(ctx, "unix", socket)
	if err != nil {
		return nil, err
	}
	defer connection.Close()
	stop := context.AfterFunc(ctx, func() { connection.Close() })
	defer stop()
	if deadline, ok := ctx.Deadline(); ok {
		connection.SetDeadline(deadline)
	}
	if _, err = connection.Write(append(body, '\n')); err != nil {
		return nil, err
	}
	reader := bufio.NewReader(io.LimitReader(connection, maxBody+1))
	line, err := reader.ReadBytes('\n')
	if err != nil || len(line) > maxBody {
		return nil, errors.New("invalid runtime response")
	}
	var reply struct {
		ID      string          `json:"id"`
		Version int             `json:"version"`
		Result  json.RawMessage `json:"result"`
	}
	if json.Unmarshal(line, &reply) != nil || !strings.EqualFold(reply.ID, id) || reply.Version != protocolVersion || len(reply.Result) == 0 {
		return nil, errors.New("invalid runtime response")
	}
	return line, nil
}

func (server *Server) rpc(writer http.ResponseWriter, request *http.Request, config Config, principal Principal) {
	if request.URL.Path != "/v1/rpc" || request.URL.RawQuery != "" {
		http.NotFound(writer, request)
		return
	}
	if request.Method != http.MethodPost {
		writer.Header().Set("Allow", "POST")
		http.Error(writer, "Method not allowed", 405)
		return
	}
	if media := strings.Split(request.Header.Get("Content-Type"), ";")[0]; media != "application/json" {
		http.Error(writer, "JSON required", 415)
		return
	}
	body, err := io.ReadAll(http.MaxBytesReader(writer, request.Body, maxBody))
	if err != nil {
		http.Error(writer, "Request too large", 413)
		return
	}
	var input rpcRequest
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&input) != nil || input.Version != protocolVersion || len(input.ID) != 36 || len(input.Operation) != 1 {
		http.Error(writer, "Invalid Bloom request", 400)
		return
	}
	if decoder.Decode(new(any)) != io.EOF {
		http.Error(writer, "Invalid Bloom request", 400)
		return
	}
	// Compact before forwarding so a JSON string cannot inject another protocol line.
	var compact bytes.Buffer
	if json.Compact(&compact, body) != nil {
		http.Error(writer, "Invalid Bloom request", 400)
		return
	}
	if raw, found := input.Operation["previewAddress"]; found {
		var address struct {
			Value string `json:"_0"`
		}
		if json.Unmarshal(raw, &address) != nil {
			http.Error(writer, "Invalid preview address", 400)
			return
		}
		result, err := resolvePreview(address.Value, config, principal)
		value := map[string]any{"text": map[string]string{"_0": result}}
		if err != nil {
			value = map[string]any{"failure": map[string]string{"_0": err.Error()}}
		}
		writer.Header().Set("Content-Type", "application/json")
		json.NewEncoder(writer).Encode(map[string]any{"version": protocolVersion, "id": input.ID, "result": value})
		return
	}
	ctx, cancel := context.WithTimeout(request.Context(), rpcTimeout)
	defer cancel()
	reply, err := runtimeRequest(ctx, config.RuntimeSocket, compact.Bytes(), input.ID)
	if err != nil {
		http.Error(writer, "Runtime unavailable. Refresh before retrying this command with the same request ID.", 502)
		return
	}
	writer.Header().Set("Content-Type", "application/json")
	writer.Write(reply)
}

func resolvePreview(address string, config Config, principal Principal) (string, error) {
	parsed, err := url.Parse(address)
	if err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") || parsed.User != nil {
		return "", errors.New("Enter an HTTP or HTTPS preview address.")
	}
	host := strings.ToLower(parsed.Hostname())
	if host != "localhost" && host != "127.0.0.1" && host != "::1" && host != "0.0.0.0" {
		return address, nil
	}
	port := parsed.Port()
	if port == "" {
		port = "80"
		if parsed.Scheme == "https" {
			port = "443"
		}
	}
	for _, preview := range config.Previews {
		if parsed.Scheme == "http" && port == fmtPort(preview.Port) && principal.Allowed(preview.Access, time.Now()) {
			parsed.Scheme = "https"
			parsed.Host = preview.Host
			return parsed.String(), nil
		}
	}
	return "", errors.New("Register this workspace's preview port with the HTTPS gateway before opening it.")
}
