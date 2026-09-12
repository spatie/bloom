# Bloom on iPhone and iPad

The iOS foundation is a native UIKit client of Bloom Server. It supports direct SSH connections by IP address or hostname, and shares HTTPS transport,
OAuth metadata, AppAuth sign-in and token refresh, Keychain persistence, typed identifiers and
JSON handling and question parsing with the Mac app. Server workspaces, sessions and processes remain on the server.
Closing the app or iOS suspending it never cancels an agent turn.

## Architecture

See [Shared clients and a public Bloom protocol](CLIENT-ARCHITECTURE.md) for the implemented shared stores, next
extractions and feature-parity workflow. [Server protocol](SERVER-PROTOCOL.md) documents the current
wire contract for other client languages.

`Packages/BloomClient` is plain Swift and Foundation. It has no UI imports, subprocesses,
filesystem execution or database ownership. It contains the shared HTTPS connection, versioned
commands, read projections, transcript merging, question drafts and a durable conversation outbox.
It also owns the shared markdown parser, syntax highlighter, palette values, transcript row updates,
review lifecycle, changed-file tree and composer model/permission decisions.
Both Mac and iOS compile this package. Question parsing and answer construction use the same
types as Mac's existing question cards, re-exported by BloomCore.
The current wire version is 13. The SSH client also negotiates the known compatible
version 12; only a hello is retried, and diagnostics remain unavailable on that older server. Diagnostics use the same value type as Bloom Server; the collector
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
provides native editing. UIKit remains the navigation, scrolling and editing foundation.

`Packages/BloomUI` holds shared SwiftUI presentation: outgoing bubbles, assistant prose, markdown
block and table layout, code-block frames, diff gutters and hunk headers, syntax rows and file labels. Both the Mac transcript and iOS hosting cells use
these components. Mac adapters retain native rich text, link actions, font preferences and caches;
iOS uses the package's Dynamic Type renderer and system clipboard. Both renderers consume the
same markdown parser and syntax highlighter. Native table adapters share row-change decisions,
so incremental streaming updates leave unchanged cells in place. Tool cards, approvals and
composers remain platform-specific and can adopt shared presentation incrementally.

The current server's complete Codable graph includes execution-only planners, settings loaders
and database lifecycle setters. Moving it wholesale would expose those setters to clients or
pull server dependencies onto iOS. The client therefore reads small immutable projections of
server records. These are not another database model: `MobileProtocolContractTests` encodes
actual server replies and decodes them with the portable client, and decodes client commands
using the actual server protocol. Shared values are extracted instead of copied. Further
protocol extraction can happen incrementally as more features need it.

## Review and composer controls

Changes are grouped into the same compressed directory tree as Mac, with folder disclosure,
fuzzy path filtering and context menus for copying paths, opening source and reviewing changes.
Filtering preserves the unfiltered folder state. All-file review loads visible patches with two
concurrent reads; unchanged files retain their parsed diff when another file changes.

The composer model button opens a native options form: model, supported reasoning levels,
backend-specific permissions, context window and output styles. Settings come from the execution
server. Apply saves them there; failures preserve the last acknowledged settings and offer a retry
with the same command ID. Changing agent backends starts the server-created conversation.
Fast replies appear only for the supported Claude backend, not for Codex's unimplemented tier.
An uncertain save locks further edits until retried or explicitly forgotten with confirmation.
Fresh loads prevent cached settings from silently replacing another client's older choices.
The current protocol has no compare-and-swap revision for composer writes, so concurrent edits
made after opening the form still use last-writer-wins semantics.

These controls are available on iPhone and iPad. iPad uses a popover; iPhone uses adaptive sheet
presentation. Full parity still needs typed creation choices, richer tool results, all approval
variants, attachments, terminal interaction and further workspace/session management.

## Build

Run `Tools/build-ios.sh`. It generates an ignored Xcode application container under
`~/Library/Caches/BloomBuild/ios/<checkout-hash>/project` and builds iPhone/iPad Simulator
slices in the sibling `build` directory. These persistent paths retain incremental build output.
It signs the Simulator build ad hoc so Xcode supplies the simulated Keychain entitlement.
It does not launch Simulator, install an app, or take focus. The generated application container
supplies iOS bundle metadata, scenes, signing and URL registration; package manifests remain
the source of truth for shared code. This leaves the existing Mac SwiftPM build unchanged.

Each checkout has its own defaults. `BLOOM_IOS_PROJECT_DIR` and `BLOOM_IOS_BUILD_DIR`
override those paths. Locks cover project generation and compilation together, including explicit
shared overrides; concurrent builds refuse to overwrite one another.
For a device build, generate the project, select a development team in Xcode and build for the
device. There is no provisioning profile or distribution setup checked in.

Run portable tests with `swift test --package-path Packages/BloomClient -j 2`. Run server contract
and existing transport tests with:

```sh
BLOOM_TEST_ID=ios-client BLOOM_TEST_SWIFT_ARGS='-j 2' \
  Tools/test-core.sh 'MobileProtocolContract|ServerHTTP|Identifier|JSONValue'
```

## Connect with SSH

Connection setup uses a full-screen native form. Wide iPad windows show an introduction beside
that form; compact windows keep the introduction in the scrolling content. Advanced paths and
ports stay collapsed unless a saved connection overrides Bloom's defaults. The mobile client
uses light appearance and the Mac control accent. Device Access explains the generated key,
allows copying or sharing only its public half, and describes revocation. Automatic device
pairing through an existing Mac connection is not implemented yet.

Choose Server, select SSH and enter the server IP address or hostname and SSH account.
The default account is `bloom`. Advanced defaults match Bloom's installer:
`/home/bloom/bloom/server/current/bin/bloom-server` with data directory `/home/bloom/bloom/data`.
Existing installations can override both paths and the SSH port.

Tap Copy Public Key and add it to the account's `~/.ssh/authorized_keys` using your existing
trusted server connection. This generates an Ed25519 identity on the device. Its private key
is stored as a non-synchronising, device-only Keychain item and is never copied to the clipboard,
preferences, source tree or application bundle. Key import and automatic device enrolment are
not implemented yet.

The first connection refuses authentication until you explicitly verify and trust the server's
SHA-256 SSH host fingerprint. Compare it through your existing trusted SSH connection, for example
with `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`. A changed host key is refused, without an
automatic replacement or fallback to password authentication.

`Packages/BloomSSH` uses Apple's compiled SwiftNIO SSH implementation. It opens the existing
`bloom-server connect --data-dir ...` relay through SSH exec and exchanges the same versioned
JSON requests as the Mac app. It has no subprocess, downloaded executable or local agent runtime.
Each RPC currently opens a bounded SSH connection; it closes after one response. Persistent
multiplexing is a future optimisation. TCP connection timeout, request timeout, cancellation,
connection loss, key refusal and response-size limits are handled explicitly.

No domain, HTTPS gateway or VPN is required for SSH. The SSH client negotiates versions 12 and 13
using a read-only hello. Version 12 is accepted only after its matching-ID, explicit incompatibility
reply and a successful version-12 hello. The v12-to-v13 protocol change added diagnostics without
changing the existing operations. Unknown versions are refused, diagnostics are gated on v12,
and user commands are never automatically retried during negotiation. The existing production
validation daemon can therefore be used without interrupting the Mac app's older connection.

## Connect with HTTPS

The server must expose the existing Bloom Gateway HTTPS API with a trusted TLS certificate and
`/.well-known/bloom-auth` metadata. iOS does not install a Swift runtime or read the server's SQLite database. It uses the same `/v1/rpc` service as Mac HTTPS connections.

For a pre-registered OAuth public client, the identity provider must allow the exact redirect
`be.spatie.bloom.ios:/oauth/callback`, authorisation code with PKCE, and refresh tokens. Providers
with dynamic native client registration can register that redirect automatically. A configured
Mac-only loopback callback does not also authorise the iOS callback. Register the mobile
callback explicitly; do not relax redirect matching or add a client secret to the app.

On iOS choose Server, enter its HTTPS origin and sign in using the system authentication browser.
Only the origin is remembered in preferences. Sign out removes the Keychain entry.
HTTPS sign-in still needs a configured Gateway and identity provider for live verification.

## Included and remaining

The foundation lists projects, workspaces and sessions, imports a GitHub repository using the
server's credentials, creates a workspace using server-advertised composer defaults, sends and
stops turns, merges incremental transcripts, runs configured scripts and opens HTTPS previews.

The iPad workspace keeps its native conversation controller beside a WebKit preview or review,
with a searchable Changes/Files inspector. Narrow windows use a native tab bar to switch tools and put the
file list in a native sheet. Branch and uncommitted scopes use the existing server review API;
diffs load lazily with at most two requests at once. All-files review, per-file diffs and read-only
source browsing reuse the Mac diff parser, file tree/filter logic and BloomUI components. A
refresh failure remains visible above cached changes. Source files and previews execute no code
on the device beyond WebKit's normal web content.

DEBUG launch fixtures `--bloom-ui-preview workspace-browser`, `workspace-review` and
`workspace-files` render the actual native controllers with protocol-shaped sample replies and
an embedded WebKit sample page. They export light-mode 13-inch iPad landscape layouts into the
Simulator app's Documents directory. Add `--native-size` to keep the device's actual geometry.
These are UI fixtures, not evidence of a live server session, and are absent from Release builds.
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
separately for each normalised server identity and session. Default HTTPS and SSH ports are canonicalised;
other ports and hosts remain distinct. SSH account and server data directory also separate drafts. A submission and its exact command ID are written before
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

An SSH connection can open a server-local HTTP preview such as `http://localhost:3190` directly.
Bloom opens a pinned SSH connection and a loopback-only device listener, then forwards its HTTP
and WebSocket connections to that one server port. It probes the destination before presenting
WebKit, bounds accepted connections, forwards backpressure and half-closes, and closes all
connections when the lease ends. It never opens a public server port.

The browser permits HTTP only for its active lease's exact local origin, uses an isolated
nonpersistent browser store for that port and blocks other HTTP subresources. Revocation stops
loading and clears the document. The ATS setting allows local networking, not arbitrary HTTP.
An HTTPS connection instead uses a registered browser-authenticated HTTPS address or Tailscale
Serve URL. API bearer credentials never enter WebKit, URLs, cookies or JavaScript. Gateway
browser login remains separate as described in `Gateway/README.md`.

The Simulator build verifies compilation and packaging. Portable and contract tests verify
wire compatibility and state behaviour. A headless Mac integration harness using the exact mobile SSH transport and workspace service
verified unknown-host refusal, changed-host refusal and authenticated relay against Ubuntu.
Against an isolated protocol-13 daemon on that server it registered a fresh repository, created
a workspace and received an exact assistant reply from a real Codex prompt. This verifies the
shared mobile workflow. The actual iPad and iPhone Simulator applications have connected to the production validation
server, loaded the existing There There workspace and its 13-message conversation, and displayed
that workspace's running Laravel homepage through each app's own SSH preview tunnel. Both also
loaded real composer settings and visible patches for all-files review. The changed-file tree
exercised disclosure, filtering and restoration across 16 directories and 38 files. No sample
replies or HTML were used for these captures. The captures use UIKit rendering in headless
Simulators, not physical devices. Live HTTPS sign-in and physical-device keyboard/background
behaviour remain unverified.

The opt-in DEBUG driver `--bloom-live-export-key` exports only the device public key.
`--bloom-live-session` reads public connection settings from `bloom-live-connection.json` in the
app's Documents directory and uses the production connection, transcript and browser paths.
Its host fingerprint must be obtained through an already trusted SSH connection. It never
learns or accepts the host key from the connection under test. The private identity remains in
Keychain. Add `--bloom-live-options` to capture the native settings form after loading it from the server.
Add `--bloom-live-phone` for the device's native compact size, and `--bloom-live-review` to load
and capture the real visible patches. The driver also exercises disclosure, filtering and
restoration of the real changed-file tree.
These flags and the driver are absent from Release builds.

## App Store preparation

`Tools/archive-ios.sh` creates a Release archive for generic iOS devices at
`~/Library/Caches/BloomBuild/ios/<checkout-hash>/Bloom-iOS.xcarchive`. It is unsigned by
default for build verification. Set
`BLOOM_IOS_TEAM_ID` to archive using a development team already configured in Xcode;
`BLOOM_IOS_ARCHIVE_PATH` controls the destination. It never installs, opens or uploads the app.
A signed archive still needs distribution export, App Store Connect setup and review before
TestFlight or App Store distribution. Simulator builds cannot be uploaded to App Store Connect.

The generated target includes the Bloom icon, iPhone/iPad orientations, SDK licence notices
from the resolved dependency checkouts, the SDKs' own privacy manifests, and Bloom's manifest.
Bloom declares its own preferences access (`CA92.1`) and app-container file access (`C617.1`).
There is no advertising, analytics or tracking SDK. Reassess both the manifest and App Store privacy
answers if telemetry, hosted accounts or additional data collection are added. The manifest does
not replace App Store Connect privacy disclosures or a published privacy policy. Apple's
[required-reason API documentation](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)
and [SDK requirements](https://developer.apple.com/support/third-party-SDK-requirements/) describe those requirements.

SSH transport uses SwiftNIO SSH and `Crypto`; the pinned Swift Crypto package re-exports system
CryptoKit on iOS, without its BoringSSL targets. HTTPS uses URLSession and AppAuth. SSH protocol
implementation is nevertheless bundled code, so `ITSAppUsesNonExemptEncryption` is intentionally
not declared automatically. Complete Apple's export-compliance assessment for the actual shipping
binary and distribution countries, then supply the resulting answer/documentation. Do not infer
an exemption solely because SSH is a standard algorithm. See Apple's
[export-compliance overview](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance).

The application is a native workspace and agent client. Agents and project tools execute on the
user's server; iOS does not download or execute those tools, use JIT, or render a streamed desktop.
That architecture is relevant to review, but does not guarantee App Store approval. The final
submission still needs a reviewable server/demo account, screenshots, privacy/support URLs,
completed export answers and device testing.
