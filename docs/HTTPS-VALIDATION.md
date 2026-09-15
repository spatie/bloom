# HTTPS validation

Validated on 9 September 2026 using isolated data and a real identity provider. The installed
Bloom apps and the existing Ubuntu validation service were not replaced.

## Environment

The Mac ran Keycloak 26.7.3, Caddy and OAuth2 Proxy 7.15.0 in separate Docker containers. TLS
used a temporary certificate trusted only by the test clients. The Mac authentication harness
compiled the app's actual `ServerAuthentication.swift`, AppAuth and BloomCore. Its browser
adapter opened the OAuth request in a separate headless Chrome profile.

The initial checks used a standalone Mac runtime. The same checks then ran with the compiled
Linux gateway and Bloom runtime on Ubuntu at `94.237.125.23`, under the existing unprivileged
test account and a new data directory. The package was built on Ubuntu 24.04 x86_64 with Swift
6.3.3 and bundled its runtime libraries. The existing installed service stayed running.

SSH forwards connected the private test services. Caddy terminated HTTPS on the Mac; the
Ubuntu gateway validated tokens and accessed its local runtime socket. This validates the
application path without opening public development ports. It is not a public HTTPS deployment.

## Passed checks

- Browser authorisation-code sign-in with PKCE and the actual macOS loopback callback.
- Keychain persistence, restoration through a second authentication instance, token refresh
  against Keycloak, and local sign-out removing the saved credential.
- Native Swift HTTPS requests reaching the standalone runtime, first on Mac and then Ubuntu.
- Workspace and conversation creation, catalogue reads, rename and pin.
- File reads and edits, stale-revision refusal, traversal refusal, Git changes and patches.
- Notes save/read and durable command retries returning the same conversation rather than
  creating a duplicate.
- An agent permission request surviving disconnected clients, approval executing the expected
  edit, a running process surviving disconnect, Stop, and another turn after Stop. These use
  the deterministic `server-agent.py` fixture and make no model calls.
- Real terminal WebSocket input, persistent shell reconnection without replay, resize verified
  with `stty size`, and terminal closure, on Mac and Ubuntu.
- Workspace archive confirmation, archive and restore on Mac and Ubuntu. Scratch workspaces
  were archived after testing.
- Browser preview login through OAuth2 Proxy, anonymous requests redirected to sign-in,
  authentication headers/cookies withheld from the upstream application, live WebSocket echo,
  closure at token expiry and a fresh connection after proxy session refresh.
- A separate Laravel 13.31.0 application and Vite 8.2.2 server running on Ubuntu. The browser
  reported HTTPS, loaded CSS and JavaScript, connected to Vite over WSS, and changed a rendered
  CSS colour from `rgb(20, 40, 60)` to `rgb(180, 30, 70)` without reloading the page.
- Local access-policy revocation on the Ubuntu gateway, refusing subsequent API requests and
  browser preview access. Policy reload closes the existing preview connection.

The focused Swift run passed 38 tests across HTTP, terminal streams, runtime and preview suites.
The Go suite passed with the race detector, including invalid identities, signature verification,
ID-token substitution, audience separation, cookie isolation, revocation and bounded RPC input.
The two opt-in identity/runtime integration tests also passed against the real provider and Ubuntu
runtime. The Mac build passed with warnings treated as errors. Both linters and `go vet` passed;
`govulncheck` reported no known vulnerabilities in the gateway.

## Changes made during validation

The gateway now accepts an explicitly configured non-default HTTPS port and preserves it in
preview addresses. Host/origin matching remains exact. Browser cookies are not scoped by port,
so different workspaces and agent control must still use different hostnames. Multiple ports
on one hostname are allowed only within the same workspace.

The gateway can load an administrator-specified identity-provider CA with `--identity-ca-file`.
Certificate and hostname checks remain enabled. Native authentication accepts an injected
session/browser adapter internally, allowing its production sign-in and Keychain code to run
in an isolated integration harness without modifying system trust or opening the user's app.

Terminal reconnection now clears and restores the captured screen and restores the tmux cursor
position. It no longer adds a trailing newline that scrolls the captured terminal. The terminal
regression test uses its own plain shell instead of executing the developer's login scripts.

## Laravel configuration discovered by the test

The Laravel and Vite origins used different HTTPS ports on the same preview hostname. Both had
the same workspace-scoped OAuth policy. Vite allowed only the Laravel origin and enabled CORS
credentials. Laravel's Vite script, style and preload tags used `crossorigin="use-credentials"`
so protected asset requests included the preview session cookie. Its APP_URL, ASSET_URL and
Vite/HMR origin pointed at the authenticated addresses. Trusted proxies were limited to loopback.

The server's file-watch limit was already exhausted when starting a second Vite instance. The
disposable fixture used polling and excluded vendor/node_modules, without changing kernel limits
or the existing application. This is a fixture/deployment concern, not an authentication failure.

## Remaining verification

This does not verify every button in the full Bloom window or a physical iPhone/iPad. The
Mac authentication and transport code were exercised through a harness, and browser checks ran
in Chrome. A native iOS client is not implemented by this work. Public DNS/certificate rollout,
a production identity-provider configuration and independent security review remain outstanding.
Laravel preview configuration is currently explicit; this test does not establish automatic
setup for arbitrary projects or providers. Opaque-token providers remain unsupported.

The opt-in fixtures are in [Tests/fixtures/https](../Tests/fixtures/https/README.md). Production
integration requirements are in [Gateway/README.md](../Gateway/README.md).
