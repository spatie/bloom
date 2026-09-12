package gateway

import (
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/coreos/go-oidc/v3/oidc"
	"github.com/go-jose/go-jose/v4"
	"github.com/go-jose/go-jose/v4/jwt"
	"github.com/gorilla/websocket"
)

type fixture struct {
	config Config
	server *Server
	key    *rsa.PrivateKey
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	access := Access{Issuer: "https://identity.example/realms/bloom", JWKSURL: "https://identity.example/realms/bloom/certs", RequiredScopes: []string{"bloom:control"}, Audience: "control", AllowedEmails: []string{"owner@example.com"}}
	previewAccess := access
	previewAccess.Audience = "workspace-a"
	directory, err := os.MkdirTemp("/tmp", "bloom-gateway-test-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(directory) })
	config := Config{Listen: "127.0.0.1:18880", APIHost: "control.example.com", ServerID: "server-one", RuntimeSocket: filepath.Join(directory, "runtime.sock"), Access: access,
		Previews: []Preview{{Host: "app.preview.example.com", WorkspaceID: "workspace-a", Port: 18000, Access: previewAccess}}}
	verifier := &Verifier{keys: map[string]oidc.KeySet{}, keySet: func(string) oidc.KeySet { return &oidc.StaticKeySet{PublicKeys: []crypto.PublicKey{&key.PublicKey}} }}
	server, err := New(config, verifier)
	if err != nil {
		t.Fatal(err)
	}
	return &fixture{config: config, server: server, key: key}
}

func (f *fixture) token(t *testing.T, audience string, changes map[string]any) string {
	t.Helper()
	claims := map[string]any{"iss": f.config.Access.Issuer, "aud": []string{audience}, "sub": "owner-id", "email": "owner@example.com", "email_verified": true, "scope": "bloom:control", "iat": time.Now().Add(-time.Second).Unix(), "exp": time.Now().Add(time.Minute).Unix()}
	for key, value := range changes {
		if value == nil {
			delete(claims, key)
		} else {
			claims[key] = value
		}
	}
	signer, err := jose.NewSigner(jose.SigningKey{Algorithm: jose.RS256, Key: f.key}, (&jose.SignerOptions{}).WithType("at+jwt"))
	if err != nil {
		t.Fatal(err)
	}
	token, err := jwt.Signed(signer).Claims(claims).Serialize()
	if err != nil {
		t.Fatal(err)
	}
	return token
}

func (f *fixture) request(method, host, path, token, origin, body string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(method, "https://"+host+path, strings.NewReader(body))
	r.Host = host
	// Real HTTP servers put the origin-form URI in URL; an absolute-form request is refused.
	r.URL.Scheme = ""
	r.URL.Host = ""
	if token != "" {
		r.Header.Set("Authorization", "Bearer "+token)
	}
	if origin != "" {
		r.Header.Set("Origin", origin)
	}
	r.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	f.server.ServeHTTP(w, r)
	return w
}

func TestAccessRejectsInvalidIdentity(t *testing.T) {
	f := newFixture(t)
	cases := map[string]map[string]any{
		"wrong issuer": {"iss": "https://attacker.example"}, "wrong audience": {"aud": []string{"preview"}},
		"expired": {"exp": time.Now().Add(-time.Hour).Unix()}, "no expiry": {"exp": nil}, "no subject": {"sub": ""},
		"no issue time": {"iat": nil}, "future issue time": {"iat": time.Now().Add(time.Hour).Unix()},
		"not yet valid": {"nbf": time.Now().Add(time.Hour).Unix()}, "wrong user": {"email": "attacker@example.com"}, "unverified email": {"email_verified": false}, "missing verification": {"email_verified": nil}, "missing scope": {"scope": nil},
	}
	for name, claims := range cases {
		t.Run(name, func(t *testing.T) {
			response := f.request("GET", f.config.APIHost, "/v1/info", f.token(t, "control", claims), "", "")
			if response.Code != 401 {
				t.Fatalf("got %d", response.Code)
			}
		})
	}
	for _, token := range []string{"", "not-a-token", strings.Repeat("x", maxToken+1), f.token(t, "control", nil) + "forged"} {
		if code := f.request("GET", f.config.APIHost, "/v1/info", token, "", "").Code; code != 401 {
			t.Fatalf("invalid token got %d", code)
		}
	}
	if code := f.request("GET", f.config.APIHost, "/v1/info", f.token(t, "control", nil), "", "").Code; code != 200 {
		t.Fatal(code)
	}
}

func TestPreviewCredentialCannotControlAgents(t *testing.T) {
	f := newFixture(t)
	response := f.request("POST", f.config.APIHost, "/v1/rpc", f.token(t, "workspace-a", nil), "", `{"version":13,"id":"00000000-0000-0000-0000-000000000001","operation":{"catalogue":{}}}`)
	if response.Code != 401 {
		t.Fatal(response.Code)
	}
	response = f.request("GET", f.config.Previews[0].Host, "/", f.token(t, "control", nil), "", "")
	if response.Code != 401 {
		t.Fatal(response.Code)
	}
}

func TestCrossOriginAPIAndUnknownHostsAreDenied(t *testing.T) {
	f := newFixture(t)
	token := f.token(t, "control", nil)
	for _, origin := range []string{"null", "https://evil.example", "https://app.preview.example.com", "https://control.example.com.evil.test"} {
		if code := f.request("GET", f.config.APIHost, "/v1/info", token, origin, "").Code; code != 403 {
			t.Fatal(origin, code)
		}
	}
	if code := f.request("GET", "unknown.example.com", "/v1/info", token, "", "").Code; code != 404 {
		t.Fatal(code)
	}
	r := httptest.NewRequest("GET", "/v1/info", nil)
	r.Host = "evil.example.com"
	r.Header.Set("X-Forwarded-Host", f.config.APIHost)
	r.Header.Set("Authorization", "Bearer "+token)
	w := httptest.NewRecorder()
	f.server.ServeHTTP(w, r)
	if w.Code != 404 {
		t.Fatal(w.Code)
	}
}

func TestRevocationAndFailedReload(t *testing.T) {
	f := newFixture(t)
	token := f.token(t, "control", nil)
	digest := sha256.Sum256([]byte(token))
	revoked := f.config
	revoked.Access.RevokedTokens = []string{hex.EncodeToString(digest[:])}
	if err := f.server.Reload(revoked); err != nil {
		t.Fatal(err)
	}
	if code := f.request("GET", f.config.APIHost, "/v1/info", token, "", "").Code; code != 401 {
		t.Fatal(code)
	}
	invalid := f.config
	invalid.Access.AllowedEmails = nil
	if err := f.server.Reload(invalid); err == nil {
		t.Fatal("invalid reload accepted")
	}
	if code := f.request("GET", f.config.APIHost, "/v1/info", token, "", "").Code; code != 401 {
		t.Fatal("failed reload removed revocation")
	}
	revoked = f.config
	revoked.Access.RevokedBefore = map[string]int64{"owner-id": time.Now().Unix()}
	if err := f.server.Reload(revoked); err != nil {
		t.Fatal(err)
	}
	if code := f.request("GET", f.config.APIHost, "/v1/info", token, "", "").Code; code != 401 {
		t.Fatal(code)
	}
}

func (f *fixture) backend(t *testing.T, handler http.Handler) *httptest.Server {
	t.Helper()
	backend := httptest.NewServer(handler)
	t.Cleanup(backend.Close)
	parsed, _ := url.Parse(backend.URL)
	port, _ := strconv.Atoi(parsed.Port())
	f.config.Previews[0].Port = port
	if err := f.server.Reload(f.config); err != nil {
		t.Fatal(err)
	}
	return backend
}

func TestPreviewStripsCredentialsAndScopesCookies(t *testing.T) {
	f := newFixture(t)
	f.backend(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		for _, key := range []string{"Authorization", "Cf-Access-Jwt-Assertion", "Cf-Access-Token", "Proxy-Authorization"} {
			if r.Header.Get(key) != "" {
				t.Errorf("leaked %s", key)
			}
		}
		if r.Header.Get("Cookie") != "laravel_session=application" {
			t.Errorf("cookies: %s", r.Header.Get("Cookie"))
		}
		if r.Host != f.config.Previews[0].Host || r.Header.Get("X-Forwarded-Proto") != "https" {
			t.Error("wrong origin")
		}
		w.Header().Add("Set-Cookie", "session=abc; Domain=.example.com; HttpOnly")
		w.Header().Add("Set-Cookie", "CF_Authorization=stolen; Domain=.example.com")
		w.Header().Set("Cache-Control", "public, max-age=9999")
		fmt.Fprint(w, "preview")
	}))
	r := httptest.NewRequest("GET", "/test?query=preserved", nil)
	r.Host = f.config.Previews[0].Host
	r.Header.Set("Authorization", "Bearer "+f.token(t, "workspace-a", nil))
	r.Header.Set("Cf-Access-Jwt-Assertion", "sensitive")
	r.Header.Set("Cf-Access-Token", "secret")
	r.Header.Set("Cookie", "CF_Authorization=secret; laravel_session=application; bloom_control=secret")
	w := httptest.NewRecorder()
	f.server.ServeHTTP(w, r)
	if w.Code != 200 {
		t.Fatal(w.Code, w.Body.String())
	}
	cookies := w.Result().Cookies()
	if len(cookies) != 1 || cookies[0].Domain != "" || !cookies[0].Secure || !cookies[0].HttpOnly {
		t.Fatalf("unsafe cookies: %#v", cookies)
	}
	if w.Header().Get("Cache-Control") != "private, no-store" {
		t.Fatal("preview was cacheable")
	}
}

func TestPrivateRedirectsAndPreviewResolution(t *testing.T) {
	f := newFixture(t)
	f.backend(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Location", "http://localhost:"+fmtPort(f.config.Previews[0].Port)+"/next?q=x")
		w.WriteHeader(302)
	}))
	w := f.request("GET", f.config.Previews[0].Host, "/", f.token(t, "workspace-a", nil), "", "")
	if w.Header().Get("Location") != "https://app.preview.example.com/next?q=x" {
		t.Fatal(w.Header())
	}
	principal := Principal{EmailVerified: true, Subject: "owner-id", Email: "owner@example.com", Expiry: time.Now().Add(time.Hour)}
	resolved, err := resolvePreview("http://localhost:"+fmtPort(f.config.Previews[0].Port)+"/a%20b?q=x#section", f.config, principal)
	if err != nil || resolved != "https://app.preview.example.com/a%20b?q=x#section" {
		t.Fatal(resolved, err)
	}
	if _, err = resolvePreview("http://localhost:59999/", f.config, principal); err == nil {
		t.Fatal("unregistered port was accepted")
	}
}

func TestWebSocketExpiresAndRevokes(t *testing.T) {
	for _, mode := range []string{"expiry", "revocation"} {
		t.Run(mode, func(t *testing.T) {
			f := newFixture(t)
			f.backend(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				upgrader := websocket.Upgrader{}
				connection, err := upgrader.Upgrade(w, r, nil)
				if err != nil {
					return
				}
				defer connection.Close()
				for {
					kind, data, err := connection.ReadMessage()
					if err != nil {
						return
					}
					if connection.WriteMessage(kind, data) != nil {
						return
					}
				}
			}))
			gateway := httptest.NewServer(f.server)
			defer gateway.Close()
			changes := map[string]any{}
			if mode == "expiry" {
				changes["exp"] = time.Now().Add(2 * time.Second).Unix()
			}
			header := http.Header{"Host": []string{f.config.Previews[0].Host}, "Origin": []string{"https://" + f.config.Previews[0].Host}, "Authorization": []string{"Bearer " + f.token(t, "workspace-a", changes)}}
			connection, response, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(gateway.URL, "http")+"/hmr", header)
			if err != nil {
				if response != nil {
					body, _ := io.ReadAll(response.Body)
					t.Fatal(err, string(body))
				}
				t.Fatal(err)
			}
			defer connection.Close()
			connection.WriteMessage(websocket.TextMessage, []byte("hot reload"))
			_, body, err := connection.ReadMessage()
			if err != nil || string(body) != "hot reload" {
				t.Fatal(string(body), err)
			}
			if mode == "revocation" {
				config := f.config
				config.Previews = append([]Preview(nil), config.Previews...)
				config.Previews[0].Access.RevokedBefore = map[string]int64{"owner-id": time.Now().Unix()}
				if err = f.server.Reload(config); err != nil {
					t.Fatal(err)
				}
			}
			connection.SetReadDeadline(time.Now().Add(4 * time.Second))
			if _, _, err = connection.ReadMessage(); err == nil {
				t.Fatal("connection survived revoked/expired access")
			}
			if networkError, ok := err.(net.Error); ok && networkError.Timeout() {
				t.Fatal("gateway did not actively close revoked/expired connection")
			}
		})
	}
}

func TestVerifierChecksSignatures(t *testing.T) {
	f := newFixture(t)
	other := newFixture(t)
	if _, err := f.server.verifier.Verify(context.Background(), other.token(t, "control", nil), f.config.Access); err == nil {
		t.Fatal("forged signature accepted")
	}
}
