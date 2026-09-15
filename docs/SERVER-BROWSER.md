# Browser testing on Bloom Server

Bloom supports two complementary workflows. A connected client's browser pane lets the person
and agent inspect the same page through the workspace-scoped MCP tools. Optional host browser
tools let an agent inspect a running project when no client is connected. Repeatable application
regressions should remain project-owned Playwright or Pest tests.

## Optional installation

`Tools/install-bloom-browser.py` installs pinned agent-browser and Chrome for Testing releases
on Ubuntu 24.04 or 26.04, for a dedicated non-root Bloom Server account. The server wizard offers
this separately from the core runtime. A browser failure does not undo a working server install.

```sh
sudo python3 Tools/install-bloom-browser.py --user bloom --service-home /var/lib/bloom-home
sudo python3 Tools/install-bloom-browser.py --check
```

The installer verifies download checksums, installs system libraries, and grants user namespaces
through an AppArmor profile scoped to its protected Chrome executable. It does not disable
AppArmor globally, install a setuid helper, or launch Chrome as root. Installation succeeds only
after checking Chrome's namespace/PID/network/seccomp status, actual renderer process security
flags, a loopback-only debugging listener, and a rendered PNG.

The managed command is `/opt/bloom-browser/bin/agent-browser`. The wizard includes this directory
in the service PATH. Existing services need the same PATH entry. Run commands from the workspace:

```sh
agent-browser open http://127.0.0.1:3190
agent-browser snapshot -i
agent-browser screenshot .bloom/preview.png
agent-browser close
```

Each workspace gets separate browser state and profile directories under the service home.
The launcher controls connection, executable and profile options, ignores repository browser
configuration, and labels page content as untrusted. Keep one workspace browser open at a time
on small servers. These profiles prevent accidental state mixing; they are not isolation against
agents that already share the same Unix account and shell access.

The readiness receipt describes the last successful smoke test, not perpetual health. Dependency
changes, damaged files or exhausted memory can still cause a later browser command to fail.
The current installation prefix belongs to one service account.

## Containers

Host provisioning deliberately refuses to run inside Docker. Upstream agent-browser automatically
adds sandbox-disabling flags in container environments; the managed launcher refuses those flags.
Do not mount this launcher into a project container and assume it remains sandboxed.

A Docker application can still be checked by the host browser through its loopback preview port,
or by the browser in a connected Bloom client. Project-owned browser test containers require their
own reviewed non-root user and sandbox policy. The Bloom MCP bridge and the host browser are
different integrations: enabling the bridge lets a container agent call the connected client,
but does not install a browser in that container.

## Research and verification

Cursor's cloud agents use isolated environments with browser/computer tools and produce visual
artifacts. Polyscope exposes an integrated browser and preview workflow, but its public materials
do not establish which browser automation engine it uses. Herdr's older browser repository points
to terminal-browser, which exposes an agent-browser-compatible interface and shared browser view.
These support offering both a visible client preview and independent server-side inspection.

- [Cursor cloud agents](https://cursor.com/docs/cloud-agent)
- [Polyscope](https://getpolyscope.com/)
- [Herdr browser](https://github.com/ogulcancelik/herdr-browser)
- [Terminal Browser](https://github.com/zenbu-labs/terminal-browser)
- [agent-browser Chrome engine](https://agent-browser.dev/engines/chrome)
- [agent-browser security](https://agent-browser.dev/security)
- [Playwright container guidance](https://playwright.dev/docs/docker)

On 10 September 2026, the pinned x64 installer passed on the actual Ubuntu 26.04 test host.
Sandboxed Chrome opened the There There application on its loopback preview port, returned the
page's accessibility snapshot, and saved a screenshot. The arm64 release is checksum-pinned but
has not yet been exercised on an arm64 Ubuntu host.
