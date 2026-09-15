package gateway

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/coreos/go-oidc/v3/oidc"
	"github.com/go-jose/go-jose/v4"
)

type Principal struct {
	Subject       string
	EmailVerified bool
	Email         string
	IssuedAt      time.Time
	Expiry        time.Time
	TokenDigest   string
}

type Verifier struct {
	mu     sync.Mutex
	keys   map[string]oidc.KeySet
	keySet func(string) oidc.KeySet
}

func VerifierContext(ctx context.Context, client *http.Client) context.Context {
	return oidc.ClientContext(ctx, client)
}

func NewVerifier(ctx context.Context) *Verifier {
	return &Verifier{keys: make(map[string]oidc.KeySet), keySet: func(keyURL string) oidc.KeySet {
		return oidc.NewRemoteKeySet(ctx, keyURL)
	}}
}

func (verifier *Verifier) Verify(ctx context.Context, raw string, access Access) (Principal, error) {
	if raw == "" || len(raw) > maxToken {
		return Principal{}, errors.New("missing access assertion")
	}
	signed, err := jose.ParseSigned(raw, []jose.SignatureAlgorithm{jose.RS256, jose.ES256})
	if err != nil || len(signed.Signatures) != 1 {
		return Principal{}, errors.New("invalid signed token")
	}
	tokenType, _ := signed.Signatures[0].Protected.ExtraHeaders[jose.HeaderType].(string)
	permitted := false
	for _, expected := range access.tokenTypes() {
		if tokenType == expected {
			permitted = true
		}
	}
	if !permitted {
		return Principal{}, errors.New("incorrect token type")
	}
	verifier.mu.Lock()
	keys := verifier.keys[access.JWKSURL]
	if keys == nil {
		keys = verifier.keySet(access.JWKSURL)
		verifier.keys[access.JWKSURL] = keys
	}
	verifier.mu.Unlock()
	token, err := oidc.NewVerifier(access.Issuer, keys, &oidc.Config{
		ClientID: access.Audience, SupportedSigningAlgs: []string{oidc.RS256, oidc.ES256},
	}).Verify(ctx, raw)
	if err != nil {
		return Principal{}, errors.New("invalid access assertion")
	}
	var claims struct {
		Email         string `json:"email"`
		EmailVerified bool   `json:"email_verified"`
		Scope         string `json:"scope"`
		NotBefore     int64  `json:"nbf"`
	}
	if err = token.Claims(&claims); err != nil {
		return Principal{}, errors.New("invalid access claims")
	}
	now := time.Now()
	if token.Subject == "" || token.IssuedAt.Unix() <= 0 || token.IssuedAt.After(now.Add(time.Minute)) || claims.NotBefore > now.Unix() || len(token.Audience) != 1 {
		return Principal{}, errors.New("invalid access claims")
	}
	var allClaims map[string]any
	if token.Claims(&allClaims) != nil {
		return Principal{}, errors.New("invalid access claims")
	}
	for key, expected := range access.RequiredClaims {
		if actual, ok := allClaims[key].(string); !ok || actual != expected {
			return Principal{}, errors.New("required claim missing")
		}
	}
	scopes := strings.Fields(claims.Scope)
	for _, required := range access.RequiredScopes {
		found := false
		for _, scope := range scopes {
			if scope == required {
				found = true
			}
		}
		if !found {
			return Principal{}, errors.New("required scope missing")
		}
	}
	digest := sha256.Sum256([]byte(raw))
	principal := Principal{Subject: token.Subject, Email: strings.ToLower(claims.Email), EmailVerified: claims.EmailVerified, IssuedAt: token.IssuedAt, Expiry: token.Expiry, TokenDigest: hex.EncodeToString(digest[:])}
	if !principal.Allowed(access, now) {
		return Principal{}, errors.New("access denied")
	}
	return principal, nil
}

func (principal Principal) Allowed(access Access, now time.Time) bool {
	if !now.Before(principal.Expiry) {
		return false
	}
	if before, found := access.RevokedBefore[principal.Subject]; found && principal.IssuedAt.Unix() <= before {
		return false
	}
	for _, digest := range access.RevokedTokens {
		if digest == principal.TokenDigest {
			return false
		}
	}
	for _, subject := range access.AllowedSubjects {
		if subject == principal.Subject {
			return true
		}
	}
	if !principal.EmailVerified {
		return false
	}
	for _, email := range access.AllowedEmails {
		if email == principal.Email {
			return true
		}
	}
	return false
}
