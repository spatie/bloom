# Codex in Bloom

Ground truth plus the plan for the rest of the work. Everything under "Verified" was measured
against `codex-cli 0.147.0` on this machine, driving the real binary, on 2026-08-21. Everything
under "Plan" is a decision, not a measurement, and is meant to be argued with.

Related: `AGENTS-INTEGRATION.md` (how the four CLIs are detected), `PROTOCOL.md` (Claude Code's
stream-json), `PLAN.md`.

---

## 1. The protocol, and why

**Bloom drives `codex app-server --listen stdio://`, which is JSON-RPC 2.0 over stdio. It never
uses `codex exec --json`.**

`codex exec --json` is NDJSON, one event per line, and looks like a drop-in for the reader
`AgentRunner` already has. It is a trap:

- **No text deltas.** Events are item-granular, so a reply appears all at once when it is finished.
  Bloom's transcript types as the model does. `exec` cannot do that.
- **No reasoning items**, so every thinking row would simply be absent.
- **No approvals at all.** Run with `-s read-only -c approval_policy=on-request` and a prompt that
  has to write a file, and nothing is asked: the patch is refused and the turn carries on. There is
  no wire on which a question could arrive. That is the same failure Bloom already fixed once for
  Claude Code with `--permission-prompt-tool stdio`.

app-server has all three, plus typed lifecycles, token usage, rate limits and thread status. It is
also what Conductor drives. The reasoning is repeated in the doc comment at the top of
`Sources/BloomCore/Agent/Codex/CodexProtocol.swift`, because `exec` will keep looking tempting.

### The protocol describes itself

```
codex app-server generate-json-schema --out <dir>
```

writes every request, response and notification as JSON Schema: 95 client methods, 1 client
notification, 70 server notifications, 10 server-to-client requests. Regenerate it rather than
reading a transcript and guessing. Do not commit the dump; it is 1.1 MB and it is reproducible.

### Verified facts

| Fact | Detail |
| --- | --- |
| Handshake | `initialize` (request) then `initialized` (notification), in that order |
| No `jsonrpc` member | Not in the schema, not on the wire. A decoder that requires it drops every line |
| Server request ids | The server's own numbering, starting at **0**. Classify frames by their members, never by id |
| Thread ids | Stable across `thread/resume`. Resuming returns the same id that went in |
| `thread/start` sandbox | Kebab-case `read-only`, `workspace-write`, `danger-full-access`. `readOnly` is rejected outright |
| `turn/start` sandboxPolicy | A *different* type, camelCase `readOnly`, `workspaceWrite`, `dangerFullAccess`, `externalSandbox` |
| `turn/start` returns | The turn in `inProgress`, not the finished one. The answer is the `turn/completed` notification |
| `turn/interrupt` | Needs **both** `threadId` and `turnId`. Thread id alone is "missing field `turnId`" |
| Interrupt result | `turn/completed` with status `interrupted` |
| Per turn | `model`, `effort`, `approvalPolicy`, `sandboxPolicy`, `serviceTier`, `personality` |
| Attachments | `UserInput` has a `localImage` variant taking a path. Bloom's existing approach works unchanged |
| stderr | The server logs tracing there. Never merge it into the frame stream |
| Cost | Tokens only. There is no price anywhere on this protocol |

### Measured behaviour, not inferred

Three questions that could only be answered by running the thing.

**Does `on-request` plus `read-only` ask about everything?** No. One turn told to run `ls`, read a
file and then write one: **two commands ran with zero questions**, and the only questions were the
three write attempts. Reading and running are what the sandbox allows, so they never reach an
approval; writing is what it refuses, so every write becomes a question. That is a usable Ask mode
and it is what shipped. It is also worth knowing the shape of it: a Codex chat in Ask never
interrupts you about a `grep`, and always interrupts you about a `sed -i`.

**Can a refusal carry a reason?** Not on the approval wire, which takes a word. But `turn/steer`
puts text into a turn that is already running, and it was measured both ways: after a bare
`decline` the agent tried the same patch again immediately, twice; after `decline` plus a steered
sentence saying the file should be named differently, it wrote the different name. So Bloom sends
the reason as a steer right behind the refusal, and a Codex denial says as much as a Claude Code
one.

That same call is why a queued message no longer waits for a turn to end on this backend.
`CodexRunner.send` steers when `handle.turnID` names a live turn and starts a turn otherwise, and
it starts one after a steer that missed, because the turn id can be a tenth of a second stale. It
is deliberately not `turn/start` twice: what the server does with a second `turn/start` on a thread
whose turn is open has never been measured here, and a person's sentence is not the thing to find
that out with. See `AgentKind.acceptsMidTurnMessage`.

**What is in `FileUpdateChange.diff`?** Not always a diff, which is the trap in the name:

| Kind | What the field holds | Recorded |
| --- | --- | --- |
| `update` | A unified **hunk**: `@@ -1,3 +1,3 @@` and its lines. No `---`/`+++` headers | `Tests/fixtures/codex-edit-patch.ndjson` |
| `add` | The **whole new file**, verbatim, no diff markers at all (`"hi\n"`) | `Tests/fixtures/codex-approval.ndjson` |
| `delete` | Presumed symmetrical. **Not observed**, and treated as content rather than as a diff | |

Anything counting `+` lines to size a new file counts zero, which is what the turn footer would
have reported for every file a Codex chat created. `CodexFileUpdate.addedLines` counts by kind.

### `model/list`, verified unauthenticated

It answers in full against a scratch `CODEX_HOME` with no credentials, so a picker can be filled
before anyone signs in. What it returned:

| Model | Default | Reasoning efforts | Default effort |
| --- | --- | --- | --- |
| `gpt-5.6-sol` | yes | low, medium, high, xhigh, max, **ultra** | low |
| `gpt-5.6-terra` | | low, medium, high, xhigh, max, **ultra** | medium |
| `gpt-5.6-luna` | | low, medium, high, xhigh, max | medium |
| `gpt-5.5` | | low, medium, high, xhigh | medium |
| `gpt-5.2` | | low, medium, high, xhigh | medium |

**The efforts belong to the model.** Bloom's flat five-entry list in `ComposerOption.efforts` is
wrong for three of these five, in both directions: it hides `ultra`, which two models take, and it
offers `max` to two models that do not. Conductor hardcodes its list and is already stale: it names
`gpt-5.4`, which no longer exists, and has none of the three `gpt-5.6` models. **Fetch it.**

---

## 2. What exists after this pass

Four new files in `Sources/BloomCore/`, nothing else touched:

- **`CodexProtocol.swift`**, the wire vocabulary. `CodexRequestID`, `CodexRPCError`,
  `CodexFrame.decode(line:)` (response / failure / server request / notification / malformed),
  `CodexOutgoing` for building frames, and `JSONValue.object(omittingNil:)` because `sandbox: null`
  is not the same request as no `sandbox`.
- **`CodexEvent.swift`**, the event model. `CodexItem` over the eighteen thread item types, ten of
  them lifted into structs and the rest keeping their JSON; `CodexTurn`, `CodexThreadStatus`,
  `CodexTokenUsage` (with `agentUsage`, mapping onto Bloom's own `AgentUsage`), `CodexApprovalRequest`
  and `CodexApprovalDecision`; `CodexEvent.decode(_:)` for the notifications a session needs.
- **`CodexClient.swift`**, an actor over `StreamingProcess`. Request ids, a pending map, the
  handshake, a per-caller event stream, and `answer(_:with:)` for server-initiated requests. Typed
  calls for `thread/start`, `thread/resume`, `turn/start`, `turn/interrupt`, `model/list`.
- **`CodexModelCatalog.swift`**, holding `CodexModel` and `CodexReasoningEffort` and an actor that fetches
  once, shares an in-flight fetch between callers and holds the answer for fifteen minutes, the way
  `AgentCatalog` does.

Tests: `Tests/BloomCoreTests/CodexProtocolTests.swift` and `CodexClientTests.swift`, 42 of them,
reading four recorded fixtures in `Tests/fixtures/` (`codex-turn.ndjson`, `codex-approval.ndjson`,
`codex-interrupt.ndjson`, `codex-model-list.json`) captured off the real server. Recorded rather
than invented, which is how the missing `jsonrpc` member and the server's request numbering were
found.

### The second pass, since

- **`SessionRunner.swift`**, the seam: the four members `TranscriptModel` calls plus the one the
  permission prompt calls, and `EventFanout`, which is why every consumer gets its own stream.
  Adopted on the Codex side only; conforming `AgentRunner` is one line, no redesign.
- **`CodexTranslation.swift`**, Codex items into `AgentEvent`, **and into Claude Code's stream-json
  shape on the way to the database**. See §6, which is the most load-bearing decision in this work.
- **`CodexPermission.swift`**, the five request shapes as `PermissionAsk`s, with a stored
  `control_request` envelope so a reopened workspace can redraw a question it is still holding.
- **`CodexRunner.swift`**, an actor conforming to `SessionRunner`: connects, starts or resumes the
  thread, persists the thread id, writes the same rows, matches stored grants, answers.
- **`Views/Transcript/CodexItemPresenter.swift`**, plus a `TranscriptPresenter` router that picks a
  presenter by reading the row's payload.
- **`Session.agentKind`** and its migration, defaulting every existing row to `claudeCode`.

Tests: 87 across twelve suites, all on recorded payloads.

### The third pass, since

The wiring, and the three things only a live server could answer (see "Measured behaviour"):
`AgentRunner` conforms to the seam through an extension rather than an edit, `TranscriptModel`
picks a runner by `session.agentKind`, `canRunWorkspaces` admits two, the composer's model menu has
a section per backend with Codex's models fetched and its efforts per model, choosing another
backend on a chat that has spoken forks, the tab strip marks a workspace that holds both, the
turn footer counts a Codex patch by its kind, and a refusal carries its reason as a steer.

**A Codex chat runs end to end.** What is left is listed under §11.

---

## 3. The decision that shapes everything: per chat, not per workspace

**The backend belongs to the chat, not to the workspace.** One workspace, one worktree, one branch
can hold several chats, and each chat can be on a different backend.

Consequences, worth stating rather than discovering:

- Two chats in one workspace, one Claude and one Codex, run in the **same worktree at the same
  time**, and both can edit the same files. That is already true of two Claude chats, so it is not
  new, but nothing in the app currently says so.
- `Session` is the row that needs the agent-kind column. `Workspace` does not get one.
- The create-workspace sheet chooses a backend for the **first chat only**.
- Anything keyed on "the workspace's agent" is wrong by construction. See §8.

---

## 4. The `Session` column and its migration

**Done.** What landed, for the record:

```swift
public struct Session {
    …
    /// Which CLI drives this chat. Per chat, not per workspace: one worktree can hold a Claude
    /// conversation and a Codex one at the same time.
    public var agentKind: AgentKind = .claudeCode
}
```

The migration step is the real-code form, not `sql(_:)`, because `ADD COLUMN` has no
`IF NOT EXISTS` and every step in that list has to be replayable over a database that already has
it applied. Rewinding `user_version` is how an old schema is reproduced, and a step that threw
would take the whole transaction with it. `theMigrationSurvivesBeingReplayed` pins that:

```swift
{ db in
    let existing = Set(try db.query("PRAGMA table_info(sessions);").compactMap { $0.string("name") })
    if !existing.contains("agent_kind") {
        try db.execute("ALTER TABLE sessions ADD COLUMN agent_kind TEXT NOT NULL DEFAULT 'claudeCode';")
    }
}
```

Every existing row is a Claude Code chat and the default says so. It is threaded through the three
places in `Store.swift` that name session columns: the `INSERT … ON CONFLICT` list, the row reader,
and `updateSessionPreferences`, which gained this column and none of the runner's. That last part
is not decoration: `upsert` writes every column from the value it is handed, which is why `34b840b`,
`e47a3b7` and `de3f173` exist. `upsert` creates a row, `update` modifies one, and a new column
changes nothing about that.

`agent_session_id` needs no change. A Codex thread id is a string like
`01a02144-3b7e-7233-97f2-73ebd5105085` and it is stable across resumes, so it goes in the same
column and means the same thing.

---

## 5. The runner

`AgentRunner` is the Claude Code runner and should stay that. The seam already exists: `AgentRunner`
depends on `AgentProcessing`, not on `StreamingProcess`, and `WorkspaceModel` holds a runner per
session.

Two options, in preference order:

1. **A `CodexRunner` beside it**, with the same public surface `WorkspaceModel` uses (`events`,
   `send`, `cancel`, `isRunning`, the store writes). A protocol, `SessionRunner`, extracted from
   what `WorkspaceModel` actually calls, and a factory that picks by `session.agentKind`. The two
   runners share the store-writing and the usage accounting and nothing else, because they share no
   protocol.
2. Widening `AgentRunner` with a second code path. Cheaper to start, worse in a month: the argv
   builder, the resume flag, the permission-prompt wiring and the event decoder are all
   Claude-specific and would each grow an `if`.

Take option 1.

**One process per chat.** app-server can carry several threads on one connection, and it is
tempting to share one process per workspace or per app. Do not, at least not first: a shared
connection means one crash takes down every Codex chat, and the per-chat lifetime already matches
what `WorkspaceModel` manages.

Turn shape for a Codex chat:

1. `start()` on the client, which launches and does the handshake.
2. `thread/start` (new chat) or `thread/resume` with the stored `agentSessionID`.
3. Persist the thread id the moment it arrives, exactly as `AgentRunner` does with the Claude
   session id, so a crashed app can come back.
4. `turn/start` per user message, carrying the chat's model, effort and approval policy.
5. Draw `item/started` as a row, update it from the deltas, replace it from `item/completed`.
6. `turn/completed` closes the turn. Status `interrupted` is a stop, not a failure.

### The process's life, and the two ways it ends

`turn/interrupt` ends a turn. **Nothing on this protocol ends the process**, so Bloom has to, and
the two acts are deliberately not the same one:

- **Stop interrupts and the server stays.** That is what lets the next message resume in the same
  process, along with the `acceptForSession` grants that live inside it and nowhere else (§7).
- **Close, archive and quit kill it.** `SessionRunner.terminateNow`, which is SIGTERM to the whole
  process group with SIGKILL three seconds behind, exactly as the Claude Code side does it.

Claude Code reaches the same contract from the other end, because killing is the only way to stop
a turn there and the next turn spawns a new process with `--resume`. Measured here while the kill
was missing: at the moment Bloom's quit path reported the agent gone, `codex` (a node script) and
the app-server binary it forks were both still running, and both were still running five seconds
later. The poll behind that report asked whether a turn was open, which the interrupt had just
made false, and nothing had signalled anything.

---

## 6. Storing and drawing Codex items

### Storage: rows go in the vocabulary their reader speaks

**A Codex chat writes Claude Code's stream-json shape into `messages.payload`.** That sounds like a
compromise and is the opposite of one. A stored row is read back by `AgentEvent.decode(line:)`,
which knows one vocabulary, so a row written as a JSON-RPC notification draws perfectly while it is
live and comes back after a restart as a column of unknown rows. Live drawing hides the failure
completely, which is why `everyStoredRowDecodesBackIntoTheSameEvent` exists.

The Codex item travels inside the tool input under `CodexTranslation.itemKey`, so nothing is lost
and a presenter reading a row out of the database still knows which vocabulary it is in without a
join and without a column that did not exist when the row was written.

`messages.payload` is already an opaque blob and `MessageKind` is already coarse. Codex items map
onto the existing kinds without a schema change:

| Codex item | `MessageKind` |
| --- | --- |
| `userMessage` | `user` |
| `agentMessage` | `assistantText` |
| `reasoning` | `thinking` |
| `commandExecution`, `fileChange`, `mcpToolCall`, `webSearch`, `dynamicToolCall` | `toolUse` |
| a refused one | the same row, redrawn; there is no separate result row |
| an approval question | `permissionAsk` |
| `turn/completed` | `result` |
| `plan`, `subAgentActivity`, `contextCompaction`, the rest | `system` |

**The one real difference: there is no `tool_use`/`tool_result` pair.** A Codex item is created by
`item/started` and *updated in place* by `item/completed` under the same id. A transcript that
appends both would draw every command twice. Either upsert by `refID` (the item id), or store only
the completed item and draw the started one from live state. Upserting is closer to what the
protocol means and survives an app restart mid-turn.

### Presenters

`Sources/BloomCore/Agent/ToolPresenter.swift` is 563 lines of Claude Code tool names
(`Read`, `Write`, `MultiEdit`, `Bash`, `Glob`, `Grep`, `Task`, `TodoWrite`, `WebFetch`, …) and it
is the largest single cost in this work. It sat under `Views/` when this was written and is in the
core now, which is the reason the split below could be tested at all. **Do not add Codex cases to
it.** Codex has no tool names at all; it has ten item types. The two vocabularies have nothing in
common but the glyphs.

Split it:

- `ToolPresentation` (the value) stays shared. Nothing in it is Claude-specific.
- `ToolPresenter` keeps its name and becomes explicitly Claude Code's, with one line at the top
  saying so.
- A new `CodexItemPresenter` switches on `CodexItem` and returns the same `ToolPresentation`.
  Roughly: `commandExecution` reads like `Bash`, `fileChange` like `Edit` or `Write` per change
  kind, `mcpToolCall` like the existing `mcp__` branch, `webSearch` like `WebSearch`, `reasoning`
  is a thinking row, `plan` is a plan row.
- The transcript row picks a presenter by reading the row's payload, **not** by the session's
  `agentKind`: a row knows what it is, and a transcript drawn from the database has the row before
  it has the session.

Done, in `Views/Transcript/CodexItemPresenter.swift`, which also holds the `TranscriptPresenter`
router that picks a presenter by reading the row's payload. Every call site goes through the
router; the two `ToolPresenter.present` calls left inside `CodexItemPresenter` are its fallback to
the Claude Code vocabulary and belong there. The rows that draw it are mostly reusable:
`ToolRowView`, `ExpandableRow`, `DetailCodeBlock` and `ToolResultView` do not care where the text
came from. `fileChange` is the nicest case, because its `changes[].diff` is already a unified diff
and Bloom's `DiffParser` reads that shape.

---

## 7. Permissions

**None of Claude Code's rule grammar exists on this protocol.** No `permission-rule`, no allow list
to append to, no `--permission-prompt-tool`. What Codex has is a policy crossed with a sandbox
crossed with a reviewer, and five request shapes.

### Policy, per turn

`approvalPolicy` is `untrusted` | `on-request` | `never` | `{granular: {…}}`, crossed with
`sandbox` (`read-only` | `workspace-write` | `danger-full-access`), crossed with
`approvalsReviewer` (`user` | `auto_review` | `guardian_subagent`). **`plan` has no equivalent at
all**, and the other four `PermissionMode` cases are exactly Codex's own four presets:

| Bloom mode | Codex preset | `approvalPolicy` | `sandbox` | `approvalsReviewer` |
| --- | --- | --- | --- | --- |
| `auto`, "Read only" | `read-only` | `on-request` | `read-only` | `user` |
| `acceptEdits`, "Ask for approval" | `workspace` | `on-request` | `workspace-write` | `user` |
| `autoReview`, "Approve for me" | `auto` | `on-request` | `workspace-write` | `auto_review` |
| `bypassPermissions`, "Full access" | `full-access` | `never` | `danger-full-access` | `user` |
| `plan` | **not offered**, falls to `auto` | | | |

**Shipped, and measured.** Read only means "do not write without telling me", and read-only is the
sandbox that means it: reads and commands run untouched, writes arrive as questions. The measured
run is above, and the number that matters is zero questions for two shell commands. `untrusted`
was the stricter alternative and was rejected on that same evidence: it asks about reads too, which
would make the strictest mode one nobody leaves on rather than one somebody works in.

Ask for approval differs by exactly one thing: the sandbox lets the worktree be written, so an edit
inside it is not a question. `workspaceWrite` names the worktree as its only writable root, so a
Codex chat can write where its own workspace is and nowhere else.

Approve for me differs from Ask for approval by exactly one field, and it is not the policy or the
sandbox: it is who answers. `approvalsReviewer: auto_review` hands each question to a subagent of
Codex's own, which gathers context and applies a risk framework before approving or denying it.
`codex --approve-for-me` says the same in its own help, "Route approval requests through automatic
review using the workspace-write sandbox".

**Bloom shipped without that row, and a user said so**, having read the Codex app's picker beside
Bloom's: three rows in Claude Code's vocabulary, and the one he wanted, the one the Codex app calls
"Approve for me", nowhere. `acceptEdits` was already sending the pair that app calls "Ask for
approval", so the middle mode was genuinely absent rather than merely renamed. Measured against
0.149.1 while adding it: both `thread/start` and `turn/start` parse `approvalsReviewer`, and a
value neither knows comes back as ``unknown variant `bogus_value`, expected one of `user`,
`auto_review`, `guardian_subagent` ``. The third is the older spelling of the second and Bloom does
not offer it.

**The reviewer is named on every turn, not only on the turn that wants it.** The field is sticky,
"this turn and subsequent turns", so a chat that ran one turn as Approve for me and was then moved
back would keep the reviewer while the chip in the composer said otherwise.

**What Bloom does not yet draw.** With `auto_review` the server also emits
`item/autoApprovalReview/started` and `.../completed`, and offers
`thread/approveGuardianDeniedAction` so a person can overrule a denial the subagent made. Bloom
ignores both, so an action the reviewer denies is denied without a row saying so. They are marked
`[UNSTABLE]` in the app-server schema, "This shape is expected to change soon", which is why the
mode ships without them rather than waiting for them.

`plan` is **absent from the picker for a Codex chat, and silently so**. It used to be named in the
picker's footnote as a mode Codex does not have, on the argument that somebody who knows Bloom has
a Plan mode would otherwise hunt for it. The owner's verdict was the other way: do the right thing
rather than explain what you are not offering. A chat carrying Plan that moves onto Codex falls to
`auto`, Codex's Read only, which is the preset that keeps Plan's promise that nothing changes
until you say so; it used to fall to `acceptEdits`, which can write the worktree without asking,
and that was a silent widening of what the agent may do. The falling is an invariant of
`ComposerControls` rather than an arrangement made at each of the four places a backend changes,
and moving back to Claude Code offers Plan again without choosing it. See
`PermissionMode.nearest(on:)`.

### The words over the rows

**Each backend's modes are labelled in that backend's own vocabulary**, which is `PermissionVocabulary`
in the core. The same user's report is the reason: Bloom was printing "Ask, Accept edits, Full
access" over a Codex chat, and somebody who has read one product's documentation could not find the
row he wanted. The labels and the one-line sentences above them are the vendors' own, from the
`codex` binary at 0.149.1 and from `claude` at 2.1.246. Every row prints its own sentence under its
own name: they were one footnote describing the selected row, because an `NSMenu` row is one line
with no room under it, which meant the one thing a permission picker has to answer was only
answered after the choice. The picker is a popover of two line rows now. See `ComposerOptionList`.

Claude Code's side of that was wrong too, and in the same direction. Its `--permission-mode auto`
is documented in the CLI as "Use a model classifier to approve/deny permission prompts", which is
the mode Codex calls Approve for me; Bloom had been labelling it "Ask". It reads "Auto" now, which
is what Claude Code calls it, and it is why Approve for me is offered for Codex only: a second row
for Claude Code would be two names for one `--permission-mode auto`.

### The five questions

`item/commandExecution/requestApproval`, `item/fileChange/requestApproval`,
`item/permissions/requestApproval`, `mcpServer/elicitation/request`, `item/tool/requestUserInput`.
Each has its own response schema; `CodexApprovalDecision.result(for:)` already spells all five.

The Claude Code side landed while this was being written, and the Codex mapping follows its shape
deliberately, so the two feel like one app: the question becomes a transcript row where the call
would have been, it is stored in `permission_asks` so a reopened workspace can still draw it, rules
live in Bloom's own `permission_grants` keyed by repository and matched on **exact equality**, a
matching grant is answered by Bloom itself with a note in the transcript saying so, and **no
settings file is written by anybody**.

Three things that differ, and cannot be papered over:

- **The question carries no detail, only an item id.** A `fileChange` approval has `itemId`,
  `threadId`, `turnId` and an optional reason. The diff is on the `item/started` that arrived a
  moment earlier. The prompt has to join the two by item id.
- **`acceptForSession` is Codex's "do not ask again", and the server remembers it, not Bloom.**
  So the `permission_grants` table, which exists because a worktree can be deleted, has nothing to
  store for Codex. A Codex chat's grants live for the life of the app-server process. Say that in
  the UI rather than showing a "remembered" list that is empty.
- **A refusal carries no sentence on the approval wire**, so the reason goes out as a `turn/steer`
  immediately behind the `decline`. Measured both ways: a bare decline was followed by the same
  patch again, twice; a decline plus a steered reason produced the different thing that was asked
  for. `CodexRunner.deliverReason` is that, and a steer that misses because the turn moved on is
  deliberately silent, since the refusal has already landed.
- **Codex offers no rule of its own.** Claude Code's CLI sends `permission_suggestions`, its own
  judgement about which rule would let calls like this through. Codex sends nothing, so Bloom
  offers the narrowest rule there is: the command verbatim, or the path verbatim. It cannot grant
  more than the thing on screen, and it will often not match again. Inventing a pattern would be
  Bloom granting something nobody agreed to.
- `item/permissions/requestApproval` answers with a granted permission profile rather than a word,
  so approving one properly is real work. Refusing is already expressible.

The mapping that shipped:

| Bloom | On the wire |
| --- | --- |
| Allow once | `accept` |
| Allow for this session | `acceptForSession` |
| Always allow (project) | `acceptForSession`, plus a row in Bloom's own `permission_grants` |
| Deny | `decline`, and the turn carries on. The reason follows as a `turn/steer` |
| Deny and stop | `cancel`. No steer: there is no turn left to put words into |

`thread/status/changed` carries an `active` state with `activeFlags: ["waitingOnApproval"]`, which
is the signal a sidebar needs to tell "working" from "waiting for you". Claude Code has no such
flag and Bloom infers it; here it is handed over.

---

## 8. Every place that assumes Claude today

| Place | What it assumes | What to do |
| --- | --- | --- |
| `AgentKind.canRunWorkspaces` (`Model/Models.swift`) | Was `self == .claudeCode` | **Done.** It admits `.codex` too, and it was the last switch thrown, which is what made everything above reachable |
| `SlashCommandIndex` | Documents in its own header that it is Claude Code's list and that a second backend gets its own index | Codex has `skills/list` as a real RPC, so its index is a call rather than a directory walk. A `CodexSkillIndex` beside it, chosen per chat |
| `WorkspaceNamer` | Shells out to `claude` with Claude-only flags (`--json-schema`, `--tools ""`, `--safe-mode`) and gates on `Shell.which("claude")` | Leave it on Claude Code, and say so. A workspace name is not a chat, so it does not follow the chat's backend. It should fall back to the mechanical name when `claude` is absent, which it already does. Revisit only if a Codex-only machine turns out to be common |
| `InstallPing.agentName(installed:)` (`System/InstallPing.swift`) | `AgentKind.allCases.first(where: \.canRunWorkspaces)`, i.e. exactly one runnable agent | Becomes a set. The wire name should report what is installed **and** runnable, not the first one. It reports no credential and must keep reporting none |
| `ContextWindowUsage` (`Views/Center/Composer/ContextWindowUsage.swift`) | Reads the limit off `result.modelUsage.<model>.contextWindow` and the used figure off the last `assistant` event's usage | Codex hands both over directly on `thread/tokenUsage/updated`: `modelContextWindow` and the `total` breakdown. Simpler, not harder. Give it a second reader and keep the doc comment explaining why Claude needs two lines and Codex needs one |
| `AgentsSettingsView` (`Views/Chrome/Settings/`) | Shows a "cannot run workspaces" note for anything that cannot run one | Follows `canRunWorkspaces` already, so it corrects itself. Its account table for Codex is already written and verified |
| `ComposerOption.models` / `.efforts` | Three Claude models and five flat efforts, hardcoded | See §9 |
| `AgentRunner`, `AgentEvent` | Claude Code's stream-json, end to end | Stay Claude Code's. A `CodexRunner` beside them |
| Sidebar status glyph, `WorkspaceRunningGlyph` | Workspace-level busy state | A workspace is busy when **any** of its chats is. Already per workspace, so no change, but check it is aggregating chats and not reading one |
| `CenterTab` / the tab strip | Chat tabs deliberately carry no glyph, so a row of conversations does not read as a toolbar | A backend mark on a chat tab is needed and must not undo that. A small tinted dot or a wordmark-sized glyph, only where the workspace holds more than one backend, and reconciled with the running glyph that is already there |

---

## 8a. The tab strip has to say which backend a chat is

Today a chat tab carries no glyph at all, deliberately: a strip of conversations must not read as a
toolbar of icons. But with two backends, **you would have to open a chat to find out what is
running it**, and the answer changes what the composer offers, what the permission prompt says and
what the numbers in the inspector mean.

So the mark is needed, and it has to cost almost nothing:

- Only when the workspace actually holds more than one backend. A workspace of five Claude chats
  gets no marks, because there is nothing to tell apart.
- A small tinted dot or a wordmark-sized glyph, not a full icon, and reconciled with the running
  glyph already in that row rather than placed beside it.
- The same mark wherever a chat is named outside its own window: the sidebar row, the window title,
  the menu bar summary.

---

## 9. The model picker

Today: `ComposerOption.models` is three hardcoded Claude ids and `ComposerOption.efforts` is five
hardcoded levels, shown by `ComposerFooterView` and again by `ModelSettingsView`.

What it becomes:

- **Sections named by backend.** "Claude Code" then "Codex", each with its own models.
- **Only backends that can run** get a section. Cursor and OpenCode are detected and configurable
  and cannot drive a chat, so they are not in this menu at all.
- **Models fetched, not hardcoded**, for Codex, from `CodexModelCatalog`. Claude's three stay a
  list for now; the CLI has no equivalent of `model/list`.
- **The effort picker follows the model, within the chat.** Codex efforts differ per model, so
  choosing `gpt-5.5` after `gpt-5.6-sol` has to drop `max` and `ultra` from the effort list, and an
  effort the new model does not take falls back to that model's own default rather than to
  Bloom's `high`. `CodexModel.resolvedEffort(preferring:)` already does the fallback.
- **`ComposerOption.adding(_:to:)` stays.** The open-set behaviour it exists for is still right: a
  settings file can pin an id nothing else knows, and it must remain selectable.
- The picker keeps working with an empty catalog. `CodexModelCatalog.lastKnown` returns the last
  fetch without fetching, so a menu opened while offline shows a stale list rather than nothing.

### Switching backend on a chat that has already spoken

Borrowed from Conductor, and it is the right behaviour: **choosing a different backend on a chat
that already has a message opens a new chat in the same workspace**, seeded with the same model
defaults, rather than changing the one that is running.

The reason is not policy, it is the transcript. A chat's rows are that backend's items, its thread
id is that backend's thread, and its context is on that backend's server. Switching in place would
leave a transcript half in one vocabulary and half in the other, and a resume that resumes nothing.

A chat with **no** messages yet simply changes backend, because there is nothing to strand.

Same workspace, same worktree, same branch: a fork is cheap, and it is much less surprising than
what the earlier framing implied (a new workspace).

## 9a. The context window, which is the one setting that is not a turn argument

Codex sizes its window from its own model catalogue, and the catalogue's figure is well under what
the model will take. The way past it is two `-c` overrides, which is what a Codex user types by
hand:

    codex -c model_context_window=1000000 -c model_auto_compact_token_limit=900000

Both keys, never one. `model_context_window` alone leaves auto-compaction firing at the old limit,
so the chat compacts at a fraction of a window it has just been told is much larger.
`model_auto_compact_token_limit` alone pushes compaction past the window and the turn fails on the
model's own limit. `CodexContextWindow` holds the pair and the 90% fraction between them, and it is
what the picker, the Settings screen and `CodexClient.launch` all read.

**It cannot travel with the turn, and everything else in the composer can.** Model, effort,
approval policy and sandbox are arguments of `turn/start`, which is why changing a chip mid chat
takes effect on the next message with nothing restarted. These two are read when `codex app-server`
starts. So `CodexRunner.applyContextWindowChange` re-reads the chat's setting before every turn and,
if the live server was launched with something else, kills it and connects again; the thread id on
the session row makes the next `openThread` a `thread/resume`, so the conversation survives. What
does not survive is anything that lived only inside the process, which is the grants somebody gave
with "allow for this session", and that is why the reconnect happens on a change rather than on
every turn.

It is per chat and it has no column: `session.<id>.codexContextWindow` in the settings table,
beside fast mode and the output style, for the reason those two are there. `defaults.codex.contextWindow`
is the app-wide default a new chat inherits, and the repository's settings file has no say, because
it has no key for one.

`model/list` does not report a window, so the sizes offered are a list rather than something read
off the catalogue: the model's own, 500K and 1M.

---

## 10. Usage and cost

Codex reports tokens and nothing else. There is no price on this protocol, so `Session.costUSD`
stays zero for a Codex chat, forever.

- `CodexTokenUsage.agentUsage` maps the breakdown onto `AgentUsage`. `cachedInputTokens` is a
  **subset** of `inputTokens` here, not a sibling, so it is deliberately not added again:
  `AgentUsage.contextUsedTokens` sums its three input fields, and counting the cache twice would
  report a window twice as full as it is.
- Anywhere the UI says "$0.00" it should say the token count instead for a Codex chat, not a zero
  price. A zero that means "we do not know" reads as "this was free".
- `account/rateLimits/updated` arrives unprompted after every turn, in `primary` and `secondary`
  slots, and it is genuinely better information than Claude Code's in two ways: the used percentage
  is always there rather than only near the wall, and the window comes as a **length in minutes**
  rather than as a name, so nothing has to be inferred. It is worse in one: the slots are called
  `primary` and `secondary` and nothing more, so the label has to come from the duration. The
  account measured had `secondary` null and `primary` at 10080 minutes, which is a week. There is
  no monthly window here either. `credits`, `planType` and `spendControlReached` are read and
  deliberately dropped: a balance is not a window, it has no reset time, and a panel about how close
  you are to a wall is the wrong place for a wallet. `CodexQuotaAdapter` is the reader, and both
  backends land in the same `agent_quotas` table.

---

## 11. Order of work

Each step should land on its own and leave the app working.

1. **Done.** `Session.agentKind` plus the migration, defaulting to `claudeCode`.
2. **Done.** The `SessionRunner` seam, adopted by both runners. `AgentRunner` conforms through an
   extension in `SessionRunner.swift`, so its own file was never edited.
3. **Done.** `CodexRunner`, driving `CodexClient`, writing the same store rows.
4. **Done.** `CodexItemPresenter`, `TranscriptPresenter`, and the one call site in `ToolRowView`.
5. **Done.** Permission mapping, the asks, the grant matching, and the steered reason.
6. **Done.** The model picker: backend sections, fetched Codex models, per-model efforts, the
   fork-on-switch rule, and Plan absent with a line saying why.
7. **Done for the numbers.** Tokens and the context window land where the existing readers look.
   What is left is wording: a Codex chat has no price, and anywhere the UI would print "$0.00" it
   should print the token count instead. A zero that means "we do not know" reads as "free".
8. **Done.** `TranscriptModel.makeRunner` picks by `session.agentKind`, `canRunWorkspaces` admits
   two, the create sheet carries a backend into the first chat, and the tab strip marks a workspace
   whose chats are not all on one backend.

### What is actually left

- **The expanded file-change row.** The collapsed row is right. Opening one hands `DiffParser` a
  bare hunk (or, for a new file, raw content), and it expects a whole unified patch with headers.
  A small shim that synthesises the `--- a/x` and `+++ b/x` lines from the path, and that draws an
  `add` as content rather than as a diff, is the fix.
- **Cost wording**, as in step 7.
- **`SlashCommandIndex`'s Codex sibling**, from the `skills/list` RPC. Codex's slash vocabulary is
  a call rather than a directory walk, so it is a different index, not a flag on that one.

`WorkspaceNamer` is not on this list, and was for a while. Staying on Claude Code is a decision
rather than an item, and §8's table is where it is recorded with the other things left out on
purpose.

---

## 12. Rules for anyone running Codex while working on this

- Run with `CODEX_HOME` pointed at a scratch directory of your own, never the user's.
- Never read, print or log `~/.codex/auth.json`, and never write into `~/.codex/`.
- Turns cost the owner's plan. Keep them few and short. The whole verification behind this document
  is seven turns of a handful of words each.
- `model/list` and the schema dump need no account and cost nothing. Prefer them.
