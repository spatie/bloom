# Bloom on iPhone and iPad

The iOS foundation is a native UIKit client of Bloom Server. It shares HTTPS transport,
OAuth metadata, AppAuth sign-in and token refresh, Keychain persistence, typed identifiers and
JSON handling with the Mac app. Server workspaces, sessions and processes remain on the server.
Closing the app or iOS suspending it never cancels an agent turn.

## Architecture

`Packages/BloomClient` is plain Swift and Foundation. It has no UI imports, subprocesses,
filesystem execution or database ownership. It contains the shared HTTPS connection, versioned
commands, read projections and transcript merging. Both Mac and iOS compile this package.
`make lint` enforces its UI boundary.

`Packages/BloomAuthentication` wraps AppAuth and Keychain. Its small platform boundary presents
Mac's loopback redirect flow or iOS's system browser authentication session. Credentials are
scoped to the server origin and the app bundle ID, and never stored in preferences. The package
is shared by the Mac app and iOS. AppAuth owns PKCE, OAuth state checking and refresh.

`iOS/Bloom` owns UIKit navigation and presentation. `UISplitViewController` adapts to iPhone's
compact navigation and iPad's columns. `UITextView` supplies system editing, selection, undo and
keyboard behaviour for the composer. Transcript polling does not recreate or overwrite the
composer. `WKWebView` owns the preview's separate browser session.

This follows Apple's [Swift package guidance](https://developer.apple.com/documentation/xcode/creating-a-standalone-swift-package-with-xcode)
for sharing logic while preserving platform-appropriate interfaces. Apple's
[split view controller](https://developer.apple.com/documentation/uikit/uisplitviewcontroller)
handles size-class adaptation, and its [text view](https://developer.apple.com/documentation/uikit/uitextview)
provides native editing. UIKit is the foundation here. SwiftUI is not a dependency. Small hosted
SwiftUI views could be introduced where they prove useful without replacing the editing or
navigation infrastructure.

The current server's complete Codable graph includes execution-only planners, settings loaders
and database lifecycle setters. Moving it wholesale would expose those setters to clients or
pull server dependencies onto iOS. The client therefore reads small immutable projections of
server records. These are not another database model: `MobileProtocolContractTests` encodes
actual server replies and decodes them with the portable client, and decodes client commands
using the actual server protocol. Shared values are extracted instead of copied. Further
protocol extraction can happen incrementally as more features need it.

## Build

Run `Tools/build-ios.sh`. It generates an ignored Xcode application container under
`/tmp/bloom-ios-project` and builds iPhone/iPad Simulator slices in `/tmp/bloom-ios-build`.
It does not launch Simulator, install an app, or take focus. The generated application container
supplies iOS bundle metadata, scenes, signing and URL registration; package manifests remain
the source of truth for shared code. This leaves the existing Mac SwiftPM build unchanged.

Set `BLOOM_IOS_PROJECT_DIR` and `BLOOM_IOS_BUILD_DIR` to isolate simultaneous builds.
For a device build, generate the project, select a development team in Xcode and build for the
device. There is no provisioning profile or distribution setup checked in.

Run portable tests with `swift test --package-path Packages/BloomClient -j 2`. Run server contract
and existing transport tests with:

```sh
BLOOM_TEST_ID=ios-client BLOOM_TEST_SWIFT_ARGS='-j 2' \
  Tools/test-core.sh 'MobileProtocolContract|ServerHTTP|Identifier|JSONValue'
```

## Connect

The server must expose the existing Bloom Gateway HTTPS API with a trusted TLS certificate and
`/.well-known/bloom-auth` metadata. iOS does not execute SSH, install a Swift runtime or read the
server's SQLite database. It uses the same `/v1/rpc` service as Mac HTTPS connections.

For a pre-registered OAuth public client, the identity provider must allow the exact redirect
`be.spatie.bloom.ios:/oauth/callback`, authorisation code with PKCE, and refresh tokens. Providers
with dynamic native client registration can register that redirect automatically. A configured
Mac-only loopback callback does not also authorise the iOS callback. Register the mobile
callback explicitly; do not relax redirect matching or add a client secret to the app.

On iOS choose Server, enter its HTTPS origin and sign in using the system authentication browser.
Only the origin is remembered in preferences. Sign out removes the Keychain entry.
The root validation server is currently configured for SSH, so it cannot validate this iOS flow
until an HTTPS Gateway deployment and provider configuration are supplied.

## Included and remaining

The foundation lists projects, workspaces and sessions, imports a GitHub repository using the
server's credentials, creates a workspace using server-advertised composer defaults, sends and
stops turns, merges incremental transcripts, runs configured scripts and opens HTTPS previews.
Failed create/send requests retain their command IDs for explicit retry. They are not retried
as new commands, because a network failure can follow a completed server mutation.

Approvals and questions are shown as waiting, with an instruction to answer on Mac or stop the
turn. Rich tool rendering, mobile approval controls, terminal emulation, diff editing,
attachments, archive confirmations, background notifications and offline draft persistence are
not implemented yet. Server selection currently connects one origin per window and remembers
the latest origin. A saved multi-server catalogue is future work.

A preview must be a registered, browser-authenticated HTTPS address or a Tailscale Serve URL
(the latter requires Tailscale on the device). Loopback previews without a mapping are refused
with an explanation because iOS has no desktop SSH port-forward subprocess. The API bearer
credential is never injected into WebKit, a preview URL, cookies or JavaScript. Gateway browser
login must be configured separately as described in `Gateway/README.md`.

The Simulator build verifies compilation and packaging. Portable and contract tests verify
wire compatibility and state behaviour. Neither is a claim of live device sign-in, interactive
keyboard testing or a preview against the current SSH-only server. Those require the HTTPS
configuration and a device or an authorised interactive Simulator session.
