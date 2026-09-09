# Private remote previews

The Mac's shared browser opens the workspace's preview port through its current server connection.
For an SSH connection, Bloom creates a loopback-only SSH forward automatically. The address bar
keeps the workspace address even when the local forwarding port changes. Choose Open Preview from
the tab menu or empty browser pane. Browser-first workspaces open it after setup succeeds.

Development servers must keep running on the remote machine. Bloom's setup script can start a
project's Docker services and wait for readiness, as the There There fixture does. A plain project
can start its development server from a terminal or run script using `BLOOM_PORT`.

## HTTPS and mobile

The provider-independent [HTTPS gateway](../Gateway/README.md) carries the existing server API,
terminal stream and private browser previews. It uses an administrator-configured OAuth/OIDC
provider and an HTTPS reverse proxy. No Cloudflare or VPN is mandatory. The administrator must
register preview ports and hosts; Bloom does not yet provision DNS, certificates or identity
provider settings automatically. Keep development ports and the runtime socket private.

Each preview has a separate origin from agent control and other workspaces. Authentication must
cover the page, assets and WebSockets. Workspace membership is checked by the gateway. The native
iOS client foundation is being developed separately with HTTPS transport and native sign-in;
live device authentication and preview provisioning still need end-to-end verification.

## Application configuration

A single application origin is easiest to preview across Mac, iPhone and iPad. Reverse proxy the
application, Vite assets and HMR, and application WebSockets through one registered port. The
There There Docker example uses Caddy for that purpose. Configure relative asset URLs and
same-origin WebSockets. Bloom forwards traffic; it does not rewrite arbitrary HTML or project
configuration. A localhost asset URL inside a remote page would refer to the viewing device.

## Optional Tailscale

Existing Tailscale HTTPS Serve mappings remain supported for users who already operate a tailnet.
The server's read-only preview resolver recognises private HTTPS root proxies to the requested
loopback service. It preserves the URL path, query and fragment. Public Funnel mappings and
subpath proxies are not substituted. Each viewing device needs access to that tailnet.

Mapping creation and removal remain administrator operations. The Bloom service account does not
need general Tailscale operator or sudo access just to discover configured previews. Without a
suitable mapping, the Mac's SSH connection uses its automatic SSH forward. HTTPS clients need a
registered gateway preview.
