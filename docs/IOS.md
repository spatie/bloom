# Bloom on iPhone and iPad

The iOS foundation is a native UIKit client of Bloom Server. It shares HTTPS transport,
OAuth metadata, AppAuth sign-in and token refresh, Keychain persistence, typed identifiers and
JSON handling and question parsing with the Mac app. Server workspaces, sessions and processes remain on the server.
Closing the app or iOS suspending it never cancels an agent turn.

## Architecture

`Packages/BloomClient` is plain Swift and Foundation. It has no UI imports, subprocesses,
filesystem execution or database ownership. It contains the shared HTTPS connection, versioned
commands, read projections, transcript merging, question drafts and a durable conversation outbox.
Both Mac and iOS compile this package. Question parsing and answer construction use the same
types as Mac's existing question cards, re-exported by BloomCore.
The shared wire version is 13. Diagnostics use the same value type as Bloom Server; the collector
and its process probes stay server-side. The mobile service can read that report, but a mobile
diagnostics screen is not included yet.
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

Native question forms support offered choices, multiple selection, custom answers where allowed,
and secure text fields for secret answers. Known command, file and search requests show their
full input, description and reason before explicit Allow once or Deny. No mobile button creates
session or project permission grants. Plan approval, MCP elicitation, unknown tools and requests
requiring a special interaction surface remain unsupported and direct the user to Mac.
An uncertain decision stays locked for retry with the same command ID and decision. Question
form contents remain in memory while the form is open and are not written to the draft store.

Conversation drafts are saved on each edit in the application's protected support directory,
separately for each normalised HTTPS origin and session. The default HTTPS port is canonicalised;
other ports and hosts remain distinct. A submission and its exact command ID are written before
network transmission. Relaunch restores an interrupted submission as Retry, without sending it
automatically. Transport errors, refusals, unexpected replies and failed persistence keep the
draft. Only a matching accepted submission can clear its own text; a later edit survives that
acknowledgement. The shared store serialises edits across windows. iOS file protection and mode
0600 protect the file; OAuth tokens remain exclusively in the authentication package's Keychain.
An unresolved submission stays locked until acknowledged. The UI explains that its outcome is
unknown and asks the user to reconnect and inspect the conversation before retrying. A matching
server failure is not necessarily a rejection: the server can return it after a command ran but
its final journal update failed. Safe recovery needs structured command-outcome reconciliation
that distinguishes a definite rejection from an interrupted or partially completed command.
That protocol and its explicit discard/reconcile flow remain foundation work.

Rich tool rendering, terminal emulation, diff editing, attachments, archive confirmations and
background notifications are not implemented yet. Server selection currently connects one origin per window and remembers
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
