# Workspace execution

A repository can run its agents, interactive terminals and run scripts inside its own development
container. Bloom and Bloom Server use the same configuration and launcher:

```toml
[execution]
name = "Docker"
command = [".bloom/docker/exec"]
```

The first element must be an executable file inside the workspace. Symlinks escaping that folder
and missing or non-executable scripts fail with an error. Remaining elements are fixed arguments.
Bloom appends the tool executable and its arguments as separate argv elements, without joining
untrusted command arguments into shell text. The wrapper must preserve those boundaries with
`"$@"` and translate host-specific tool paths to the corresponding installed container tool.
Interactive terminals invoke `/bin/bash -l` through the wrapper.

The wrapper receives the usual `BLOOM_WORKSPACE_ID`, `BLOOM_WORKSPACE_PATH`, `BLOOM_ROOT_PATH`,
`BLOOM_PORT` and other workspace variables. Container tooling must explicitly forward the variables
it needs and expose the workspace at its original absolute path. Git worktrees also need their
common Git directory available at the same path. Agent credentials should be mounted only into the
agent environment, never into web, database or queue services.

Setup and archive scripts run on the host. Setup can create the container before any agent starts;
archive can stop it before Bloom removes the worktree. Run scripts execute in the same container
shell as interactive commands.

Shared `.conductor/settings.toml` and `.bloom/settings.toml` are read from the workspace's branch.
If a shared file is absent there, the project root file remains the fallback. Project-root local
settings override shared files, and workspace-local settings take final precedence. Script-file
references resolve against the workspace, so setup added on a pull request can run before that
configuration is merged into the default branch.

Host-only Bloom MCP bridge registrations are omitted for wrapped agents. The local Mac bridge
executable and Unix socket cannot be assumed usable inside a Linux container. Ordinary host
sessions keep their existing bridge. Container bridge integration needs a portable transport;
basic agent conversations, filesystem changes, terminals and previews do not depend on it.

Changing execution settings affects newly started processes. Existing agent processes and persistent
terminal sessions retain the environment in which they started.
