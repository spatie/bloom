package gateway

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httputil"
	"net/url"
	"strings"
)

func writeInfo(writer http.ResponseWriter, config Config) {
	writer.Header().Set("Content-Type", "application/json")
	json.NewEncoder(writer).Encode(map[string]any{"serverID": config.ServerID, "protocolVersion": 9, "authentication": "oauth2", "capabilities": []string{"rpc", "private-previews"}})
}

func stripCredentials(header http.Header, access Access) {
	for name := range header {
		lower := strings.ToLower(name)
		if strings.HasPrefix(lower, "cf-") || lower == "authorization" || lower == "proxy-authorization" || lower == "forwarded" || strings.HasPrefix(lower, "x-forwarded-") {
			header.Del(name)
		}
	}
	values := (&http.Request{Header: header}).Cookies()
	header.Del("Cookie")
	for _, cookie := range values {
		if access.reservedCookie(cookie.Name) {
			continue
		}
		(&http.Request{Header: header}).AddCookie(cookie)
	}
}

func (server *Server) proxy(writer http.ResponseWriter, request *http.Request, preview Preview) {
	if request.Method == http.MethodConnect || request.Method == http.MethodTrace {
		http.Error(writer, "Method not allowed", 405)
		return
	}
	if strings.EqualFold(request.Header.Get("Upgrade"), "websocket") && request.Header.Get("Origin") == "" {
		http.Error(writer, "WebSocket origin required", 403)
		return
	}
	target := &url.URL{Scheme: "http", Host: "127.0.0.1:" + fmtPort(preview.Port)}
	writer.Header().Del("Cache-Control")
	request.Body = http.MaxBytesReader(writer, request.Body, maxBody)
	proxy := &httputil.ReverseProxy{
		Transport:     server.transport,
		FlushInterval: -1,
		Rewrite: func(proxy *httputil.ProxyRequest) {
			proxy.SetURL(target)
			stripCredentials(proxy.Out.Header, preview.Access)
			proxy.Out.Header.Del(preview.Access.header())
			proxy.Out.Host = preview.Host
			proxy.Out.Header.Set("X-Forwarded-Host", preview.Host)
			proxy.Out.Header.Set("X-Forwarded-Proto", "https")
		},
		ModifyResponse: func(response *http.Response) error {
			response.Header.Set("Cache-Control", "private, no-store")
			response.Header.Set("Referrer-Policy", "no-referrer")
			response.Header.Set("X-Content-Type-Options", "nosniff")
			for name := range response.Header {
				if strings.HasPrefix(strings.ToLower(name), "cf-access-") {
					response.Header.Del(name)
				}
			}
			cookies := response.Cookies()
			response.Header.Del("Set-Cookie")
			for _, cookie := range cookies {
				if preview.Access.reservedCookie(cookie.Name) {
					continue
				}
				cookie.Domain = ""
				cookie.Secure = true
				response.Header.Add("Set-Cookie", cookie.String())
			}
			if location := response.Header.Get("Location"); location != "" {
				parsed, err := url.Parse(location)
				if err != nil {
					return errors.New("invalid redirect")
				}
				host := strings.ToLower(parsed.Hostname())
				if host == "127.0.0.1" || host == "localhost" || host == "::1" || host == "0.0.0.0" {
					if parsed.Port() != fmtPort(preview.Port) {
						return errors.New("redirect points to an unregistered preview")
					}
					parsed.Scheme = "https"
					parsed.Host = preview.Host
					response.Header.Set("Location", parsed.String())
				}
			}
			return nil
		},
		ErrorHandler: func(writer http.ResponseWriter, request *http.Request, err error) {
			writer.Header().Set("Cache-Control", "no-store")
			http.Error(writer, "Preview unavailable", 502)
		},
	}
	proxy.ServeHTTP(writer, request)
}
