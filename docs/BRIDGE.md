# The Bloom bridge

What an agent can ask Bloom to do, and which callers may ask for what. The other direction from
`AGENTS-INTEGRATION.md`, which is about Bloom reading what the CLIs put on disk; this is the CLIs
calling back in.

Everything here is read off `Sources/BloomCore/Bridge/`, which is where all of it lives. The heads
of the files named below carry the reasoning at length, and this is the map over them.

Related: `AGENTS-INTEGRATION.md` (registering Bloom in a client the owner runs themselves),
`PROTOCOL.md` (Claude Code's stream-json), `CODEX.md` (Codex's app-server).

---

## 1. Why there is a shim at all

Bloom serves MCP over a unix domain socket. Neither CLI can speak to one: Claude Code registers an
MCP server as a stdio command or an HTTP URL, Codex as a stdio `command` or a streamable HTTP
`--url`, and that is the whole list on both. HTTP on localhost was refused for a different reason,
which is that it would be one port for the whole machine, reachable by every local process, and
impossible to share between Bloom and Bloom Dev, a pair that is a documented permanent arrangement
rather than a test setup.

So the registered transport is stdio and the socket sits behind it. `bloom-bridge` is the stdio
process the CLI launches, shipped inside Bloom's own bundle, and it is a line relay and
deliberately not an MCP implementation:

```
agent CLI  ──stdio──▶  bloom-bridge  ──unix socket──▶  Bloom
```

**Every behaviour that lives in the shim is a behaviour that can skew against the app.** Sparkle
replaces the bundle underneath a running Bloom and the CLI launches whatever binary the path in its
config names, so a shim that knew anything about tools could be a version behind the app it is
talking to. A relay changes almost never; the tool surface changes every time a tool is added. So
`initialize`, `tools/list` and `tools/call` are all answered in the app, in `BridgeDispatch`, where
the store is reachable.

The shim sends one hello line before any MCP byte crosses, carrying a protocol version, the token
and the claimed role, and Bloom answers with one welcome line that accepts or refuses. The version
is compared for **equality and never as a range**, because the skew to design for is a new shim
meeting an older running Bloom after Sparkle swapped the bundle mid-session. Both directions have
to fail with a sentence rather than hang: a hung tool call is a hung turn, and a model cannot tell
one from the other. See `BridgeProtocol` and `BridgeShim`.

The shim exits with distinct statuses because the CLI prints them, and "exited 1" says nothing that
"Bloom is not running" does not say better: `64` nothing to connect to, `69` could not reach Bloom
or Bloom went away mid-answer, `70` refused at the handshake.

## 2. Who is calling, and how Bloom knows

Three roles, in `BridgeIdentity.swift`.

| Role | What it is | What it is scoped to |
| --- | --- | --- |
| `parent` | A workspace the owner created | Its own worktree, implicitly |
| `child` | A workspace an agent created | Nothing. It reports and that is all |
| `owner` | The owner, through a client of their own, sitting in no workspace | Nothing implicitly. Everything is named out loud |

**The role is read from the database at mint time, never from the shim's environment.** The
environment carries a claimed role, and it is carried for diagnostics only: anything running as the
user can launch the shim by hand with any role it likes, so a claim that disagrees with the
database is worth a log line and nothing else. A workspace with a parent is a child, and that is
the whole test. There is no depth counter, because the limit on nesting is one, so "has a parent"
**is** the depth and a number kept beside it is a number that can drift.

`owner` is the odd one. The other two are derived from a workspace row and this one is derived from
nothing: no session, no worktree, no project. **It is not a child**, because a child is penned in
for being an agent that another agent asked for and nobody weighed. **It is not a parent either**,
because every tool a parent has is implicitly scoped to the worktree it is sitting in and this
caller is sitting in none.

Identity is minted by Bloom and handed to the CLI through the shim's environment, never claimed by
the agent. That is what lets every tool be implicitly scoped: **no tool takes a workspace id as a
parameter**, so there is nothing for a model to forge, mistype or hold on to after it has gone
stale.

The token is **not a secret and must not be commented as one**. Any process running as the user can
read `ps`, the mode 0600 config file and the socket itself, and an agent has the user's whole home
directory anyway. What actually holds, whoever connects, is server side: parentage read from the
database, git's own safety reports, and counts. Session tokens are minted per launch and held in
memory only, so a quit retires them; the owner's standalone token is the one exception and
`BridgeOwnerToken` sets out at length why a coupling that breaks every time the app restarts is not
a coupling.

The socket path is derived from the database path through the same fingerprint the tmux socket name
uses, so Bloom and Bloom Dev can never land on one. The landmine there is `sockaddr_un.sun_path`,
104 bytes on macOS, which **truncates in silence**: two instances whose paths agree for the first
103 bytes quietly share one socket, which is the exact failure the fingerprint exists to prevent.
`BridgeSocketPath` asserts the length rather than trusting that it fits.

## 3. The tools

Sixteen, each a type of its own in `Sources/BloomCore/Bridge/`, each carrying its own role gate. A
list of handlers rather than a switch, because a switch would put every tool in three places: the
listing, the dispatch and the gate.

| Tool | What it does | parent | child | owner |
| --- | --- | :---: | :---: | :---: |
| `whoami` | What this connection is: the workspace and its branch, the worktree path, the project, and whether the workspace was created by the owner or by another agent. From the owner's own client, which copy of Bloom was reached and how much it is holding | ✓ | ✓ | ✓ |
| `project_list` | Every project in the sidebar: name, path, default branch, live workspace count, whether it is still where Bloom recorded it, whether it is hidden | | | ✓ |
| `project_add` | Register a git repository that **already exists** as a project | | | ✓ |
| `project_hide` | Take a project out of the sidebar. A view preference and nothing more | | | ✓ |
| `project_unhide` | Put it back, in the place it already had | | | ✓ |
| `workspace_list` | Every workspace, its state, its worktree path, its chats and their cost, what an agent is stopped on, what is queued and why | | | ✓ |
| `workspace_start` | Cut a worktree on a new branch and put an agent in it with a task | ✓ | | ✓ |
| `workspace_merge` | Ask a workspace's own agent to merge its pull request | | | ✓ |
| `pane_open` | Open a chat, a terminal or a browser in a new tab of the caller's own workspace | ✓ | | |
| `pane_split` | Put one beside what is on screen rather than behind it | ✓ | | |
| `pane_close` | Take one back off the screen | ✓ | | |
| `pane_rename` | Give a tab a name the reader can find it by | ✓ | | |
| `quick_prompt_list` | The owner's own quick prompts, whole, with the ids the other three take | ✓ | | ✓ |
| `quick_prompt_create` | Write a new quick prompt into that library | ✓ | | ✓ |
| `quick_prompt_update` | Change one, field by field, leaving the fields it does not name alone | | | ✓ |
| `quick_prompt_delete` | Take one out of the library for good | | | ✓ |

**A child sees `whoami` and nothing else.** That is not an oversight and not a cost saving: a child
is a workspace an agent asked for, which nobody weighed, so it reports and that is all.

The gate is enforced twice on purpose. `tools/list` hides what the caller may not use, so a child
never sees a tool to be tempted by, and `tools/call` refuses it again, so a process speaking raw
MCP at the socket with a child's token gets nowhere either. A tool that exists but is refused
answers exactly as an unknown name does, so the refusal cannot be read as a hint that something is
there.

A refusal is a result with `isError` set and never a JSON-RPC error frame. A JSON-RPC error is a
transport failure the CLI may retry or surface as a broken server; an errored result is text the
model reads and can act on. "You are not allowed to do that" is something to tell the model, not
something to tell the transport.

### The six that need the app, and the ten that do not

`BridgeToolbox.standard` holds the ten that reach nothing but the store, and it is what a
`BridgeServer` built without the app serves, which is every test that did not ask for more.
`AppModel.bridgeToolbox()` adds the other six to it, because starting a workspace has to reach the
main-actor graph that runs one, asking for a merge has to reach the same path the Merge button
takes, and a pane is a thing the window owns. Each of those crosses the line as an injected closure
(`WorkspaceStarting`, `WorkspaceMergeRequesting`, `PaneOpening`, `PaneSplitting`, `PaneClosing`,
`PaneRenaming`), so a pane an agent asks for is the pane the menu makes, unchanged and not copied.
It adds them **to** `.standard` rather than listing its handlers again, because a copy of that list
is a copy that drifts: a tool added to the core toolbox and not to the app's would pass every test
in the suite and never reach the running app.

**The four quick prompt tools are the case that shows where the line really is.** They write, and
they need no seam at all, because a quick prompt is a row in `quick_prompt` and `Store` is an actor
a handler on a background task calls directly. The window finds out the way it finds out about
every other write: the update hook publishes the `quickPrompts` domain and `QuickPromptCatalog`
re-reads. The panel used to read that list once and never again, so a prompt written over the
bridge was invisible for the rest of the session; it subscribes now. An injected main-actor closure
here would have been a second way to write the same row.

`BridgeServer` **never constructs an `AgentRunner`, and nothing added to it ever may.** One runner
per session is held in main-actor UI object identity, and a handler that built its own would put a
second CLI process on the same session row and the same worktree, both writing `agent_session_id`
and both editing the same files. It holds no database connection of its own either: `Store` is an
actor whose `update` methods re-read inside the actor, so a handler on a background task calls them
directly, and a second `SQLiteDatabase` on the file is the cross-connection sequence race that
`UNIQUE(session_id, seq)` exists to survive rather than to invite.

## 4. What an agent cannot reach through it

Nothing here reads or writes a file, runs a command, or touches a repository's contents. The
worktree path is handed over precisely so the agent uses **its own** tools on an ordinary git
checkout, which `workspace_list`'s description says out loud.

Nothing archives. `workspace_archive` is not one of the sixteen: it removes a worktree and can
remove a branch with it, and the whole reason Bloom asks before archiving by hand is that the
answer is sometimes no.

Nothing merges. `workspace_merge` **does not merge**: it composes the request Bloom's own Merge
button composes and sends it into that workspace's chat as an ordinary message, so the agent runs
`gh pr merge` there, in front of the owner, under whatever permission mode they set. Its
description tells the caller not to run `gh pr merge` itself when the tool refuses.

`project_add` registers and does not create. The failure it is written against is not a wrong path,
it is a helpful agent: told "add my projects", handed a folder git does not recognise and given a
bare "not a git repository", a model reaches for `git init` and makes a repository where nobody
asked for one, with whatever was lying in the folder as its first commit. The refusal is written to
head that off in words rather than to hope.

A parent cannot name a project, because its own is the only one it may act in, and `project` is
refused rather than ignored if it names one. The owner's client must name one, because nothing else
says which.

**One thing on the bridge can now be destroyed, and it is a few lines of the owner's own writing.**
`quick_prompt_update` overwrites a prompt and `quick_prompt_delete` removes one, and Bloom keeps no
copy of what was there before. Three things hold that in: both are owner only, so the caller is a
client the owner is typing into rather than an agent running for ten minutes unattended; neither is
self-approved, so the call stops and asks a person who is sitting there; and the delete's answer
carries the whole prompt back, name, mark and text, so `quick_prompt_create` writes it again
verbatim, which is an undo that costs one call. That last one is what a worktree does not have and
is why archiving is still not here.

A quick prompt deleted over the bridge is deleted exactly as one deleted in the panel is, because
it is the same call. **A built-in stays deleted.** Bloom seeds its built-ins once and records the
seed version it reached, rather than reconciling a list against the table, so a prompt the owner
threw away is not read back as one that is missing. Nothing in the four tools writes that recorded
version, so no tool can reseed and none of them can resurrect what it deleted. The one write the
listing can make is the seeding itself, on a copy of Bloom whose panel has never been opened, which
is exactly what opening the panel would have done: the tools and the panel have to describe the
same library, or an agent asked to add "Explain changes" writes a second copy of the prompt Bloom
is about to insert. See `QuickPromptSeed` and `QuickPromptCall`.

The library is **global**, which is why the two that change it are shaped differently from every
workspace scoped tool. The pane tools came off `.owner` because they act on the worktree the caller
is standing in and that role stands in none; a quick prompt belongs to no worktree, so there is
nothing for the owner's client to be missing and the argument runs the other way. `.parent` keeps
the two that cannot lose anything, because the owner mostly talks to Bloom from inside Bloom and
"save that as a quick prompt" is a sentence typed into a workspace chat. It does not get the two
that overwrite and delete: a parent runs unattended, and a change to a global library decided in
the middle of one of those turns up weeks later in a project that workspace had nothing to do with.

`quick_prompt_update` is partial, and its description says so before it is called once, because a
model that reads "update" as "replace" blanks the text every time it fixes a name. A field left out
keeps the value the row holds. `name` passed as an empty string clears the name, which is a state
the panel's own form can produce: the row falls back to showing the start of its text. `text`
cannot be blank, because a prompt with no words in it inserts nothing, and that is the same rule
the form enforces by disabling Save. A call that names no field at all is refused rather than
answered with "nothing changed", because the next call a model makes after those two answers is a
different call.

### How many a caller may start

`WorkspaceStartAllowance` holds all three answers in one switch, and they are one rule with one
variable in it, which is **how much a workspace costs the caller to ask for**.

| Caller | Brake |
| --- | --- |
| The Create sheet, a `bloom://` link, the Services menu, a Shortcut | None. Each is a deliberate gesture per workspace |
| A parent agent | Eight running children at once |
| The owner's own client | Six starts in fifteen minutes |

The two brakes are shaped differently on purpose. A parent's children are work it is waiting on, so
what matters is how many are alive at once and a ceiling is right. The owner is a person whose
workspaces accumulate over weeks, so a ceiling would refuse the eleventh workspace of a busy
fortnight, which is ordinary use; what is not ordinary is the rate. Neither number is a safety
limit. Six worktrees and six agents is already real money, and the point of both is that somebody
notices at six or at eight instead of at forty.

Both are counted from the database rather than kept in memory, so they survive a restart and two
calls racing cannot both read the same stale number.

Every start is deduplicated by a digest of the call, because a model retries and a retried spawn
cuts a second worktree. A repeat answers with the workspace that already exists and a note saying
so, rather than with a second one.

## 5. Which questions Bloom answers for itself

**A bridge call raises a permission question like any other tool call.** Measured: on claude
2.1.238 under `acceptEdits`, calling `whoami` produced an ask for
`mcp__bloom-workspace-bridge__whoami` and the turn stopped until it was answered. Being an MCP tool
does not exempt a call from the permission machinery, which was half the reason the bridge is MCP
rather than a CLI the agent shells out to. The first `workspace_start` in a project stopped a
parent's turn on an ask, and with nobody watching that workspace the turn sat waiting and died
`cancelled` when the app quit, having started nothing. **A feature whose first use hangs unless
somebody happens to be looking is a feature that does not work.**

So `BridgeToolApproval` names the tools Bloom answers for itself:

| Self-approved | Not |
| --- | --- |
| `whoami`, `workspace_start`, `pane_open`, `pane_split`, `pane_close`, `pane_rename`, `quick_prompt_list` | everything else |

It is a list rather than "anything with our prefix", so a tool added later is opted in by somebody
thinking about it rather than by inheriting a decision made before it existed.

Answering is not a shortcut round consent, because **Bloom is on both ends of this question**. It
wrote the tool, it minted the token, it knows which workspace is asking, and it enforces every
limit itself: the role gate hides `workspace_start` from a child, the handler refuses a caller that
was itself agent-started, and eight is the ceiling. There is nothing for a person to weigh that
Bloom has not already decided, and the ask carries no information a person could act on beyond "an
agent would like to use Bloom". None of that is true of the tools the agent brings with it: `Bash`,
`Write` and `Edit` reach outside anything Bloom knows about, and nothing here touches them.

The four pane tools are on the list because each adds or changes something the reader can see and
undo, in the workspace whose agent is asking and nowhere else. `pane_close` refuses the two cases
that would cost anything: it will not empty the centre column, and it cannot close the review or
the notes, which hold the reader's own work.

The project tools are not on it, and that is deliberate rather than an omission: the list is for
tools an agent must be able to call while nobody is watching, and those are called by the owner's
own client, where the owner is by definition sitting there to answer.

`quick_prompt_list` is on it and the other three quick prompt tools are not, which is the same test
applied four times. The listing is offered to `.parent`, so it can be called by an agent running on
its own, and it reads the owner's library and changes nothing in it: the ask would carry nothing for
a person to weigh and an unanswered one would hang the turn for no gain. `quick_prompt_create`
writes a row into a panel nobody is looking at, rather than putting something in front of the
reader the way a pane does, so it is worth one ask; the cost of that ask is the hang described
above, and it is accepted because the tool is only ever called on the owner's own instruction, in
the chat they typed it in, which its description says out loud. `quick_prompt_update` and
`quick_prompt_delete` take words the owner wrote by hand and there is no undo, which is the clause
`BridgeRole.owner` is written against.

`workspace_merge` draws the line one step further out. It destroys nothing, it sends a turn. But
what that turn leads to is a call to a server other people share, and unlike a worktree there is
nothing on the far side to restore. **Bloom answering its own permission question there would be
Bloom deciding to publish, which is the one decision it has never had.**

A self-approved ask still leaves a settled row in the transcript, saying what happened and who let
it through. "Allowed automatically" with no reason is the thing that makes people distrust an app's
permission model.

## 6. How each CLI is told the bridge exists

Two completely different mechanisms, both verified against the installed binaries.

**Claude Code** reads a JSON file named by `--mcp-config`, written mode 0600 in a 0700 directory,
one per session, rewritten from scratch at every process start because the token in it is minted
per launch. **A file, never the inline JSON string the same flag also accepts**, because argv is
visible in `ps` and an agent runs `ps` through its own Bash tool as ordinary behaviour. Never
`--strict-mcp-config` beside it: that flag shuts every other MCP configuration out, which is right
for `WorkspaceNamer` and wrong for a chat, where the user's own servers have to survive. Measured
on 2.1.238 by running a live turn, because `claude mcp list` rejects `--mcp-config` outright and
nothing short of a turn exercises it: `system/init` listed the user's own servers alongside Bloom's,
all connected, and the tool reached the model as `mcp__bloom-workspace-bridge__whoami`, hyphens
carried through.

**Codex** takes `-c mcp_servers.<name>.…` overrides carrying the same values inline. Bloom already
runs one app-server process per chat, so a per-process override is a per-session registration, the
same as Claude Code's per-start argv. Never `--strict-config` beside it: a different flag from
Claude Code's, the same trap, and it makes Codex refuse to start on a user config holding anything
the build does not recognise.

The server name is `bloom-workspace-bridge`, and it is **a correctness requirement with a test
behind it** rather than a convention. Codex `-c` overrides do not shadow a colliding
`mcp_servers.<name>` entry, they deep-merge it leaf by leaf: against a config holding a user's own
server called `bloom`, overriding `command` and `env` produced Bloom's binary launched with the
user's `args` and the user's `env` key still present, and `codex mcp list` reported that chimera as
one healthy server with no warning at all. There is no `-c` form that replaces a whole entry. So
the only defence is a name nobody would type, and the failure it prevents does not look like a
naming problem when it happens.

The owner's own standalone registration is a third thing, under a **different** name derived per
copy of the app, and `AGENTS-INTEGRATION.md` is where that half is written down: what
`claude mcp add` accepts, why the scope is `user`, and why the name is neither `serverName` nor one
constant for every copy of Bloom.
