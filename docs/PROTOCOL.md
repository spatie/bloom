# The Claude Code stream-json protocol

Ground truth, captured from `claude` on this machine on 2026-08-18. A real capture lives at
`Tests/fixtures/session-basic.jsonl` (55 lines: thinking, two tool calls, two tool results, text,
result). Hook payloads in that file were trimmed because they were enormous, nothing else was
touched.

## How Bloom invokes it

```
claude
  -p
  --output-format stream-json
  --input-format stream-json
  --include-partial-messages
  --verbose
  --permission-mode <auto|acceptEdits|bypassPermissions|plan>
  --permission-prompt-tool stdio
  --model <opus|sonnet|haiku|...>
  [--effort <level>]                 only when the session has one
  [--thinking disabled]              fast mode, and only when it is on
  [--settings '{"outputStyle":"…"}'] only when a style was chosen
  [--mcp-config <path>]              the workspace bridge, a file and never inline JSON
  [--resume <agent session id>]
```

`--verbose` is required with `-p --output-format stream-json`, otherwise the CLI refuses to run.

`--permission-prompt-tool stdio` is undocumented, absent from `--help`, present in the binary, and
always on. Without it the CLI answers permission questions on the user's behalf and the answer is
no, which was every `permission-rule` refusal in every transcript. It does not make the CLI ask
more: the classifier still approves what it approved before, measured at zero questions over seven
tool calls in one ordinary turn. The paragraph above `AgentRunner.argv` is where that measurement
lives, along with why `--settings` takes one object rather than accumulating and why the bridge is
handed over as a file (argv is visible in `ps`, and an agent runs `ps`).

Working directory is the worktree. Input is NDJSON on stdin, output NDJSON on stdout. stdin stays
open for the whole session so follow-up turns are just more lines.

### Sending a turn

One JSON object, one line:

```json
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"do the thing"}]}}
```

### Sending into a turn that is already running

Measured on `claude 2.1.260` on 4 September 2026, driving the invocation above with a cheap model.
A second user line was written to stdin four seconds into a running turn. It was **accepted**: no
error, nothing lost, and the CLI did not close the pipe.

What it did with it depends on what the turn had left to do. The probe's turn was prose with no
tool call after the injection, and the CLI finished it, emitted its `result`, then emitted a
**second `init`** and ran the injected line as a turn of its own. The other landing is in the CLI's
own copy: a message whose origin is the person is framed as "The user sent a new message while you
were working", with a paragraph under it saying that is how Claude Code surfaces a mid-turn
message, within the running turn and often alongside the next tool result rather than as a separate
turn. So a turn with a tool boundary left in it takes the message inside the turn, and a turn
without one runs it next.

Both are landings Bloom already handles. `AgentRunner.ingest` applies `turnStarted` on an `init`,
which is the fix written for the CLI's habit of starting turns of its own (see `StrayResult`), so a
second `init` puts the chat back to running rather than leaving it drawn as idle through a turn.

`AgentKind.acceptsMidTurnMessage` is where this is written down as a fact the app reads, and
`DeliveryHold.allowsDelivery(on:)` is what it decides.

## Output events

Every line has `type`. Every line except a few carries `uuid` and `session_id`.

### `system` / `init`

First line of the session. Carries the fields Bloom needs to bind a session:

```json
{"type":"system","subtype":"init","session_id":"f93932c9-...","cwd":"/path",
 "model":"claude-sonnet-5","permissionMode":"bypassPermissions",
 "tools":["Bash","Read",...],"slash_commands":[...],"agents":[...],
 "output_style":"default","uuid":"..."}
```

`session_id` is what `--resume` takes later. Persist it the moment this arrives.

### `assistant`

**The important one.** Emitted once per content block, already split, with the block complete.
A transcript can be built from these alone: the `stream_event` deltas below are only needed to
show text arriving live.

```json
{"type":"assistant","uuid":"...","parent_tool_use_id":null,"session_id":"...",
 "message":{"id":"msg_011...","role":"assistant","model":"claude-sonnet-5",
   "stop_reason":null,
   "usage":{"input_tokens":2,"cache_creation_input_tokens":13435,
            "cache_read_input_tokens":24424,"output_tokens":2,
            "cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":13435},
            "service_tier":"standard"},
   "content":[ <exactly one block> ]}}
```

`content[0]` is one of:

| block | fields |
|---|---|
| `text` | `text` |
| `thinking` | `thinking`, `signature` |
| `tool_use` | `id` (`toolu_...`), `name`, `input` (arbitrary JSON object) |

`parent_tool_use_id` is non-null when the event comes from inside a subagent (the Agent tool).
Nest or indent those rows rather than mixing them into the main flow.

Several consecutive `assistant` events can share one `message.id`. That is one assistant turn
split across blocks, not several turns.

### `user`

A tool result being fed back. Not something a human typed.

```json
{"type":"user","uuid":"...","parent_tool_use_id":null,"session_id":"...",
 "message":{"role":"user","content":[
   {"type":"tool_result","tool_use_id":"toolu_01PpK...","content":"1\thello\n2\t",
    "is_error":null}]},
 "toolUseResult":null}
```

`content` is either a string or an array of blocks (`{"type":"text","text":...}`, and image
blocks for screenshots). `is_error` is `true` when the tool failed. Match `tool_use_id` back to
the `tool_use` block to render the pair as one row.

### `stream_event`

Raw passthrough of the Anthropic streaming API, only present with `--include-partial-messages`.
Use for live typing, then reconcile against the `assistant` event that follows.

```json
{"type":"stream_event","event":{...},"session_id":"...","uuid":"...","parent_tool_use_id":null}
```

`event.type` is one of `message_start`, `content_block_start`, `content_block_delta`,
`content_block_stop`, `message_delta`, `message_stop`.

`content_block_start` carries `index` and `content_block` (`{"type":"text"|"thinking"|"tool_use",...}`).
`content_block_delta` carries `index` and `delta`, whose `type` is:

- `text_delta` with `text`
- `thinking_delta` with `thinking`
- `input_json_delta` with `partial_json` (accumulate the string, it parses only once complete)
- `signature_delta` with `signature`

### `system` (other subtypes)

- `status` with `status: "requesting"` and similar. Drives a "thinking" indicator.
- `thinking_tokens` with `estimated_tokens` and `estimated_tokens_delta`. Live thinking counter.
- `hook_started` / `hook_response` with `hook_name`, `hook_event`, `output`, `stdout`, `stderr`,
  `exit_code`, `outcome`. Payloads can be hundreds of kilobytes. Never render them raw.
- Unknown subtypes will appear over time. Ignore them without failing.

### `result`

Last line of a turn.

```json
{"type":"result","subtype":"success","is_error":false,
 "duration_ms":7880,"duration_api_ms":7851,"num_turns":3,
 "stop_reason":"end_turn","session_id":"...","total_cost_usd":0.119,
 "result":"Created out.txt with \"BATON\".",
 "usage":{"input_tokens":6,"output_tokens":360,
          "cache_read_input_tokens":100420,"cache_creation_input_tokens":13928,
          "output_tokens_details":{"thinking_tokens":150}},
 "modelUsage":{"claude-sonnet-5":{"contextWindow":1000000,"costUSD":0.119,...}},
 "permission_denials":[],"terminal_reason":"completed","uuid":"..."}
```

`subtype` is `success`, or `error_max_turns` / `error_during_execution` on failure.
`modelUsage.<model>.contextWindow` is where the context-window size comes from, so a
"how full is the context" gauge can be drawn.

**It is the last line of a turn, and not always of the turn you sent.** The CLI starts turns of
its own, and when it does the result carries an `origin` object naming why:

```json
{"type":"result","subtype":"success","is_error":false,"duration_ms":60,
 "duration_api_ms":0,"num_turns":0,"result":"","origin":{"kind":"task-notification"},...}
```

Measured on 25 August 2026, twice, in two workspaces. Both times a `--resume` brought back a
session that had a background task notification waiting for it, and the CLI ran that as a turn
before it read anything from stdin: `init`, this line, then a second `init` for the turn the user
had actually sent. A result answering a prompt names no origin at all. See `StrayResult`, which is
the bug that cost.

### `rate_limit_event`

One per turn, and it carries **one window**, never a set:

```json
{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1787508600,
 "rateLimitType":"five_hour","overageStatus":"rejected",
 "overageDisabledReason":"org_level_disabled","isUsingOverage":false},"uuid":"...","session_id":"..."}
```

Measured on 23 August 2026 against the installed binary, and recorded with a second payload from a
busier account in `Tests/fixtures/rate-limits.jsonl`. Three facts, all of which shaped `AgentQuota`:

1. `rateLimitType` names a single window. `five_hour` and `seven_day` are the values observed, there
   is no array, and there is no way to ask for the rest, so what Bloom knows about an account
   accumulates over turns.
2. **`utilization` is absent below a warning threshold.** The payload above has no usage figure at
   all. The one that does carries `"status":"allowed_warning"` and `"surpassedThreshold":0.75`
   beside it, so the number arrives only once the account is near the wall. Store that as unknown,
   never as zero: an empty bar is a claim, and it is a claim this protocol never made.
3. **There is no monthly window.** Bloom shows the two it is given and says nothing about a third.

Surface it quietly, never as an error. `AgentQuotaAdapters` is the reader.

### `control_request` / `control_response`

Not an event, a question. With `--permission-prompt-tool stdio` the CLI asks before running a tool
it is not allowed to run outright, and holds the turn open until an answer arrives on stdin.

```json
{"type":"control_request","request_id":"…",
 "request":{"subtype":"can_use_tool","tool_name":"Bash","input":{…},
            "permission_suggestions":[…]}}
```

Only `can_use_tool` is lifted out. The other control subtypes are the CLI answering Bloom, or
asking something Bloom has no business answering, and they stay raw rather than half understood.
`request` also carries `display_name`, `tool_use_id`, `description`, `decision_reason`,
`decision_reason_type`, `blocked_path`, `suppress_always_allow_rule`, `requires_user_interaction`
and `classifier_approvable`, all optional. **`decision_reason` may carry ANSI escapes**, which the
CLI's own schema says in as many words, so it is stripped before anything renders it.

The answer is one line back:

```json
{"type":"control_response","response":{"request_id":"…","subtype":"success",
 "response":{"behavior":"allow"|"deny",…}}}
```

An allow carries `updatedInput`, which is the input that was asked about and unedited unless the
tool asked a question the user typed an answer to. A wider scope than once carries
`updatedPermissions`, which is the CLI's own suggestion aimed at the session. A deny carries
`message` and `interrupt`. The `request_id` has to match the pending ask or the answer does
nothing: the CLI refuses a response whose tool disagrees with the question and logs the mismatch.
`PermissionAsk` reads these and `PermissionAnswer` writes them.

This wire used to fall through to `unknown` and be dropped on the floor, which is exactly what
"Bloom never asks" looked like from the inside: the CLI was willing to ask and nobody was reading
the line. A decoder that took the event list above as complete would hang the turn the same way.

## Rules for the decoder

1. **Never fail the stream on an unknown event.** New `type` and `subtype` values ship
   regularly. Decode what is recognised, keep the raw JSON for everything else, carry on.
2. **Keep the raw line.** Bloom stores the original JSON for every row so a renderer added later
   can show detail that was not decoded at the time.
3. Lines can be very large (a hook response, a big tool result). No length assumptions.
4. A malformed line is possible if the CLI crashes mid-write. Skip it, do not abort.
