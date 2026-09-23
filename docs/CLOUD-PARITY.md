# Bloom Cloud parity: who may reach a workspace, and doing locally what Cloud can

Written on 19 September 2026 in answer to two things Freek said the night before. The first
outranks the second, so it comes first:

> authentication is important. Worst case is that somebody not access to a workspace or even a
> team would give instruction to a bloom cloud workspace it does not belong to. Make sure that
> isn't possible.

> ideally you should be able to do all you can locally also on bloom cloud. In the very best case,
> local bloom should be able to interact with bloom cloud workspaces as well. is that possible
> easily?

This covers the machine's half. runbloom.app's half of the authentication audit is the control
server's, and the two are meant to be read together. Nothing in part 2 is built; it is here to be
argued with before anybody starts.

## 1. Authentication on the machine

The rule: **the machine refuses anything not meant for it, even if runbloom.app got something
wrong.** runbloom.app decides who may have a token. The machine does not take its word for what a
token says; it verifies every token itself, against runbloom.app's published keys, and checks that
the token names this workspace, is still in date, is the right kind for the door it is shown at,
and grants the ability being used.

### Every way in that can cause work

| Door | Credential | How the machine knows it is for this workspace | Expired | Revoked | Another workspace's |
| --- | --- | --- | --- | --- | --- |
| RPC `POST /_bloom/v1/rpc` | session token (JWT, EdDSA), at most 5 minutes | `aud` must be `bloom-workspace:<this id>`; signature against runbloom.app's JWKS; `iss`; `token_use` must be `session`; each operation checks its ability (`view`, `prompt`, `files`, `terminal`, `share`) | 401 `token_expired` | 401 | 401 |
| Event stream `GET /_bloom/v1/events` | session token, with `view` | the same; the stream closes when its token expires unless renewed with a fresh one that still has `view` | 401, and an open stream closes at its token's expiry | 401; an open stream is closed at once by `revoke` | 401 |
| Stream renewal `POST /_bloom/v1/streams/:id/token` | session token, with `view` | the same | 401 | 401 | 401 |
| Terminal WebSocket | session token, with `terminal`; the shell runs as the sandbox user, and network git and gh in it get no person's credential | the same `aud` | 401 | 401; an open terminal is closed at once by `revoke` | 401 |
| Preview `GET /_bloom/preview/enter` | preview token, single use, at most 60 seconds, grants only `preview` | the same `aud`, `token_use` must be `preview`; exchanged for a host-only cookie | 401, no cookie | 401, no cookie; an existing cookie is refused from the revocation on | 401, no cookie |
| Preview cookie (Caddy `forward_auth`) | the cookie, stored hashed on the machine | only this machine issued it | the cookie expires after 1 hour, for a person and a share link alike | refused from the revocation on | not possible: a cookie is this machine's own |
| Control `POST /_bloom/v1/control/:action` | control token, single use, at most 60 seconds, `sub` must be `control`, `admin` only in this kind | the same `aud` | 401 | not revocable, being runbloom.app itself | 401 |
| Agent bridge (Unix socket) | a per-chat token written into the agent's MCP config; directory 0700, files 0600 | the socket is this machine's and the token names one chat of this workspace | tokens are retired when the chat closes | n/a | n/a |
| Person-bound credential socket | kernel peer identity plus root-attested process ancestry and one rotating grant | exact ephemeral uid, cgroup, process group, wrapper pid and start time | grant expiry | reservation revoked and descendants killed | another workspace has no registered identity |
| runbloom.app calls the machine makes (`turns`, person-bound grant exchange, `cloud-workspaces`, and `opening`) | the workspace secret, from `/etc/bloom/workspace.json`, rotated whenever anybody loses access | runbloom.app checks the secret against the workspace in the URL | n/a | the old secret works for two minutes after rotation | n/a |

What a person's token cannot do at all: a preview token grants nothing but `preview`, whatever it
claims; `admin` in anything but a control token refuses the whole token; an ability named twice
refuses it; a token that lasts longer than runbloom.app issues them for is refused; one issued in
the future is refused; a single-use token is refused the second time, even under a new signature.

**Every door verifies the same way because they all call one verifier**, `TokenVerifier.verify`,
with the kind of token the door accepts. The author of anything written is the token's subject,
never a name in the request body.

### Proved by tests

`Tests/BloomRunnerTests/WorkspaceAuthenticationTests.swift`, through the real routes:

- a valid token minted for a different workspace, signed by runbloom.app's own key, is refused at
  the RPC, the event stream, stream renewal and the terminal, and nothing is queued or written;
- an expired token is refused at the same four;
- a preview token cannot command, watch, renew or open a terminal; a preview token for another
  workspace, an expired one, or a session token does not open the preview, and no cookie is set;
- a token without the ability asked for is refused it: a viewer cannot send, but can still read,
  which shows the refusal is the ability and not a broken route; no `view` cannot watch; no
  `terminal` gets no shell;
- a token issued before its subject was revoked is refused at once, though it has minutes to run;
- an event stream and a terminal whose token has run out are closed, and a stream is renewed only
  with the same person's token.

`TokenVerifierTests` covers each of the verifier's own rules one at a time.

### Somebody removed while holding a live token

**With runbloom.app's `revoke` control call, it is immediate.** The machine records the revocation
(in its database, so a restart keeps it) and from then on refuses every token issued before it, on
every door. It closes the person's open event streams and terminals, removes their queued prompts,
stops a turn of theirs that is running, and refuses their preview cookie.

**Without the call, the gap is five minutes and thirty seconds** for everything but the preview: a
session token lasts at most five minutes, with thirty seconds of clock skew, and nothing renews an
event stream or a terminal once runbloom.app stops issuing tokens to that person. A queued prompt
of theirs still has to be started by runbloom.app's `turns/{id}/start`, which is runbloom.app's to
refuse.

**The preview cookie was the real gap, and is now an hour.** It lasted eight hours for a person,
and a lost `revoke` left it opening the app, which on a development machine may well have an admin
panel in it. It never reached the agent, but it was more than "looking". Agreed with the control
server on 19 September 2026: the first below is done on the machine, the second is runbloom.app's.

1. **A person's cookie lasts one hour**, as a share link's already did (`PreviewRoutes.cookieLifetime`).
   Somebody who still has access loses a click: the page an expired cookie gets says to open the
   preview again from Bloom.
2. **runbloom.app retries `revoke` for at least that hour**, measured from the removal, and alerts
   if it is still undelivered. The machine records revocations in its database, so a restart does
   not lose one.

**The two numbers move together.** The cookie's lifetime is the longest any credential lasts on a
machine, and runbloom.app's retry window is sized to it. Lengthening the cookie without telling the
control server would let a lost `revoke` outlast its retries.

### What the new work adds

- **`cloud_workspace_start`** acts only as the person whose turn is running, named by the turn and
  never by a user id, so a machine can only ever act as whoever is prompting it. A crew member's
  chat, which has no person's turn, is refused on the machine before anything is sent, and
  runbloom.app refuses a turn with nobody behind it as well.
- **The opening prompt (v2)** is fetched by the new machine with its own secret, and the turn it
  runs is one runbloom.app registered for the creating turn's person; starting it still goes
  through `turns/{id}/start`, which runbloom.app checks against this workspace.
- **Part 2 below** keeps the same shape: a token scoped to one workspace and one person, verified by
  the machine that receives it. Nothing in it lets a machine accept a token for anything but
  itself.

## 2. Doing locally what Cloud can

### The short answer to "is it easy"

**Mostly yes, because runbloom.app is the authority and never the pipe.** It issues a short-lived
token for one workspace and one person, and whoever holds it talks to that machine directly. Three
of the four directions need nothing more than that. The one that does not is a message to somebody
who is not connected, and the proposal is to refuse it rather than store it.

| Direction | Today | Smallest shape that works | Size |
| --- | --- | --- | --- |
| Within one Bloom Cloud workspace | works: `agent_start`, `agent_say`, `agent_stop`, `agent_list`, `chat_list`, `chat_read`, `workspace_diff` | nothing | done |
| Mac to a Bloom Cloud workspace | the Mac already holds a token and a connection to each Cloud workspace it opens, and sends, reads chats and reads diffs through it | route the Mac bridge's `workspace_say`, `chat_read`, `chat_list` and `workspace_diff` through that connection when the named workspace is a Cloud one | small, and no protocol change |
| Bloom Cloud to Bloom Cloud | not possible: machines do not know each other | machine A asks runbloom.app for a session token for machine B, as the person whose turn is running, and talks to B at its own address | medium: one runbloom.app endpoint, a wire client on the machine, one field on `send` |
| Bloom Cloud to a Mac | not possible: a machine cannot open a connection to a Mac | send it back down the event stream the Mac already holds to the machine, as `request_pane` does | medium, and only while that Mac is connected |

### Mac to a Bloom Cloud workspace

**What exists.** The Mac's Cloud client (`MachineClient`, `WorkspaceConnection` in `BloomClient`)
holds a session token for each Cloud workspace that is open and speaks the whole protocol: `send`,
`transcript`, `review_snapshot`, `review_patch`. It acts as the signed-in person, which is who the
Mac's agent is working for.

**What is missing.** The Mac's bridge tools resolve a workspace in the local database, and a Cloud
workspace is not a row there. `workspace_list` does not list them and `workspace_say` cannot find
them.

**Smallest shape.** A seam in `AppModel.bridgeToolbox()`: when the named workspace is a Cloud one,
`workspace_say` becomes `send`, `chat_list` and `chat_read` read the snapshot and `transcript`, and
`workspace_diff` reads `review_snapshot`. `workspace_list` lists Cloud workspaces beside local ones
with a field saying which they are.

**One thing to get right.** A message sent this way arrives on the machine as the person's own
prompt, because the token is theirs. The machine should know it was written by an agent on their
behalf, so the transcript says so: an optional `via` on `send` (`{"kind": "agent", "workspace":
"...", "chat": "..."}`), shown under the author and never trusted for anything but the label.
Without it, the person reads a message they did not type as their own.

**Safety.** Nothing new: the Mac can only reach workspaces it already holds a token for, as the
person it already is. If a team switch is wanted, it is the one `cloud_workspace_start` checks.

### Bloom Cloud to Bloom Cloud

**Built on 19 September 2026**, to the shape agreed with the control server: `GET
.../workspaces?turn_id=` lists the workspaces the turn's person may open, and `POST .../tokens` mints
a session token for one of them, with `view` and `prompt` only, for that person, carrying the
standard `act` claim that names this workspace. The receiving machine reads `act` and labels the
message as an agent's even when the body leaves `via` out. runbloom.app refuses another team's
workspace (answered as if it did not exist), a removed member, a share guest, a turn that is not
running and a switch that is off, and limits minting to 20 a minute and 100 an hour per origin. The
machine refuses a crew chat before asking. See `RunbloomPeers`.

**The agent can mint such a token itself.** `bloom-runner` holds the token it asks for and uses it
for `workspace`, `new_chat` and `send`, but the agent runs as a user with passwordless sudo, can
read the workspace secret and a running turn's id, and so can call `POST .../tokens` directly. What
holds is therefore the receiving machine: **a token carrying `act` may run `workspace`, `new_chat`
and `send` and nothing else, whatever abilities it claims**, and is refused on the event stream and
the terminal (`RemoteCaller.agentMayRun`, `WorkspaceToken.refuseIfMintedForAnAgent`, and
`anActorTokenCanOnlySend`, which tries every operation in the vectors). An agent can say something
to another workspace its person can open, labelled as an agent's, and cannot read a file there,
stop or close anything, change a chat's permission mode or answer a question. The security review
of 19 September 2026 found the wider version as H1; the structural fix, a second Unix user without
sudo for the agent, is being designed.

**What exists.** Nothing: no machine knows another's address, and no machine holds a token for
another.

**Smallest shape.** runbloom.app mints, for machine A, a session token for workspace B:
`POST /api/machine/workspaces/{A}/tokens` with `turn_id` and the target workspace, answering the
token and B's URL. It is authorised exactly as `cloud_workspace_start` is: the turn's person, who
must have access to B, and the team switch. A then calls B with it. **B needs nothing new**: it
verifies the token as it verifies any client's, and the `aud` names B.

Missing on A: a protocol client on the machine (the Mac's `MachineClient` is the candidate, if it
builds on Linux), and the machine tools `workspace_list`, `workspace_say`, and reading tools that
take a workspace, whose descriptions now say only what the machine offers. On B: the `via` field
above.

**Cost.** The receiving machine runs a turn as the person, on their key and their limits, exactly
as if they had typed it. An agent in A that is told to talk to B can therefore spend on B. The team
switch and runbloom.app's limits apply to every token it mints; a rate limit on minting is the
guard against two agents talking each other into a loop.

**Hearing back.** B cannot call A without a token for A. The simplest answer is that A keeps B's
event stream open for the length of the conversation, as a client does, and reads the reply there.

### Bloom Cloud to a Mac

A Mac cannot be dialled, so whatever reaches it rides a connection the Mac opened. Three shapes,
weighed against the rule that nobody outside a workspace or team can instruct it, on 19 September
2026:

| Shape | Who carries the words | Who could instruct the Mac | Reach | Verdict |
| --- | --- | --- | --- | --- |
| **A. Down the event stream the Mac already holds to that machine** | the machine, over a connection the Mac opened with the person's own token | only an agent whose running turn belongs to the Mac's signed-in person | while that Mac has that workspace open | **recommended** |
| B. A standing outbound connection from the Mac to runbloom.app | runbloom.app, for every message | whoever runbloom.app forwards for, so its routing is now part of the Mac's attack surface | whenever the Mac is running | a relay: a second exception, and a standing one |
| C. A mailbox runbloom.app keeps and the Mac drains | runbloom.app, stored until read | as B, and the words are at rest on a server | even when the Mac is closed | a relay with storage: the widest exception of the three |

**A is built (19 September 2026)**: `mac_workspace_say` on the machine, the `mac_message` event, and
`Bloom-Client: mac` on the Mac's event stream so a browser holding the same person's stream is not
mistaken for their Mac. The Mac's half, receiving it into a local workspace, is the Mac client's.

**A, because it adds no party and no stored words.** The machine already talks to the Mac over the
stream (`pane_requested`), authenticated by a token that names the person, and runbloom.app never
sees what is said. What makes it safe:

- **The machine delivers only to streams whose token subject is the person whose turn is running.**
  A colleague prompting the same shared workspace can reach their own Mac and never another's: the
  person is taken from the turn, which runbloom.app registered, never from anything the agent says.
- **The Mac checks it again**: the event arrived on a stream it opened as its signed-in person, the
  named local workspace exists on this Mac, and the message goes in as a crew-style message headed
  with where it came from, in the untrusted envelope, never as words the person typed.
- **The team switch that gates Cloud to Cloud gates this too**: the machine asks runbloom.app the
  same question it asks before minting a token (is this turn's person allowed to message from here),
  so a team that has not said yes gets nothing.
- **A turn nobody started refuses**, as every agent-to-anywhere tool does: a crew chat has no person.

**What A cannot do, said plainly:** reach a Mac that is closed, or that has this workspace closed.
The tool answers that the person's Mac is not connected to this workspace and sends nothing. Keeping
a stream open to every Cloud workspace a person has, so that it could, would hold every one of those
machines awake and billing, which is a worse trade than the gap. **B and C close the gap and are
relays; neither is to be built without Freek's written exception**, bounded like the opening prompt
(encrypted, for one Mac, deleted when delivered, expiring).

**C was approved by Freek on 19 September 2026, and is built on the machine's side.** Direct first:
when a Mac stream (`Bloom-Client: mac`) of the turn's person is open here, the message goes down it
as above. Only when none is, a browser tab on this workspace not counting, the machine leaves it
with runbloom.app: `POST .../mac-messages` with `turn_id`, `target_workspace`, `text` and
`via.chat`, and an `Idempotency-Key` minted per tool call and kept across its retries, so a lost
answer queues nothing twice. There is no recipient field: runbloom.app delivers to the running
turn's prompter, found on its side. It keeps the message encrypted for seven days, fifty undelivered
at most per person and thirty deposits an hour per workspace, and deletes it when the Mac
acknowledges it or the person leaves the team. Its refusal sentences are passed to the agent as they
stand, with "try again in N minutes" added from `Retry-After`. See `RunbloomPeers.depositForMac`.

**Addressing** stays the hard part in any shape: the machine knows no Mac's local workspace names, so
the agent has to be told one, and only the Mac can refuse a wrong one, after the fact. A Mac that
sends its open local workspaces' names on connect would fix that, and is the first thing to add if A
is built.

### Local tools with no Cloud equivalent today

What the Mac's bridge offers an agent in a local workspace against what a machine offers. "Owner" is
a Mac-only role for the person's own client, not an agent.

| Local tool | On a machine | Could it be | Note |
| --- | --- | --- | --- |
| `whoami`, `chat_list`, `chat_read`, `workspace_diff`, `agent_*`, `cloud_setup` | yes | | reading tools are held to this workspace |
| `workspace_start` | `cloud_workspace_start` | yes, with an optional opening prompt and reasoning effort | the prompt and its validated effort are handed over once; see `OpeningHandoff` |
| `workspace_list` | yes, the team's other Bloom Cloud workspaces | | through runbloom.app; see "Bloom Cloud to Bloom Cloud" |
| `workspace_say` | yes, to another Bloom Cloud workspace | | through a token runbloom.app mints; labelled there |
| `workspace_rename` | no | yes, trivially | the protocol already has `rename_workspace` |
| `workspace_archive` | no | yes, through runbloom.app | the machine already has `archive_preview` and `archive` |
| `workspace_merge` | no | yes, through runbloom.app's GitHub App | a machine's own `gh` has no token that may merge |
| `workspace_tabs`, `workspace_tab_select` | no | as a request, like `request_pane` | the window is a client's |
| `pane_open`, `pane_split`, `pane_close`, `pane_rename`, `pane_list` | `request_pane` only | as requests | the window is a client's |
| `media_show` | yes, since 19 September 2026 | | see "Showing a picture" below |
| `reveal` | no | as a request | the window is a client's |
| `browser_*` (twelve tools) | no | only with a headless browser on the machine | large; the Mac's are a `WKWebView` in its window |
| `terminal_start`, `terminal_read`, `terminal_write`, `terminal_send_key` | no | yes | the machine already has tmux terminals and the protocol already attaches to them |
| `project_list`, `project_add`, `project_hide`, `project_unhide` | no | no | a machine holds one project |
| `quick_prompt_list`, `_create`, `_update`, `_delete` | no | the project's, read only | the person's own live on their client; `quick_prompts` answers the project's |

### Showing a picture

Freek, on 19 September 2026: "could we somehow add support for showing generated images and such.
locally we can do it and it's super handy."

**On a Mac**, `media_show` draws the file straight from the agent's call, because the file and the
window are on one disk. **On a machine they are not**, so `media_show` copies the file into the
worktree's git-ignored `.bloom/scratch/media/`, named by its SHA-256, and writes a `media` row into
the chat naming the copy. A client fetches it with `download`.

- **Authorised as everything else is**: `download` takes a session token for this workspace with
  `view`, is confined to the worktree by the descriptor walk every file read uses, and carries at
  most 8 MB. Showing a picture adds no door.
- **A reference in the row, never the bytes.** The row is `path`, `name`, `caption`, `kind`, `mime`
  and `bytes`; see "Media" in `docs/WORKSPACE-PROTOCOL.md`.
- **Types from the bytes, not the name**: PNG, JPEG, GIF, WebP, AVIF, MP4, MOV and WebM, up to 8 MB.
  A file named `.png` that is really something else is refused, so showing something is never a way
  to hand a viewer a file that is not a picture. SVG is refused because it can carry script.
- **Copied, not pointed at**, so a later screenshot at the same path does not change a picture that
  was already shown.

### `agent-browser` on a machine

**Not deliberately absent: nothing puts it there.** The machine image is the provider's own, with
`claude`, `codex`, `gh`, `git`, `tmux`, `node`, `python` and `go`, and Bloom installs only
`bloom-runner` on top. `agent-browser` is an npm command that fetches its own Chromium on first use,
and Chromium needs system libraries the image may not have.

**It is cheap in code and not free per machine.** A Sprite cannot be created from another's
checkpoint, so every workspace would download and install a browser from nothing, which is time
and disk on every create for a tool most turns never use. Three places it could go, cheapest first:

1. **A project's own `prepare` script**, for projects that want it. Works today, costs only the
   projects that ask, and `cloud_setup`'s guide can say how.
2. **Installed in the background after setup by `bloom-runner`**, pinned to one version, so a
   machine has it a minute after it is ready and nobody waits for it.
3. **At machine creation, by runbloom.app's bootstrap**, which puts it on the critical path of
   every create.

The recommendation is 2, measured first on a real machine for its time and disk, with 1 documented
meanwhile. It carries no new risk: an agent on a machine can already run any program, and a headless
browser reaches nothing the machine's network could not. **Together with `media_show`, it is the
screenshot loop Freek uses on a Mac**: `agent-browser` takes the picture, `media_show` puts it in
the chat.
