# Private remote previews

Tailscale is the recommended network for personal remote servers. Install it on the server and
each Mac, iPhone or iPad, and connect those devices to the same tailnet. The server does not need
a Mac to remain online. The free Personal plan is limited to non-commercial use; check
[current pricing](https://tailscale.com/pricing) for a business network.

## Server setup

Run `sudo tailscale up` and follow the sign-in link. Then enable private HTTPS for a development
server that listens on loopback:

```sh
sudo tailscale serve --bg --https=18000 http://127.0.0.1:18000
```

The command supplies a link to enable Serve/HTTPS if the tailnet needs that setting. Its resulting
`https://machine.tailnet.ts.net:18000` address is private to devices allowed by the tailnet's access
policy. Use Serve, not Funnel. Do not open development ports in the public firewall.

Choose an unused port for each workspace. Inspect `tailscale serve status --json` before adding
a mapping so an existing service is not replaced. `--bg` keeps the mapping after the shell exits.
Keep the development process running separately, using Bloom's server terminal or a service.

Remove a single mapping when it is no longer needed:

```sh
sudo tailscale serve --https=18000 off
```

Do not use `tailscale serve reset` when cleaning up a workspace, because it removes other
workspaces' mappings too. Bloom currently reads configured mappings; their creation and removal
are administrator operations. The Bloom service account does not need general Tailscale operator
or sudo access just to discover preview URLs.

## Laravel and Vite

For an application on port 18000 and Vite on port 18001:

1. Run Laravel on `127.0.0.1:18000` and Vite on `127.0.0.1:18001`.
2. Create private HTTPS Serve mappings for both ports.
3. Set the workspace's `APP_URL` to the complete application HTTPS URL, including its port.
4. Configure Vite's `server.origin` to its complete HTTPS URL. Set `server.hmr.host` to the
   server's Tailscale DNS name, `protocol` to `wss`, and `clientPort` to 18001.
5. Keep Vite's bind host at `127.0.0.1`, use `strictPort: true`, and permit the application HTTPS
   origin in its CORS configuration. Restrict allowed hosts to the server's DNS name.
6. Trust the loopback reverse proxy in Laravel so it recognises forwarded HTTPS requests. For
   applications using cookies, configure secure cookies and check any domain-specific routing.

The HTML, asset URLs and hot-reload WebSocket must all name the server. A `localhost:18001` URL
inside a page refers to the viewing device and cannot work on an iPhone. Bloom does not rewrite
application responses or silently edit an existing project's environment files.

## Bloom behaviour and mobile support

Protocol 8 adds the read-only `previewAddress` operation. It resolves a loopback HTTP/HTTPS URL
using the owning server's Tailscale status and Serve configuration, preserving its path, query
and fragment. Only HTTPS root proxies to the requested loopback service qualify. Other servers,
subpath proxies and public Funnel mappings are not substituted.

The existing shared browser component uses the resolved address. No separate remote browser UI
is needed, and external HTTPS addresses continue to open directly. Without a configured Serve
mapping, the Mac client retains its existing SSH forwarding behaviour.

An iPhone or iPad connected to the tailnet can open a configured preview in Safari today. A native
Bloom mobile client and an authenticated HTTPS transport for the Bloom control protocol still
need implementation; Tailscale connectivity alone does not add them. Keep that API independent
of the network provider so local and remote clients can use the same operations.

References: [Tailscale Serve](https://tailscale.com/docs/reference/tailscale-cli/serve),
[Laravel Vite integration](https://laravel.com/docs/13.x/vite),
[Vite server options](https://vite.dev/config/server-options).
