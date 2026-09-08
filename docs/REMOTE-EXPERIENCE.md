# Local and remote workspace experience

Choose the execution host when creating a workspace. After that, the workspace owns the choice.
The sidebar, conversation, permissions, files, terminals, previews and Git actions should behave
consistently. The host remains visible as context, so a command's execution location is clear.
Switching to another workspace must not stop anything running on its previous host.

Bloom Remote is a separate installation of the regular Bloom app for testing. It is not a second
product interface. Existing local workspaces continue to run locally.

## What other tools demonstrate

| Source | Relevant behaviour | Consequence for Bloom |
| --- | --- | --- |
| [Herdr quick start](https://herdr.dev/docs/quick-start/) | Attaching and detaching leave the same background session and agents alive. Agent status appears in the workspace sidebar. | Closing a Mac window must not stop server work. Reconnecting restores the conversation and pending approvals. |
| [VS Code Remote SSH](https://code.visualstudio.com/docs/remote/ssh) | Terminals open on the connected host. Private ports can be forwarded to available local ports and remembered. | Use normal terminal and browser panes. Route localhost previews through SSH, avoiding collisions with local development servers. |
| [Polyscope](https://getpolyscope.com/) | Advertises an integrated browser, code review and headless operation on a user's Linux server. | Remote execution belongs inside the development workflow. Its homepage alone does not establish its server runtime or installation requirements. |
| [Mattias Geniar's remote environment](https://ma.ttias.be/remote-coding-environment-vps/) | The server holds the working environment. Worktree setup prepares dependencies and environment files, previews have stable ports, and teardown must clean up their processes. Shared databases remain a separate isolation decision. | Creating a remote workspace must perform setup on that host. Follow through on scripts, preview lifecycle and cleanup, rather than stopping at a remotely running agent. |

## Implementation boundaries

A remote session has a distinct sidebar selection that cannot resolve to a local filesystem
workspace. Its actions use the server API. The transcript rows, composer editor, source editor,
terminal renderer, browser and file preview renderer are shared with the local app.

The server is the only owner of its database and runners. SSH clients are replaceable transports.
Commands and queued prompt deliveries have durable receipts. Unknown outcomes after an interrupted
mutation are shown for review instead of repeating an operation that may already have happened.

The current protocol polls snapshots. That gets the ownership and recovery rules in place; push
subscriptions can later reduce polling without changing which process owns the work.

## Verification checklist

- Create a remote workspace from a private Git URL through New Workspace.
- Check that setup, agent execution and terminal commands run as the service account on Ubuntu.
- Exchange multiple messages, answer a permission question and queue a second prompt.
- Close the Mac app during work, then reopen the same conversation and read its result.
- Read, edit and preview files. Refuse saving stale contents after another writer changes a file.
- Upload an attachment and confirm Git ignores the scratch copy.
- Start a development server in the terminal and view it through a private SSH tunnel.
- Commit, push and create a draft pull request in the validation repository.
- Create a local workspace in the same installation and switch between the two.
- Check restart recovery separately from client reconnect. Do not imply a server restart keeps
  every child process running.

The supported operations and remaining gaps are tracked in [SERVER.md](SERVER.md).

## Live verification on 8 September 2026

The isolated Bloom Remote installation created a remote workspace from a private GitHub repository
and a local terminal workspace through the regular New Workspace flow. Both appeared in its sidebar.
Remote Codex turns, approvals and queued follow-ups survived closing and reopening the Mac app.
Remote file editing, attachment upload and Quick Look, terminal commands, a private HTTP preview,
commit, push and draft pull request creation were exercised through the interface. The terminal
reported the Ubuntu hostname and service account; its local counterpart reported Darwin and the
Mac user. The server remained stable after the process descriptor fixes.
