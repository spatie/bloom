# CLI agent integration

Temporary working notes, 14 September 2026. Implementation and local checks are complete; manual UI checks remain below.

## Intended behaviour

Create a workspace with Claude Code or Codex running interactively in a terminal tab. Keep a linked agent session so Bloom can show the provider and activity using its existing tabs and workspace status. Detect agents started manually in existing terminal tabs and split panes where possible.

## Verified CLI support

Checked the Context7 skill, current official documentation and local command help. Installed versions are Claude Code `2.1.268` and Codex `0.154.0`.

- Both accept an initial prompt as one positional argument and remain interactive. Quote every shell argument. Do not use Claude `--print` or Codex `exec`.
- Claude supports `--session-id UUID`, `--resume SESSION_ID` and invocation-local `--settings FILE_OR_JSON` for hooks.
- Codex supports `--no-alt-screen`, `--cd PATH`, `resume SESSION_ID` and invocation-local `-c key=TOML` overrides. Capture its native session ID from a hook; there is no new-session-ID flag.
- Both support `--model MODEL`. Claude has `--effort LEVEL`. Codex uses `-c 'model_reasoning_effort="LEVEL"'`. Use levels supported by the selected model.
- Claude permission modes include `manual`, `acceptEdits`, `auto`, `dontAsk`, `plan` and `bypassPermissions`. Omit the flag for its normal default. Codex accepts `--sandbox read-only|workspace-write|danger-full-access` and `--ask-for-approval on-request|never`. Preserve the user's chosen permissions.
- Both have lifecycle hooks. Claude accepts a `hooks` object through `--settings`. Codex accepts overrides such as `hooks.UserPromptSubmit=[{hooks=[{type="command",command="...",timeout=3}]}]`. Codex merges hook sources and requires trust review for non-managed hooks, including CLI overrides. Do not bypass hook trust.
- Bloom already owns the worktree. Do not pass either CLI's worktree creation option.

Sources: [Claude CLI](https://code.claude.com/docs/en/cli-reference), [Claude hooks](https://code.claude.com/docs/en/hooks), [Codex CLI](https://developers.openai.com/codex/cli/reference), [Codex hooks](https://learn.chatgpt.com/docs/hooks), [Codex hook discovery](https://github.com/openai/codex/blob/main/codex-rs/hooks/src/engine/discovery.rs), [Codex effort values](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/openai_models.rs).

## Reuse and implementation

- Reuse terminal `CenterTab` entries with optional linked `SessionID` metadata; the existing session supplies `AgentKind`. Reuse existing agent session presentation and status. No separate terminal-agent tab type or custom view is planned.
- Extend `AgentKind` for interactive command construction and hook settings.
- Reuse terminal startup, pane persistence, `TmuxSessions.parsePanePIDs` and `ProcessTable` for launch and process association.
- Store hook events per linked session, associated with its original terminal pane. Both providers send JSON with `session_id`, `cwd`, `hook_event_name` and `transcript_path` (nullable for Codex). A stable hook command can use a pane-specific environment variable for its destination without changing its trust identity.
- Keep hook writes atomic, silent and successful even when Bloom cannot receive an update. Status integration must not block an agent turn.

Suggested event mapping: `UserPromptSubmit`, `PreToolUse` and `PostToolUse` mean working; `PermissionRequest` means waiting; `Stop` means idle; `SessionEnd` means stopped. `SessionStart` means idle except `source=compact`, which can occur during a running turn. Claude notifications can add permission and idle signals.

## Implementation state

- Added Claude CLI and Codex CLI to workspace creation. They reuse the prompt editor and show the existing agent tab with an embedded terminal.
- CLI launches wait for setup and preserve attachment paths. The CLIs use their own model, effort and permission settings by default.
- Initial prompts use the existing delivery queue. The existing terminal restart strip can offer an interrupted launch; it does not restart agents automatically.
- Supported hooks drive existing session state, sidebar activity, waiting indicators and unread marks. Activity is checked every two seconds using a batched process and tmux query.
- Manually started agents change the terminal tab glyph. Process detection alone does not show a working state.
- Native session IDs feed resume commands offered by the existing restart strip. These do not repeat the opening prompt. Linked terminals allow longer generated commands while ordinary command recall keeps its existing limit.
- Multiline or control-character prompts travel in an encoded shell command. Hook files are private and separated by app bundle ID, so Bloom Dev cannot overwrite the main app's status files.
- Linked sessions do not start managed runners. Follow-up prompts and approvals are entered directly in the CLI terminal.
- Research, workspace UI and terminal detection were handled by parallel agents. Root integrated the changes and reviewed lifecycle and restore handling.

## Limits and validation

- An uninstrumented running CLI can identify the provider, but process presence cannot distinguish working from idle or waiting for approval. Exact activity depends on hooks being enabled and trusted.
- A `Stop` hook may run before another hook requests continuation. Reconcile later events and exited processes instead of trusting a stale status file indefinitely.
- Current Codex web docs describe `Interrupt`, while the indexed source enum differs. Support needs version verification. Transcript files are not a stable status API.
- Multiple panes can share a working directory. Linked status follows the original pane, not another agent in a split. Observed process replacements invalidate stale hook files. Manual process detection uses a conservative shell-job heuristic; some wrappers and ambiguous command lines may not be recognised.
- The CLI owns its transcript. Bloom does not import terminal text as chat messages or forward its chat-only actions into terminal input.
- If setup is interrupted, reopening offers the saved command. Check the existing setup warning before starting it.
- Validation passed: `make build` with no warnings, `make lint`, `make swiftlint`, and 173 targeted tests in 19 suites. The test command was `BLOOM_TEST_ID=bloom-cli-integration ./Tools/test-core.sh InteractiveAgent TerminalCommandMemory WorkspaceStart SessionLifecycle`. `git diff --check` is clean. No live paid agent turn or interactive UI verification has run. Do not launch or activate applications for verification without the permission required by `AGENTS.md`.
- Initial implementation was committed and pushed to `alex/cli-agent-terminals`. No pull request is requested.
- Merged current `main` to retain schema version 27 support after the first dev build could not open the newer dev database. The dev database was backed up and its integrity checked before app replacement. The existing database is kept in place. No database reset or schema downgrade is used. CLI integration remains alongside main's run scripts, terminal activity and workspace history guards.

## Review follow-up

- Codex reviewed the committed CLI integration. Fixed both confirmed findings: hook JSON/TOML stays together during process detection, and setup launches the terminal even when its tab is hidden.
- Added detection regressions using the actual generated Claude and Codex launch and resume arguments, including real headless flags after hook settings.
- Claude's simplify session completed its review suggestions. Removed repeated lifecycle transitions and reused the Claude hook entry. Larger restructuring suggestions remain deferred.
- Claude's separate review reached its account limit before a final report. Its partial findings are not counted as a completed review.
- Final fast dev build compiled without warnings and passed signature verification. Both linters and 175 focused tests across 19 suites passed. The earlier schema checks passed too. No PR is being opened, as requested.

## Manual checks still to run

1. Create one Claude CLI workspace and one Codex CLI workspace with a multiline task and an attachment. Verify setup finishes before the prompt is sent.
2. Allow the CLI status hooks when prompted. Verify working, approval waiting and completion states in the agent tab and sidebar.
3. Start a CLI manually in a normal terminal and in a split pane. Verify the provider glyph without a false working indicator.
4. Relaunch the dev app with tmux enabled, then with a stopped terminal. Verify reattachment or the existing Start offer resumes the native session without repeating the task.
5. Close a linked session during setup. Verify it does not launch later or start another chat's runner.

These are pending checks, not claimed results. The first dev launch hit the schema mismatch above. Reopening the compatible build is pending.
