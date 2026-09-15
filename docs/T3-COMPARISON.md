# T3 Code remote access compared with Bloom

Investigated 12 September 2026 against T3 Code main commit
[`a43f9b45`](https://github.com/pingdotgg/t3code/tree/a43f9b45ae85caf37e0be8270ad3d27365ece2bd).
This is a focused primary-source review, not a live connection, pairing, notification or
preview test. It updates the T3 findings in [the earlier research](T3-CONNECT-RESEARCH.md).
The Bloom side should be read against the current development branch, not a released product.

## Useful product gaps

| T3 capability | What it would add to Bloom |
| --- | --- |
| T3 Connect account login and environment discovery, with a managed outbound tunnel | Sign in on a second device and choose a server, without manually entering its SSH configuration or distributing a device public key. |
| One-time pairing links and QR codes, with client sessions and revocation in Settings | A guided Add Device flow and a visible way to remove one device's access. Bloom's HTTPS support alone is not this product workflow. |
| Hosted browser client at app.t3.codes, plus a locally served web client | Access without installing an Apple app. This is the web control panel discussed for Bloom. |
| Published iPhone/iPad and Android clients, plus background notifications | Distribution beyond development builds, and alerts when work finishes or needs attention while the app is closed. |
| Optional automatic machine selection based on CPU and memory | Distribute new threads among connected machines while keeping existing threads on their original server. |
| Integrated Tailscale HTTPS and pairing controls | A supported private-network route that users can turn on and off from connection settings. |

Connect, pairing, load balancing and Tailscale controls are documented in
[T3's current remote-access guide][remote]. The hosted UI also responds at
[app.t3.codes](https://app.t3.codes). T3's [root README][readme] describes serving a local
web client with its CLI and links its distributed clients.

## How Connect is secured

T3 uses Clerk identity and a trusted broker to link accounts with environments. The broker
obtains a one-time bootstrap credential bound to the client's DPoP key; the client exchanges
it with the environment for a scoped session. The broker does not receive that session token,
but its signing authority is still trusted. Managed tunnels expose a validated loopback origin.
Normal HTTP and WebSocket traffic uses the tunnel hostname, rather than traversing the broker
Worker. [Connect architecture][connect]

Pairing cannot grant more authority than the issuer holds. Ordinary pairing does not grant
access-management or relay-management scopes. Browser cookies and native credentials use the
same server-enforced session model. Native clients fetch short-lived WebSocket tickets through
authenticated HTTP instead of putting long-lived tokens in socket URLs. Revoking a pairing
link and revoking an already-paired device session are separate actions.
[Environment authentication][auth], [access management][remote]

T3 documents credential renewal without dropping an otherwise healthy connection. Its execution
server owns durable state regardless of whether the route uses Connect, SSH, Tailscale or direct
access. These are useful reliability details, but this review did not test reconnect behaviour
or establish that every T3 recovery path is more capable than Bloom's.
[Credential renewal][remote], [remote architecture][architecture]

## Mobile background activity is an actual additional system

T3 documents completion, failure, approval and input notifications, with thread deep links.
It also provides iOS Live Activities and Android ongoing activity. Background delivery requires
T3 Connect and host activity publishing; a direct connection or Tailscale alone is insufficient.
The phone need not keep an environment connection open. The relay owns APNs/FCM delivery and
device notification preferences. [Notification guide][notifications], [relay responsibilities][relay]

The [Apple App Store listing](https://apps.apple.com/us/app/t3-code-remote-claude-more/id6787819824)
was accessible and identifies an iPhone/iPad app. T3's root README also links its Android store
listing. The mobile package README still claims the app is not distributed; that statement is
stale relative to the published App Store listing. Store availability was checked, but app
installation and background delivery were not tested.
[Root README][readme], [conflicting package README][mobile-readme]

## Do not overstate T3's preview support

The current browser URL resolver still rejects environment-port targets when the environment
hostname is not privately reachable, explicitly referring to a planned authenticated preview
gateway. Its discovered-URL helper catches that refusal and returns the original URL. Returning
a localhost URL does not make that remote port reachable from another device.
[Browser target resolver][preview]

Therefore T3 Connect is not evidence that arbitrary Laravel or Vite previews automatically work
through its managed public endpoint. Its hosted browser UI also requires a reachable HTTPS
backend and does not proxy normal application traffic. Bloom already has SSH preview tunnelling;
compare these preview paths separately from the account-discovery gap.
[Hosted web architecture][architecture]

The strongest ideas to lift are account-based discovery, simple device pairing/revocation and
background notifications. A browser client is a separate substantial feature. Load balancing
is useful later, once multiple-server usage is common.

[remote]: https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/docs/user/remote-access.md
[connect]: https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/docs/internals/t3-connect.md
[auth]: https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/docs/internals/environment-auth.md
[architecture]: https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/docs/internals/remote.md
[preview]: https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/web/src/browser/browserTargetResolver.ts
[notifications]: https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/docs/user/mobile-notifications.md
[relay]: https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/infra/relay/README.md
[readme]: https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/README.md
[mobile-readme]: https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/mobile/README.md
