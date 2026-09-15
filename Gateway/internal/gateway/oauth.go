package gateway

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"strings"
)

// This is Bloom's public native-client configuration, not an OAuth discovery document
// impersonating the identity provider. Administrators pin the provider and client here.
type OAuth struct {
	Issuer                string   `json:"issuer"`
	AuthorizationEndpoint string   `json:"authorization_endpoint"`
	TokenEndpoint         string   `json:"token_endpoint"`
	RegistrationEndpoint  string   `json:"registration_endpoint,omitempty"`
	ClientID              string   `json:"client_id,omitempty"`
	Scopes                []string `json:"scopes"`
	Resource              string   `json:"resource,omitempty"`
}

func (oauth OAuth) validate(config Config) error {
	if oauth.Issuer != config.Access.Issuer {
		return errors.New("native login issuer must match the API token issuer")
	}
	issuer, _ := url.Parse(oauth.Issuer)
	for _, endpoint := range []string{oauth.AuthorizationEndpoint, oauth.TokenEndpoint, oauth.RegistrationEndpoint} {
		if endpoint == "" && endpoint == oauth.RegistrationEndpoint {
			continue
		}
		parsed, _ := url.Parse(endpoint)
		if !secureURL(endpoint) || parsed.Host != issuer.Host {
			return errors.New("OAuth endpoints must use the configured issuer's HTTPS authority")
		}
	}
	if oauth.AuthorizationEndpoint == "" || oauth.TokenEndpoint == "" {
		return errors.New("OAuth endpoints are required")
	}
	if oauth.ClientID == "" && oauth.RegistrationEndpoint == "" {
		return errors.New("configure a public native client ID or dynamic registration endpoint")
	}
	if oauth.ClientID == config.Access.Audience {
		return errors.New("native client ID must differ from the API audience")
	}
	if len(oauth.Scopes) == 0 {
		return errors.New("native OAuth scopes are required")
	}
	for _, scope := range oauth.Scopes {
		if scope == "" || strings.ContainsAny(scope, " \t\r\n") {
			return errors.New("invalid OAuth scope")
		}
	}
	for _, required := range config.Access.RequiredScopes {
		found := false
		for _, scope := range oauth.Scopes {
			if scope == required {
				found = true
			}
		}
		if !found {
			return errors.New("native login must request the API's required scopes")
		}
	}
	return nil
}

func (server *Server) oauthMetadata(writer http.ResponseWriter, request *http.Request, config Config) {
	if request.Method != http.MethodGet {
		writer.Header().Set("Allow", "GET")
		http.Error(writer, "Method not allowed", 405)
		return
	}
	if config.OAuth == nil || request.URL.RawQuery != "" {
		http.NotFound(writer, request)
		return
	}
	writer.Header().Set("Content-Type", "application/json")
	json.NewEncoder(writer).Encode(config.OAuth)
}
