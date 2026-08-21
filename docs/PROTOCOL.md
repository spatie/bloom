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
  --model <opus|sonnet|haiku|...>
  [--resume <agent session id>]
```

`--verbose` is required with `-p --output-format stream-json`, otherwise the CLI refuses to run.
Working directory is the worktree. Input is NDJSON on stdin, output NDJSON on stdout. stdin stays
open for the whole session so follow-up turns are just more lines.

### Sending a turn

One JSON object, one line:

```json
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"do the thing"}]}}
```

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

### `rate_limit_event`

Occasional. Carries rate limit state. Surface it quietly, never as an error.

## Rules for the decoder

1. **Never fail the stream on an unknown event.** New `type` and `subtype` values ship
   regularly. Decode what is recognised, keep the raw JSON for everything else, carry on.
2. **Keep the raw line.** Bloom stores the original JSON for every row so a renderer added later
   can show detail that was not decoded at the time.
3. Lines can be very large (a hook response, a big tool result). No length assumptions.
4. A malformed line is possible if the CLI crashes mid-write. Skip it, do not abort.
