package gateway

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

type Access struct {
	JWKSURL         string            `json:"jwks_url"`
	SessionCookies  []string          `json:"session_cookies,omitempty"`
	TokenHeader     string            `json:"token_header,omitempty"`
	TokenTypes      []string          `json:"token_types,omitempty"`
	RequiredClaims  map[string]string `json:"required_claims,omitempty"`
	RequiredScopes  []string          `json:"required_scopes,omitempty"`
	AllowedSubjects []string          `json:"allowed_subjects,omitempty"`
	Issuer          string            `json:"issuer"`
	Audience        string            `json:"audience"`
	AllowedEmails   []string          `json:"allowed_emails"`
	RevokedBefore   map[string]int64  `json:"revoked_before,omitempty"`
	RevokedTokens   []string          `json:"revoked_tokens,omitempty"`
}

type Preview struct {
	Host           string   `json:"host"`
	WorkspaceID    string   `json:"workspace_id"`
	Port           int      `json:"port"`
	Access         Access   `json:"access"`
	AllowedOrigins []string `json:"allowed_origins,omitempty"`
}

type Config struct {
	Listen        string    `json:"listen"`
	APIHost       string    `json:"api_host"`
	ServerID      string    `json:"server_id"`
	RuntimeSocket string    `json:"runtime_socket"`
	Access        Access    `json:"access"`
	OAuth         *OAuth    `json:"oauth,omitempty"`
	Previews      []Preview `json:"previews"`
}

func LoadConfig(path string) (Config, error) {
	file, err := os.Open(path)
	if err != nil {
		return Config{}, err
	}
	defer file.Close()
	decoder := json.NewDecoder(io.LimitReader(file, 1<<20))
	decoder.DisallowUnknownFields()
	var config Config
	if err := decoder.Decode(&config); err != nil {
		return config, err
	}
	if err := decoder.Decode(new(any)); err != io.EOF {
		return config, errors.New("configuration must contain one JSON object")
	}
	return config, config.Validate()
}

func validHost(host string) bool {
	if host != strings.ToLower(host) || strings.HasSuffix(host, ".") || !strings.Contains(host, ".") {
		return false
	}
	for _, label := range strings.Split(host, ".") {
		if len(label) == 0 || len(label) > 63 || label[0] == '-' || label[len(label)-1] == '-' {
			return false
		}
		for _, ch := range label {
			if !(ch >= 'a' && ch <= 'z' || ch >= '0' && ch <= '9' || ch == '-') {
				return false
			}
		}
	}
	return len(host) <= 253
}

// A private deployment can use a dedicated HTTPS port without rewriting its authority.
func validAuthority(authority string) bool {
	if !strings.Contains(authority, ":") {
		return validHost(authority)
	}
	host, port, err := net.SplitHostPort(authority)
	number, parseErr := strconv.Atoi(port)
	return err == nil && parseErr == nil && validHost(host) && number > 0 && number <= 65535 && number != 443 && strconv.Itoa(number) == port
}

func secureURL(value string) bool {
	parsed, err := url.Parse(value)
	return err == nil && parsed.Scheme == "https" && parsed.Hostname() != "" && parsed.User == nil && parsed.RawQuery == "" && !parsed.ForceQuery && parsed.Fragment == ""
}

func (access Access) header() string {
	if access.TokenHeader == "" {
		return "Authorization"
	}
	return access.TokenHeader
}

func (access Access) tokenTypes() []string {
	if len(access.TokenTypes) == 0 {
		return []string{"at+jwt", "application/at+jwt"}
	}
	return access.TokenTypes
}

func (access Access) validate() error {
	if !secureURL(access.Issuer) || !secureURL(access.JWKSURL) {
		return errors.New("issuer and signing-key URL must be explicit HTTPS URLs without credentials, query or fragment")
	}
	for _, cookie := range access.SessionCookies {
		if !httpToken(strings.ReplaceAll(cookie, "_", "-")) {
			return errors.New("invalid authentication cookie name")
		}
		if strings.ContainsAny(cookie, " ;=\r\n\t") || cookie == "" {
			return errors.New("invalid authentication cookie name")
		}
	}
	header := httpToken(access.header())
	if !header || strings.EqualFold(access.header(), "Cookie") || strings.EqualFold(access.header(), "Host") || strings.EqualFold(access.header(), "Origin") {
		return errors.New("invalid signed-token header")
	}
	for _, tokenType := range access.tokenTypes() {
		if tokenType != "at+jwt" && tokenType != "application/at+jwt" && (tokenType != "JWT" || len(access.RequiredClaims) == 0) {
			return errors.New("JWT assertions require explicit claims distinguishing them from ID tokens")
		}
	}
	for key, value := range access.RequiredClaims {
		if key == "" || value == "" {
			return errors.New("required token claims cannot be empty")
		}
	}
	for _, scope := range access.RequiredScopes {
		if scope == "" || strings.ContainsAny(scope, " \t\r\n") {
			return errors.New("invalid required scope")
		}
	}
	if access.Audience == "" || len(access.AllowedEmails)+len(access.AllowedSubjects) == 0 {
		return errors.New("token audience and an explicit user allowlist are required")
	}
	for _, subject := range access.AllowedSubjects {
		if strings.TrimSpace(subject) == "" || subject == "*" {
			return errors.New("allowlist subjects must be explicit")
		}
	}

	for _, email := range access.AllowedEmails {
		if email != strings.ToLower(strings.TrimSpace(email)) || !strings.Contains(email, "@") || strings.ContainsAny(email, "*\r\n") {
			return errors.New("allowlist entries must be explicit lower-case email addresses")
		}
	}
	for _, digest := range access.RevokedTokens {
		if len(digest) != 64 || strings.Trim(digest, "0123456789abcdef") != "" {
			return errors.New("revoked tokens must be SHA-256 hex digests")
		}
	}
	return nil
}

func (config Config) Validate() error {
	host, port, err := net.SplitHostPort(config.Listen)
	if err != nil || host != "127.0.0.1" || port == "0" {
		return errors.New("gateway must listen on a fixed IPv4 loopback port")
	}
	if number, err := strconv.Atoi(port); err != nil || number < 1 || number > 65535 || strconv.Itoa(number) != port {
		return errors.New("invalid gateway listen port")
	}
	if !validAuthority(config.APIHost) || config.ServerID == "" {
		return errors.New("API hostname and stable server ID are required")
	}
	if !filepath.IsAbs(config.RuntimeSocket) {
		return errors.New("runtime socket must be an absolute path")
	}
	if err := config.Access.validate(); err != nil {
		return err
	}
	if config.OAuth != nil {
		if err := config.OAuth.validate(config); err != nil {
			return err
		}
	}
	hosts := map[string]bool{config.APIHost: true}
	apiURL, _ := url.Parse("https://" + config.APIHost)
	cookieHosts := map[string]string{apiURL.Hostname(): ""}
	ports := map[int]bool{}
	audiences := map[string]string{}
	for _, preview := range config.Previews {
		if !validAuthority(preview.Host) || hosts[preview.Host] || preview.WorkspaceID == "" || preview.Port < 1024 || preview.Port > 65535 {
			return errors.New("preview requires a unique hostname, workspace ID and unprivileged port")
		}
		previewURL, _ := url.Parse("https://" + preview.Host)
		if owner, found := cookieHosts[previewURL.Hostname()]; found && owner != preview.WorkspaceID {
			return errors.New("host-only cookies require separate hostnames for control and different workspaces")
		}
		cookieHosts[previewURL.Hostname()] = preview.WorkspaceID
		hosts[preview.Host] = true
		if ports[preview.Port] || fmtPort(preview.Port) == port {
			return errors.New("preview ports must be unique and cannot target the gateway")
		}
		ports[preview.Port] = true
		if workspace, found := audiences[preview.Access.Audience]; found && workspace != preview.WorkspaceID {
			return errors.New("different workspaces need different preview token audiences")
		}
		audiences[preview.Access.Audience] = preview.WorkspaceID
		if preview.Access.Audience == config.Access.Audience {
			return errors.New("preview and agent-control token audiences must differ")
		}
		if err := preview.Access.validate(); err != nil {
			return fmt.Errorf("preview %s: %w", preview.Host, err)
		}
	}
	for _, preview := range config.Previews {
		for _, origin := range preview.AllowedOrigins {
			parsed, err := url.Parse(origin)
			if err != nil || parsed.Scheme != "https" || parsed.User != nil || parsed.Path != "" || parsed.RawQuery != "" || parsed.Fragment != "" || !hosts[parsed.Host] || parsed.Host == config.APIHost {
				return errors.New("preview origins must name configured preview HTTPS hosts")
			}
			for _, other := range config.Previews {
				if other.Host == parsed.Host && other.WorkspaceID != preview.WorkspaceID {
					return errors.New("preview origins cannot cross workspace boundaries")
				}
			}
		}
	}
	return nil
}

const maxBody = 16 << 20
const maxToken = 16 << 10
const rpcTimeout = 660 * time.Second

func httpToken(value string) bool {
	if value == "" {
		return false
	}
	for _, ch := range value {
		if !(ch >= 'a' && ch <= 'z' || ch >= 'A' && ch <= 'Z' || ch >= '0' && ch <= '9' || ch == '-') {
			return false
		}
	}
	return true
}

func (access Access) reservedCookie(name string) bool {
	lower := strings.ToLower(name)
	if lower == "cf_authorization" || strings.HasPrefix(lower, "bloom_") {
		return true
	}
	for _, cookie := range access.SessionCookies {
		if name == cookie {
			return true
		}
	}
	return false
}
