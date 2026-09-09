package gateway

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/go-jose/go-jose/v4"
	"github.com/go-jose/go-jose/v4/jwt"
)

func TestProviderConfigurationAndPublicNativeMetadata(t *testing.T) {
	f := newFixture(t)
	f.config.OAuth = &OAuth{Issuer: f.config.Access.Issuer, AuthorizationEndpoint: f.config.Access.Issuer + "/authorize", TokenEndpoint: f.config.Access.Issuer + "/token", ClientID: "bloom-native", Scopes: []string{"openid", "bloom:control"}}
	if err := f.server.Reload(f.config); err != nil {
		t.Fatal(err)
	}
	response := f.request("GET", f.config.APIHost, "/.well-known/bloom-auth", "", "", "")
	if response.Code != 200 {
		t.Fatal(response.Code)
	}
	var metadata OAuth
	if err := json.Unmarshal(response.Body.Bytes(), &metadata); err != nil {
		t.Fatal(err)
	}
	if metadata.ClientID != "bloom-native" || metadata.RegistrationEndpoint != "" || metadata.Resource != "" {
		t.Fatal("configured native clients must not require registration or a resource parameter")
	}
	if strings.Contains(response.Body.String(), "owner@example.com") || strings.Contains(response.Body.String(), "runtime.sock") {
		t.Fatal("private configuration exposed")
	}
	if f.request("GET", f.config.APIHost, "/v1/info", "", "", "").Code != 401 {
		t.Fatal("discovery bypassed API authentication")
	}
	if f.request("GET", f.config.Previews[0].Host, "/.well-known/bloom-auth", "", "", "").Code != 401 {
		t.Fatal("discovery exposed on preview host")
	}
	if f.request("POST", f.config.APIHost, "/.well-known/bloom-auth", "", "", "").Code != 405 {
		t.Fatal("metadata accepted a mutation")
	}
	for _, issuer := range []string{"https://login.example/realms/bloom", "https://identity.example:9443/application/o/bloom/"} {
		config := f.config
		config.Access.Issuer = issuer
		config.Access.JWKSURL = issuer + "/jwks"
		config.OAuth = nil
		if err := config.Validate(); err != nil {
			t.Fatal(issuer, err)
		}
	}
	for _, issuer := range []string{"http://login.example", "https://user:secret@login.example", "https://login.example?x=1", "https://login.example#fragment", "https:///missing-host"} {
		config := f.config
		config.Access.Issuer = issuer
		if config.Validate() == nil {
			t.Fatal("unsafe issuer accepted", issuer)
		}
	}
	invalid := *f.config.OAuth
	invalid.TokenEndpoint = "https://unexpected.example/token"
	f.config.OAuth = &invalid
	if f.config.Validate() == nil {
		t.Fatal("endpoint authority change accepted")
	}
}

func TestSigningKeysComeOnlyFromAdministratorConfiguration(t *testing.T) {
	f := newFixture(t)
	var reads atomic.Int32
	keys := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/custom/keys" {
			t.Error("unconfigured key endpoint", r.URL.Path)
			http.NotFound(w, r)
			return
		}
		reads.Add(1)
		json.NewEncoder(w).Encode(jose.JSONWebKeySet{Keys: []jose.JSONWebKey{{Key: &f.key.PublicKey, Algorithm: "RS256", Use: "sig"}}})
	}))
	defer keys.Close()
	f.config.Access.JWKSURL = keys.URL + "/custom/keys"
	verifier := NewVerifier(VerifierContext(context.Background(), keys.Client()))
	if _, err := verifier.Verify(context.Background(), f.token(t, "control", nil), f.config.Access); err != nil {
		t.Fatal(err)
	}
	if reads.Load() != 1 {
		t.Fatal("configured JWKS was not used")
	}
	if _, err := verifier.Verify(context.Background(), f.token(t, "control", map[string]any{"iss": "https://attacker.invalid"}), f.config.Access); err == nil {
		t.Fatal("token selected its own issuer")
	}
	if reads.Load() != 1 {
		t.Fatal("invalid issuer triggered network discovery")
	}
}

func TestIDTokensAndCombinedAudiencesCannotBeUsedAsAccessTokens(t *testing.T) {
	f := newFixture(t)
	original := f.token(t, "control", nil)
	parsed, err := jwt.ParseSigned(original, []jose.SignatureAlgorithm{jose.RS256})
	if err != nil {
		t.Fatal(err)
	}
	var claims map[string]any
	if err = parsed.Claims(&f.key.PublicKey, &claims); err != nil {
		t.Fatal(err)
	}
	for _, typ := range []string{"JWT", "", "id+jwt"} {
		signer, err := jose.NewSigner(jose.SigningKey{Algorithm: jose.RS256, Key: f.key}, (&jose.SignerOptions{}).WithType(jose.ContentType(typ)))
		if err != nil {
			t.Fatal(err)
		}
		token, err := jwt.Signed(signer).Claims(claims).Serialize()
		if err != nil {
			t.Fatal(err)
		}
		if f.request("GET", f.config.APIHost, "/v1/info", token, "", "").Code != 401 {
			t.Fatal("ID token accepted", typ)
		}
	}
	combined := f.token(t, "control", map[string]any{"aud": []string{"control", "workspace-a"}})
	if f.request("GET", f.config.APIHost, "/v1/info", combined, "", "").Code != 401 {
		t.Fatal("combined audience accepted")
	}
}

func TestConfiguredAssertionsAndSubjectAllowlist(t *testing.T) {
	f := newFixture(t)
	f.config.Access.TokenHeader = "X-Bloom-Identity"
	f.config.Access.AllowedEmails = nil
	f.config.Access.AllowedSubjects = []string{"owner-id"}
	f.config.Access.RequiredClaims = map[string]string{"token_use": "access"}
	if err := f.server.Reload(f.config); err != nil {
		t.Fatal(err)
	}
	token := f.token(t, "control", map[string]any{"email": nil, "email_verified": nil, "token_use": "access"})
	request := httptest.NewRequest("GET", "/v1/info", nil)
	request.Host = f.config.APIHost
	request.Header.Set("X-Bloom-Identity", token)
	response := httptest.NewRecorder()
	f.server.ServeHTTP(response, request)
	if response.Code != 200 {
		t.Fatal(response.Code)
	}
	request.Header.Set("X-Bloom-Identity", f.token(t, "control", nil))
	response = httptest.NewRecorder()
	f.server.ServeHTTP(response, request)
	if response.Code != 401 {
		t.Fatal("missing access discriminator accepted")
	}
	request.Header.Set("X-Bloom-Identity", token)
	request.Header.Add("X-Bloom-Identity", token)
	response = httptest.NewRecorder()
	f.server.ServeHTTP(response, request)
	if response.Code != 401 {
		t.Fatal("ambiguous credentials accepted")
	}
}

func TestPreviewRemovesConfiguredProviderCredentials(t *testing.T) {
	f := newFixture(t)
	f.config.Previews[0].Access.TokenHeader = "X-Preview-Token"
	f.config.Previews[0].Access.SessionCookies = []string{"__Host-preview-auth"}
	f.backend(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("X-Preview-Token") != "" {
			t.Error("provider assertion reached application")
		}
		if _, err := r.Cookie("__Host-preview-auth"); err == nil {
			t.Error("provider session reached application")
		}
		if cookie, err := r.Cookie("laravel_session"); err != nil || cookie.Value != "app" {
			t.Error("application session was removed")
		}
		w.Header().Add("Set-Cookie", "__Host-preview-auth=attacker; Path=/; Secure")
		w.WriteHeader(200)
	}))
	request := httptest.NewRequest("GET", "/", nil)
	request.Host = f.config.Previews[0].Host
	request.Header.Set("X-Preview-Token", f.token(t, "workspace-a", nil))
	request.Header.Set("Cookie", "__Host-preview-auth=secret; laravel_session=app")
	response := httptest.NewRecorder()
	f.server.ServeHTTP(response, request)
	if response.Code != 200 || len(response.Result().Cookies()) != 0 {
		t.Fatal("preview could set provider session", response.Code, response.Header())
	}
}

func TestActivePolicyCannotBeChangedThroughCallerOwnedConfig(t *testing.T) {
	f := newFixture(t)
	token := f.token(t, "control", nil)
	f.config.Access.AllowedEmails[0] = "attacker@example.com"
	if f.request("GET", f.config.APIHost, "/v1/info", token, "", "").Code != 200 {
		t.Fatal("configuration mutation bypassed reload")
	}
	if f.request("GET", f.config.APIHost, "/v1/info", f.token(t, "control", map[string]any{"email": "attacker@example.com"}), "", "").Code != 401 {
		t.Fatal("configuration mutation granted access")
	}
}
