# Bloom HTTPS gateway

The gateway carries Bloom's existing RPC and terminal protocol over HTTPS. Authentication is
configured by the server administrator and has no mandatory Cloudflare, DNS or VPN provider.
Local workspaces and SSH connections continue to use their existing transports.

## Configuration

Start with `deploy/config.example.json` and replace every example value with your provider's
actual configuration. The endpoint paths are illustrative, not a tested preset for a particular
identity product. Run `go run ./cmd/bloom-gateway --config /absolute/path/config.json` behind an
HTTPS reverse proxy such as Caddy. The gateway deliberately accepts only a fixed loopback listener.
The reverse proxy must preserve the original Host and support WebSocket upgrades. `api_host`
and preview `host` may include an explicit HTTPS port, such as `server.example.com:8443`.
Omit the default `:443`. Origins and preview URLs retain a configured non-default port.
Different workspaces and agent control require different hostnames because cookies ignore ports.
For an identity provider using a private CA, pass `--identity-ca-file /path/to/ca.pem`.
The gateway still verifies certificate chains and hostnames; it never disables TLS verification. Do not expose
the runtime socket or development ports to the internet.

Configure a public native OAuth client with authorisation-code flow, PKCE S256 and no client
secret. On macOS, AppAuth uses an ephemeral loopback redirect. The provider must permit arbitrary
ports for its registered loopback redirect URI, as required by RFC 8252. Native iOS callbacks
will need their own registered redirect and platform integration; this is not an iOS client yet.

`oauth.client_id` supports a pre-registered client. Alternatively, provide
`oauth.registration_endpoint` for dynamic public-client registration. The selected Bloom server
publishes these public settings at `/.well-known/bloom-auth`. This is Bloom configuration, not a
replacement for the provider's OIDC discovery document. Endpoints must share the issuer's HTTPS
authority. Issuer paths and non-default HTTPS ports are supported. Add `oauth.resource` only if
the provider needs an RFC 8707 resource parameter. Bloom preserves it during token refresh.

`access` pins the exact issuer, JWKS URL and API audience. The native client ID must differ from
the API audience. Providers must issue signed access tokens with:

- RS256 or ES256 signatures, a subject, issue time, expiry and exactly the configured audience.
- An `at+jwt` or `application/at+jwt` protected header by default.
- Every configured `required_scopes` entry in the space-separated `scope` claim.
- An explicitly allowed subject, or an allowed email with `email_verified: true`.

For providers using a `JWT` header instead, set `token_types: ["JWT"]` and explicit
`required_claims` that distinguish access tokens from ID tokens, for example
`{"token_use":"access"}` where that is the provider's documented access-token marker.
These fields must match the actual provider; do not disable validation to accept an arbitrary
JWT. Opaque tokens and introspection are not implemented. Provider-independent means a documented
configurable integration contract, not automatic compatibility with every OAuth product.

By default the gateway reads `Authorization: Bearer ...`. An established authentication proxy
can instead supply a signed assertion in a configured `token_header`. Bloom still verifies the
signature, issuer, audience and user allowlist. Unsigned identity headers are never sufficient.
The proxy must remove client-supplied copies before injecting that header.

Credentials live in the Mac app's Keychain. Preferences store only the server address. The native
transport refuses HTTP redirects carrying bearer credentials. Local sign-out removes local
credentials; provider-side session revocation remains the identity provider's responsibility.

## Managed server updates

For a supervised Bloom installation, set `runtime_socket` to its root-owned
`/run/bloom-maintenance/<server-fingerprint>.sock` instead of the runtime's temporary socket.
The supervisor forwards ordinary RPCs and serves maintenance status while the runtime restarts.
It also answers connection negotiation during that interval, so a newly opened client can
recover the same update job. The [maintenance protocol](../docs/SERVER-MAINTENANCE.md) is shared
by native and web clients.

Give the dedicated gateway service access to the socket's group, for example with
`SupplementaryGroups=bloom`. For terminal streaming, set `gateway_group_id` in the protected
supervisor configuration to that shared group ID. The runtime continues to keep agent and
database files private. Do not make either control socket world-accessible.

Gateway OAuth access is still required. A maintenance request additionally carries the separate
maintenance key, which the supervisor verifies. Ordinary workspace access does not grant update
authority. Keep this key out of browser persistent storage, logs and preview pages; a web panel
should retain administrative credentials on its backend and protect its own session and CSRF
boundary. Responses retain `Cache-Control: no-store`.

## Browser previews

Register each preview explicitly with a hostname, workspace ID, loopback port and its own
`access` policy. A workspace's application and Vite host can share a preview audience. Different
workspaces and agent control must have different audiences. Only explicitly listed
`allowed_origins` from the same workspace may make cross-origin preview requests.

A browser does not attach the native app's bearer token. An established OAuth authentication
proxy must handle browser login and sessions, then supply a preview-scoped signed token to the
gateway. This login proxy is deployment work still to be configured and tested with a chosen
provider. Do not put the agent-control token into browser storage, URLs or preview cookies.

List that proxy's cookie names in each preview's `access.session_cookies`, such as
`["__Host-preview-auth"]`. The gateway strips those cookies and the configured token header
before forwarding requests, and prevents the preview application from setting those cookies.
Application cookies become Secure and host-only. Public development ports are never needed.

## Revocation and isolation

Configuration must be administrator-owned, outside agent-writable directories. Use separate
unprivileged service users for the gateway and runtime. `BLOOM_SERVER_GATEWAY_GID` can grant only
the runtime and terminal sockets to a dedicated group, with mode 0660. Other sockets remain 0600.
Treat access to the runtime socket as full agent-control authority.

Update `revoked_before` by subject or `revoked_tokens` with a token's SHA-256 hex digest and send
SIGHUP. Valid reloads close existing HTTP and WebSocket connections; invalid reloads keep the
previous policy. Connections also expire with their tokens. Removing the user from the local
allowlist takes effect on reload. Provider revocation alone may leave a signed token valid until
its expiry, so use short-lived tokens and local revocation for immediate removal.

## Verification

Run `go test -race ./...` and `go vet ./...`. The suite exercises real JWT signatures and HTTPS
JWKS retrieval, hostile identities, ID-token substitution, audience separation, invalid headers,
RPC boundaries, WebSocket expiry/revocation and terminal byte transport. Core Swift tests cover
native metadata validation, HTTPS replies and persistent tmux reconnection.

The gateway is still a development implementation. An isolated integration run now exercises
Keycloak 26.7.3, Caddy and OAuth2 Proxy 7.15.0 with the actual Mac authentication code, Keychain,
refresh flow, standalone runtime and browser WebSockets. See
[HTTPS validation](../docs/HTTPS-VALIDATION.md) for results and limits. No public identity provider
is deployed. Physical iOS verification and independent security review remain outstanding.

Standards: [JWT access tokens](https://www.rfc-editor.org/rfc/rfc9068.html),
[native OAuth](https://www.rfc-editor.org/rfc/rfc8252.html).
