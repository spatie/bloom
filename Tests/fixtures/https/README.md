# HTTPS integration fixtures

These checks are opt-in and must target disposable data. They make no model calls. The agent
check requires `Tests/fixtures/server-agent.py` installed as an executable and selected through
the test server's `agent.claudeCode.executablePath` setting. Never run it against personal work.

`AuthHarness.swift` is compiled with the app's `ServerAuthentication.swift`, the debug BloomCore
objects and AppAuth objects. It runs the actual sign-in and Keychain implementation. Its browser
adapter writes `authorize-url.txt` into the fixture directory for an isolated browser to open.
It pins the supplied `cert.der` as a test-only trust anchor in its own URLSession. It does not
change the system trust store. The server URL is the loopback fixture authority in the source.

The fixture directory supplies `gateway.json`, `cert.pem`, `cert.der` and a running HTTPS proxy.
Use a public native OAuth client named `bloom-native`, an API audience `bloom-control`, PKCE S256,
a loopback redirect (`http://127.0.0.1/*` in Keycloak) and the scopes `openid email profile`.
The tested Keycloak client has the `basic`, `email` and `profile` default client scopes and an
access-token-only audience mapper. The `basic` scope supplies the subject claim. Do not weaken
the gateway's subject checks to accommodate a missing mapper. Configure Keycloak's `JWT` header
with `required_claims: {"typ":"Bearer"}` on the gateway.

Run a separate confidential `bloom-preview` client with its own audience for OAuth2 Proxy.
The tested proxy uses PKCE S256, `--pass-access-token`, a Secure HttpOnly host-only cookie named
`__Host-bloom-preview`, and `--provider-ca-file` for the fixture CA. The preview gateway policy
reads `X-Forwarded-Access-Token` and reserves that cookie name. `preview.go` checks that neither
credential reaches the application and provides a browser WebSocket echo endpoint.

After `swift build -j 4`, compile the native harness with
`BLOOM_HTTPS_FIXTURE=/path/to/isolated/fixture python3 Tests/fixtures/https/compile.py`, then run
`/path/to/isolated/fixture/auth-harness /path/to/isolated/fixture`.

After sign-in, the harness writes an access token into the fixture directory, refreshes it while
the checks run and checks Keychain sign-out at the end. Treat the directory as private test
state. Create `finish-native` to end the refresh loop early. These files are not repository inputs.

With the running fixture:

```sh
export BLOOM_HTTPS_FIXTURE=/path/to/isolated/fixture
python3 Tests/fixtures/https/rpc.py
python3 Tests/fixtures/https/agent.py
cd Gateway
go test ./internal/gateway -run 'TestConfiguredIdentityProviderIntegration|TestLiveRuntimeTerminalIntegration' -v
```

The RPC exercise creates a scratch repository/workspace and writes `created.json`, which the
terminal and agent checks use. Configure the test server's private `tmux.conf` to run `/bin/sh`
with `default-command /bin/sh`, so tests do not execute the developer's interactive shell setup.
The terminal check uses the real persistent shell, sends input, disconnects, reconnects and checks
its size. Use `BLOOM_HTTPS_REPOSITORY` to supply a repository path on a remote server instead of
creating the local scratch repository.

The browser check opens the preview without injecting headers, signs in through the identity
provider and clicks **Test live connection**. Expect **Bloom live preview verified**. Anonymous
requests should redirect to sign-in. After token expiry the connection should close, and a new
connection should work through the proxy's session refresh.

Stop the fixture processes and containers and archive/delete only the scratch workspaces when
done. Keep the installed Bloom apps, their databases and the user's active server untouched.
