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

**Two clients come in on it, and neither is a special case of the other.** One is the owner's own
terminal, holding the token the welcome window's command line step or Settings > Command Line handed them. The other is Ask Bloom, the
conversation inside the app that belongs to no workspace: `BridgeServer.register(askSession:)`
attaches it to the same standalone token rather than minting one, because the definition above is
exactly what that chat is, and a fourth role or an invented workspace would have been the only
other ways to say so. It follows that regenerating the token from Settings cuts both off, which is
what a revocation should do.

Identity is minted by Bloom and handed to the CLI through the shim's environment, never claimed by
the agent. That is what lets a tool be implicitly scoped: **nothing a workspace agent calls takes a
workspace id as a parameter**, so there is nothing for a model to forge, mistype or hold on to after
it has gone stale. The owner's own client is the exception and has to be, because it is sitting in
no workspace: `reveal`, `workspace_merge` and `workspace_rename` are named a workspace out loud,
resolved against the rows that exist, and refused when a name is shared by two of them. A workspace
agent calling the last of those may not name one, and is refused rather than quietly given its
own.

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

Twenty-seven, each a type of its own in `Sources/BloomCore/Bridge/`, each carrying its own role
gate. A list of handlers rather than a switch, because a switch would put every tool in three
places: the listing, the dispatch and the gate.

| Tool | What it does | parent | child | owner |
| --- | --- | :---: | :---: | :---: |
| `whoami` | What this connection is: the workspace and its branch, the worktree path, the project, and whether the workspace was created by the owner or by another agent. From the owner's own client, which copy of Bloom was reached and how much it is holding | ✓ | ✓ | ✓ |
| `project_list` | Every project in the sidebar: name, path, default branch, live workspace count, whether it is still where Bloom recorded it, whether it is hidden | | | ✓ |
| `project_add` | Register a git repository that **already exists** as a project | | | ✓ |
| `project_hide` | Take a project out of the sidebar. A view preference and nothing more | | | ✓ |
| `project_unhide` | Put it back, in the place it already had | | | ✓ |
| `workspace_list` | Every workspace, its state, its worktree path, its chats and their cost, what an agent is stopped on, what is queued and why | | | ✓ |
| `workspace_start` | Cut a worktree and put an agent in it with a task, on a new branch or on a branch that already exists | ✓ | | ✓ |
| `workspace_rename` | Give a workspace the name the work in it turned out to be about. Its own, for a workspace agent; any of them, named out loud, for the owner | ✓ | | ✓ |
| `workspace_merge` | Ask a workspace's own agent to merge its pull request | | | ✓ |
| `reveal` | Point Bloom's window at one workspace, or at Home narrowed by project, scope and search. Navigation and nothing else: it creates nothing and archives nothing | | | ✓ |
| `pane_open` | Open a chat, a terminal or a browser in a new tab of the caller's own workspace | ✓ | | |
| `pane_split` | Put one beside what is on screen rather than behind it | ✓ | | |
| `pane_close` | Take one back off the screen | ✓ | | |
| `pane_rename` | Give a tab a name the reader can find it by | ✓ | | |
| `pane_list` | What the workspace has open: each pane's kind, its name, whether it is in the tab in front, and for a browser its number and its address | ✓ | | |
| `workspace_tabs` | The same window read as a strip: every tab in order, what it is called, which one is in front, and one true thing about what is in it | ✓ | | |
| `workspace_tab_select` | Make one of those tabs the one in front, by its number or by its name. It cannot make one | ✓ | | |
| `browser_read` | One browser's toolbar: address, page title, load state, whether Back and Forward would do anything | ✓ | | |
| `browser_reload` | Fetch that page again | ✓ | | |
| `browser_go` | Point a pane that is already open at another http or https address | ✓ | | |
| `browser_scroll` | Move the page up, down, to the top or to the bottom, and say where it ended up | ✓ | | |
| `browser_screenshot` | A picture of the pane as it is on screen, as an image | ✓ | | |
| `browser_text` | The visible text of the page, wrapped as untrusted content | ✓ | | |
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

### The sixteen that need the app, and the eleven that do not

`BridgeToolbox.standard` holds the eleven that reach nothing but the store, and it is what a
`BridgeServer` built without the app serves, which is every test that did not ask for more.
`AppModel.bridgeToolbox()` adds the other sixteen to it, because starting a workspace has to reach
the main-actor graph that runs one, asking for a merge has to reach the same path the Merge button
takes, moving the selection is the window's own, and a pane is a thing the window owns. Each of
those crosses the line as an injected closure
(`WorkspaceStarting`, `WorkspaceMergeRequesting`, `Revealing`, `PaneOpening`, `PaneSplitting`,
`PaneClosing`, `PaneRenaming`, `PaneListing`, `BrowserPaneCommanding`, `WorkspaceTabListing`,
`WorkspaceTabSelecting`), so a pane an agent asks for is the pane the
menu makes, unchanged and not copied. It adds them **to** `.standard` rather than listing its
handlers again, because a copy of that list is a copy that drifts: a tool added to the core toolbox
and not to the app's would pass every test in the suite and never reach the running app.

**The two tab tools are on that side for a reason worth stating plainly, because it is not the
same reason the browser tools are there.** A browser is a `WKWebView`, which is obviously the
window's. A tab looks like data and is not: the tool tabs are a JSON blob in user defaults that
only `CenterTabStore` reads, the split arrangements are more of the same under `WorkspaceTabsStore`,
and **which tab a workspace is in is in memory on the main actor and is written nowhere at all**.
There is no table to read, so there was never a version of these two that lived in
`BridgeToolbox.standard`. What that forces is the pair of closures above, and the same rule the
rest of the family follows: no workspace argument, so the caller reads and moves the strip of the
workspace it is standing in and no other.

**The last two of those are what a browser tool sees the window through.** `PaneListing` takes a
workspace and gives back a `PaneCensus`, and that shape is the point: there is no argument on it
that could ask the window to do anything, so the tool that reports cannot act. `BrowserPaneCommanding`
carries one `BrowserPaneCommand` and is what the other six share, so the pane a call means is
resolved once, by `BrowserPaneChoice.choose` in the core, rather than six times in the window.

**The four quick prompt tools are the case that shows where the line really is.** They write, and
they need no seam at all, because a quick prompt is a row in `quick_prompt` and `Store` is an actor
a handler on a background task calls directly. The window finds out the way it finds out about
every other write: the update hook publishes the `quickPrompts` domain and `QuickPromptCatalog`
re-reads. The panel used to read that list once and never again, so a prompt written over the
bridge was invisible for the rest of the session; it subscribes now. An injected main-actor closure
here would have been a second way to write the same row.

`workspace_rename` is on the same side for the same reason, and it is worth saying because a
workspace looks far more like a thing the window owns than a quick prompt does. It is not. A
workspace's name is one column of the `workspaces` table, the sidebar draws it from there, and the
sidebar re-reads on the `workspaces` domain already, because that is how it finds out about a
rename typed into the row itself. The write goes through `Store.update(workspaceID:)` and never
`upsert`: a diff stat refresh writes to that row every six seconds and an agent turn writes to it
for ten minutes, and a whole-value write would put both back to whatever the rename had read. See
`Tests/BloomCoreTests/WorkspaceWriteIsolationTests.swift`, which is that bug written down.

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

Nothing here opens or closes a tab except the tools whose whole subject that is. `workspace_tab_select`
brings an existing tab forward and will not make one on the way, which is what keeps "go back to the
terminal" from forking a second terminal.

Nothing archives. `workspace_archive` is not one of the twenty-seven: it removes a worktree and can
remove a branch with it, and the whole reason Bloom asks before archiving by hand is that the
answer is sometimes no. `reveal` is the answer to the request that wants one. Asked to clean up the
finished workspaces, an agent ends by putting the candidates on screen, selected, with the owner
looking at them and the button under their finger, which is a different thing from eight worktrees
being gone.

Nothing a rename touches is on disk. `workspace_rename` writes one column of one row: the branch,
the worktree, the pull request and the directory keep the names they have. That is worth saying out
loud in the tool's own description as well, because a model asked to "rename this workspace" that
believed the branch moved with it would report something to the owner that never happened.

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
verbatim, which is an undo that costs one call. The two delivery switches are the exception, and
deliberately: `sends_immediately` and `opens_new_chat` are reported by every one of these tools and
set by none of them, because they say what happens when the OWNER presses a row and a tool that
could arm them would be an agent arranging a turn he never read. A prompt restored by
`quick_prompt_create` comes back as an ordinary one, and the delete's answer says what he has to
turn back on. That last one is what a worktree does not have and
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

### The browser pane, and what it does and does not hand over

**Stated as a capability rather than as a list of tools: an agent working in a workspace can now
see what the owner has open in that workspace, read one of its browser panes as words or as a
picture, and move that pane about, in the workspace it is standing in and nowhere else. It cannot
run script in the page, click anything, fill anything in, or read anything the person cannot see on
the screen.**

That is the whole of it, and each half is deliberate.

**It cannot run script.** `evaluateJavaScript` would turn six narrow tools into a general
automation surface, and it is not here. The pane is the owner's own browser with his own session in
it, so a script in that page reads what he can read and acts as he acts: it can walk an
administration area, post a form, or lift a token out of `localStorage`. And the caller may be an
agent that has just read a web page, an issue or a dependency's README, which is to say an agent
holding text somebody else wrote. Keeping such a tool off the self-approval list would not rescue
it either, because a permission prompt showing a paragraph of JavaScript is a prompt nobody can
evaluate: two lines of it look reasonable to anybody. The honest substitute is the narrow verb, so
what Bloom offers is reading the visible text, taking a picture, scrolling, reloading and going to
an address, each of them a thing Bloom does rather than a thing the caller describes. What that
costs is real: no clicking, no forms, no waiting for a selector. An agent that needs those has a
browser of its own to drive, and the difference is that nobody is logged in there as him. If it is
ever wanted, the shape is a per-project setting, off by default, never self-approved, with the
script shown in the prompt, and it is a change to make with the owner asked first.

**The scripts Bloom does run are written out in `BrowserPageScript`, in full, at compile time.**
Two of them: `document.body.innerText` for the text, and a scroll. There is no case in that enum
that carries a string, and `BrowserSession.evaluate` takes a `BrowserPageScript` rather than a
`String`, so the signature is the guarantee rather than a convention somebody has to keep. The one
thing a caller influences is a distance, and it reaches the source as an `Int` that has already
been parsed out of JSON and range checked.

**What comes back off a page is marked as untrusted where it arrives.** A page can say anything,
including "ignore your instructions", and a model reading a wall of prose cannot tell which words
came from the owner. `browser_text` answers inside `BridgeUntrustedText`, which names the address,
says the lines are data, and quotes any line of the page that would have read as the closing
marker. That is not a defence and is not described as one: nothing stops a model that decides to
obey the page. It removes the excuse. The picture `browser_screenshot` returns carries the same
sentence beside it, and a browser tab's name and address are page-written too, so `pane_list` and
`browser_read` carry the note as well.

**Nothing here can reach another workspace's window.** There is no workspace argument on any of
them, exactly as with the four older pane tools, so an agent cannot read a page in a window
somebody is working in on the other side of the sidebar.

**And nothing here opens a page.** A caller names a browser by the number `pane_list` gives it,
counting along the strip, and the tools act only on a pane that already has a live web view.
`CenterTabStore.liveBrowser` is what they ask, never `browser(for:)`, so a listing cannot cause a
page to be fetched: a tab restored from the last launch that nobody has looked at is reported with
the address it remembers and refused for anything needing a live page. `browser_go` takes the two
schemes `pane_open` takes and refuses the rest, through the same reading, so neither door will
render `file:///` in the owner's window on a model's say-so.

### The strip, and what a tab tells a caller

`pane_list` and `workspace_tabs` report one window and are not two versions of one tool. The first
flattens a workspace into panes, which is the shape the browser tools need, because the question
they ask first is "which of the reader's browsers do you mean" and a browser is a pane wherever it
is sitting. The second is the strip itself, because that is the shape a person speaks in: "go back
to the chat about the parser", "bring the notes forward". A flat list of panes has nothing in it
that is a tab, since a split contributes two rows and neither of them is the thing the reader would
click.

A tab is one entry of that strip, and it is one of five things: a chat, a terminal, a browser, the
review or the notes. The first three a workspace can have several of; the last two it has exactly
one of each. A tab can also have been split, in which case it owns a small tree of panes and the
other things living in them have dropped out of the strip. That last part is the one piece of
window furniture a caller mostly does not need, so it is reported and kept small: a split tab lists
what it has absorbed, kind and name, and nothing else. Ratios, axes, which half has the keyboard
and the pane ids themselves are all left out, because there is no tool that takes any of them.

What each kind says is what Bloom is already holding:

| Kind | What the tab reports |
| --- | --- |
| `chat` | Which CLI drives it, the `sessions` row's own state, whether a turn is running, how many messages |
| `terminal` | The directory its shell was started in, and whether a shell has been started at all |
| `browser` | The toolbar: where it is pointed, what the page calls itself, whether it is loading, and the number the `browser_` tools take |
| `review` | The file it is on, or that it is on the whole change |
| `notes` | How long the note is, and never a word of it |

**The cases were chosen against a rule rather than by taste: nothing in a listing may cost a
subprocess or a request.** The two temptations were a terminal's live working directory and what is
running in it, and both mean asking tmux, inside a call an agent makes at the top of every turn. So
the tab says where its shell started and says out loud that it does not know the rest, which is a
true small answer instead of a plausible large one. For the same reason nothing here creates:
`CenterTabStore.liveBrowser` is asked rather than `browser(for:)` and `TerminalSessionStore.hasShell`
rather than `terminal(for:)`, so a listing cannot fetch a page or fork a shell in a worktree nobody
had opened.

**A tab is named by a number or by its name, and never by its id.** The number is its place in the
strip counting from 1, which is `BrowserPaneReport.number`'s argument applied again: a uuid is a
handle a model cannot read, cannot repeat to a person and can carry in from somewhere stale. The
title is accepted as well, which the browser tools deliberately do not do, and the difference is
that a browser's name is the page's own `<title>` while a tab is the one thing in this window a
person names out loud. A title that two tabs share is refused with their numbers rather than
resolved to the first, because guessing there means selecting a tab the caller did not name.

That title is whatever the strip draws, down to the fallback: a chat nobody has titled reads
`Untitled` in the strip, in the Go to Tab menu and over the bridge, because `workspace_tab_select`
takes back the name `workspace_tabs` handed out. One function answers it for all three,
`CenterTabStore.title`, and it was three functions with two different fallbacks.

**`workspace_tab_select` cannot create a tab, and that is the refusal it was written around.** The
tempting shape is "select it, and open it if it is not there", which reads as helpful and is how an
agent asked to go back to a terminal ends up forking a second one beside the one it meant. A name
nothing answers to is a refusal carrying the strip, ten tabs and a count of the rest, so the next
call can pick off it without a workspace of thirty tabs spending the whole refusal listing them, and
`pane_open` stays the only door a tab comes through. Selecting a chat also makes it the workspace's
active conversation, which is not an extra effect: it is what clicking that tab does, through the
same `WorkspaceTabsStore.select` the click goes through.

### Which branch a workspace starts on

`workspace_start` offers the choice the create sheet offers, and it is the sheet's own choice
rather than a second one written for the bridge. The sheet draws it as a tab strip,
`WorkspaceSourceTab`; over the socket it is two arguments, and `AgentStartSource` is the
translation between them.

| Argument | The tab it is | What happens to a commit |
| --- | --- | --- |
| `base_branch`, or nothing | Create new branch | It lands on a new branch, and merges into the branch that was named |
| `existing_branch` | Continue on existing branch | It lands on the branch that was named, and merges when that branch does |

Nothing said is a new branch from the project's default branch, which is exactly what the tool did
before there was a choice, so every caller written against the older tool keeps working. Naming
both arguments is refused rather than resolved to one of them: they are opposite in effect, and a
call that asked for both has not decided.

**The second one is here because the first one answers the wrong question about somebody else's
work.** Told to look at a colleague's branch, the tool could only cut a fresh branch off its tip,
so the worktree opened identical to that branch and the Changes tab drew nothing. It was right and
it was useless. That is the bug `docs/start-from.html` was written about, arriving a second time
through the other door.

The branch is found in the project before anything is cut, and both ways of not finding it are a
sentence rather than a failed start. A name that is not there is answered with the names that are,
which is the list the picker would have shown somebody who could see one. A branch something else
is already sitting on is refused with what has it, git's own worktrees included rather than only
Bloom's rows, because git allows one worktree per branch and the alternative is git exiting 128 in
the middle of a start. Both refusals end by offering `base_branch` on the same name, which is a
different intention and Bloom does not take it on a caller's behalf.

A pull request cannot be named, though the sheet's second tab lists them beside the branches.
Resolving one costs a `gh` call and a network round trip on a path that otherwise spends only local
git, and an agent that wants a pull request's code can name its head branch, which is what the
picker draws a listed pull request by anyway. `WorkspaceCheckout` already carries the case, so the
day it is wanted it is an argument rather than a mechanism.

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
| `whoami`, `workspace_start`, `pane_open`, `pane_split`, `pane_close`, `pane_rename`, `workspace_rename`, `pane_list`, `workspace_tabs`, `workspace_tab_select`, `browser_read`, `quick_prompt_list`, `reveal` | everything else |

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

`workspace_rename` is on it, and it is the entry that had to be argued against the quick prompt
paragraph below rather than against the pane one above, because it overwrites something and keeps
no copy. Three things settle it. What it overwrites is one column of one row, and a label Bloom
proposed most of the time, rather than a paragraph the owner wrote by hand. The change is in the
sidebar row the reader is looking at as it lands, which is the same visibility a pane's name has,
and typing over it is a double click away. And the answer carries the name the workspace had, so
undoing it from the far side of the socket costs one more call. Against that sits the reason it
must not ask: this tool exists because an agent nine commits into a piece of work stopped and asked
the owner to rename the workspace by hand, and a permission prompt on a parent running unattended
is the hung turn this whole section is about, spent on a label.

The two tab tools follow them. `workspace_tabs` reports the same furniture `pane_list` reports in
another shape, all of it on the screen in front of the reader and none of it the contents of a
page, a diff or a note. `workspace_tab_select` is `pane_open` with less in it: that one both makes
a tab and brings it to the front and is already on this list, so asking before an agent may bring
forward a tab that already exists would cost a hung turn and protect nothing. What it changes is
which tab the reader is looking at, and one click puts it back. The cost that is real is
interruption, and it is answered in the tool's description rather than by a prompt: a person may be
typing in the tab in front, so the tool says to ask before pulling them out of it.

**The seven browser tools split, and the line between them is the chrome.** `pane_list` and
`browser_read` report the strip and the address bar: what is open, what it is called, where each
browser is pointed, whether it is loading. Every fact of that is on the screen in front of the owner
already, none of it is the contents of a page, and they have to be callable unattended because they
are the first call of any turn that then does something useful. The other five are off the list, in
two groups. `browser_reload`, `browser_go` and `browser_scroll` change what the person is looking
at: a reload can lose what they had half typed into a form, a navigation is a request made from
their browser with whatever they are logged into, and a scroll moves the page under somebody who is
reading it. `browser_screenshot` and `browser_text` carry the page itself into a model's context,
which is to say off this machine, and a page he is signed into is his own data. Bloom cannot tell a
dev server's front page from an administration screen, so it does not try: it asks, and the person
who can tell answers.

`reveal` is on it, and it is the one entry whose argument runs the other way from the paragraph
below. It is called by the owner's own client, so the owner IS sitting there, and asking would put
a question in front of somebody who has just said out loud "show me those". It creates nothing,
archives nothing and touches no file: what it costs is a glance, and the way back is a click.

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
