package gateway

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
)

type snapshot struct {
	config     Config
	generation uint64
}

type Server struct {
	state     atomic.Pointer[snapshot]
	verifier  *Verifier
	requests  chan struct{}
	transport *http.Transport
}

func New(config Config, verifier *Verifier) (*Server, error) {
	if err := config.Validate(); err != nil {
		return nil, err
	}
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.Proxy = nil
	transport.ResponseHeaderTimeout = 15 * time.Second
	transport.MaxConnsPerHost = 32
	transport.MaxIdleConnsPerHost = 8
	server := &Server{verifier: verifier, requests: make(chan struct{}, 64), transport: transport}
	server.state.Store(&snapshot{config: cloneConfig(config), generation: 1})
	return server, nil
}

func (server *Server) Reload(config Config) error {
	if err := config.Validate(); err != nil {
		return err
	}
	old := server.state.Load()
	if config.Listen != old.config.Listen || config.RuntimeSocket != old.config.RuntimeSocket || config.ServerID != old.config.ServerID {
		return errors.New("listener, runtime and server identity changes require a restart")
	}
	server.state.Store(&snapshot{config: cloneConfig(config), generation: old.generation + 1})
	return nil
}

func fmtPort(port int) string { return strconv.Itoa(port) }

func (server *Server) ServeHTTP(writer http.ResponseWriter, request *http.Request) {
	writer.Header().Set("Cache-Control", "no-store")
	writer.Header().Set("X-Content-Type-Options", "nosniff")
	writer.Header().Set("Referrer-Policy", "no-referrer")
	select {
	case server.requests <- struct{}{}:
		defer func() { <-server.requests }()
	default:
		http.Error(writer, "Too many requests", 429)
		return
	}
	state := server.state.Load()
	config := state.config
	// Route by the original, exact authority. Forwarded host headers never select a service.
	if request.URL.IsAbs() || strings.ContainsAny(request.Host, "/@\\") {
		http.Error(writer, "Invalid authority", 400)
		return
	}
	host := strings.TrimSuffix(request.Host, ":443")
	var preview *Preview
	access := config.Access
	if host != config.APIHost {
		for _, candidate := range config.Previews {
			if candidate.Host == host {
				copy := candidate
				preview = &copy
				access = copy.Access
				break
			}
		}
		if preview == nil {
			http.NotFound(writer, request)
			return
		}
	}
	origin := request.Header.Get("Origin")
	if origin != "" && origin != "https://"+host {
		allowed := false
		if preview != nil {
			for _, value := range preview.AllowedOrigins {
				if origin == value {
					allowed = true
				}
			}
		}
		if !allowed {
			http.Error(writer, "Origin denied", 403)
			return
		}
	}
	if preview == nil && request.URL.Path == "/.well-known/bloom-auth" {
		server.oauthMetadata(writer, request, config)
		return
	}
	assertions := request.Header.Values(access.header())
	if len(assertions) != 1 {
		http.Error(writer, "Authentication required", 401)
		return
	}
	raw := assertions[0]
	if strings.EqualFold(access.header(), "Authorization") {
		scheme, value, found := strings.Cut(raw, " ")
		if !found || !strings.EqualFold(scheme, "Bearer") || value == "" || strings.ContainsAny(value, " \t\r\n,") {
			http.Error(writer, "Bearer authentication required", 401)
			return
		}
		raw = value
	}
	principal, err := server.verifier.Verify(request.Context(), raw, access)
	if err != nil {
		http.Error(writer, "Authentication required", 401)
		return
	}
	if server.state.Load().generation != state.generation {
		http.Error(writer, "Access policy changed. Retry the request.", 403)
		return
	}
	ctx, cancel := context.WithDeadline(request.Context(), principal.Expiry)
	defer cancel()
	// Upgraded connections must lose access when policy is reloaded, not only on reconnect.
	go func() {
		ticker := time.NewTicker(250 * time.Millisecond)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				if server.state.Load().generation != state.generation {
					cancel()
					return
				}
			}
		}
	}()
	request = request.WithContext(ctx)
	if preview != nil {
		server.proxy(writer, request, *preview)
		return
	}
	if request.URL.Path == "/v1/terminal" {
		server.terminal(writer, request, config)
		return
	}
	writer.Header().Set("Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'")
	if request.URL.Path == "/v1/info" && request.Method == http.MethodGet && request.URL.RawQuery == "" {
		writeInfo(writer, config)
		return
	}
	server.rpc(writer, request, config, principal)
}

// A caller changing its config must never mutate the active policy without validation and
// a generation change, which also closes connections authorised under the old policy.
func cloneConfig(config Config) Config {
	data, _ := json.Marshal(config)
	var copy Config
	if err := json.Unmarshal(data, &copy); err != nil {
		panic(err)
	}
	return copy
}
