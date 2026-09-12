# Git and agent reliability improvements

Implementation of the recommendations in [the T3 Code investigation](T3CODE-RESEARCH.md).
The investigation remains a record of the original source snapshots; this document describes
the resulting Bloom behaviour and its validation.

## Git operations

- Single-file revert and diff treat filenames literally, including dynamic route names such as
  `[id].tsx`. Reverting one file preserves neighbouring worktree and index changes.
- Patch rendering disables external diff tools and text conversion, fixes the patch prefixes,
  and distinguishes the normal `--no-index` changed-files status from a real command failure.
- Worktree enumeration uses NUL-delimited records, retaining newline-containing paths and lock
  reasons. Watchers include each worktree's real Git directory and shared repository metadata.
- Refreshes acknowledge only the invalidation generation they read. A change arriving during a
  refresh remains due, and a failed refresh remains eligible for retry.
- Repository context distinguishes the base branch/remote from the publication branch/remote,
  including `branch.<name>.pushRemote` and `remote.pushDefault` fork workflows.
  A checked-out pull request ref without an explicit publication remote refuses a direct push
  instead of guessing the contributor's repository. The normal agent-driven push remains available.
- Submodule initialisation runs through workspace setup before the project's setup script.
  Failures retain the workspace and use the existing setup log and retry controls.

## Process and service reliability

Short-lived subprocesses share byte-preserving, bounded output collection. Cancellation and
execution deadlines cover input writes, child execution and inherited output pipes. A bounded
termination grace allows cleanup before returning a typed failure. Structured output exceeding
its budget fails explicitly instead of returning a truncated successful result.

GitHub requests share identical in-flight reads and host-wide rate-limit cooldowns. Cancelling
one consumer does not cancel a shared request. Missing pull requests, malformed responses and
service failures remain distinct. The inspector retains the last successful result with an
explanation when refresh is unavailable.

## Agent interactions

- Delivery records distinguish claiming a prompt from provider acceptance. Interrupted sends
  remain visible and recoverable without automatically replaying uncertain paid work.
- Codex Stop accounts for child turns as well as the parent, with bounded interruption of
  unresponsive children and guards against affecting a replacement turn.
- Presentation subscribers receive bounded updates backed by authoritative live state and
  persisted transcript rows. Protocol ingestion remains lossless.
- Codex has independent Plan/Build and permission controls. Queued prompts preserve the mode
  selected when they were submitted.
- Saved plans retain revisions and provenance. A plan can be refined, implemented in the current
  chat, or handed to a new chat in the same worktree with the selected model and permissions.
- A terminal selection can be added to a draft with its captured text and source. Attaching an
  excerpt does not send it, and later scrolling or terminal closure does not change its contents.
- Settings > Agents offers optional idle process release. It defaults to Never. Active turns,
  pending work, questions and live children prevent release. Restarting Codex can require new
  approval for permissions that belonged to its previous process.

## Historical changes and rewind

Turn snapshots use private Git indexes and hidden refs. They record worktree contents separately
from the user's staging state. Historical diffs therefore include shell edits and net changes
from repeated writes, and remain tied to their original contents after subsequent turns.
Recorded turn footers use these net file counts, and their file chips open the historical patch
instead of previewing the current file.
Changes made by another chat or terminal during the same interval may appear in the snapshot;
the diff describes changes during a turn, not guaranteed authorship.

The most recent 200 completed turns per conversation retain snapshots. Transcript history is
not removed by snapshot retention. Older turns can retain their existing tool-derived summaries.

Conversation rewind requires provider history support and a recorded provider turn identity.
Filesystem restore and provider history are separate operations, so rewind first records a
recovery snapshot and a durable progress journal. An interrupted rewind must be reconciled
before sending more work into the affected workspace. Restoring files refuses unsupported
submodule/sparse-checkout cases and collisions with ignored files.

## Validation

Local validation passed: 336 regression tests in 44 suites, app compilation with warnings treated
as errors, both house rules and SwiftLint, and shell syntax checking. The pull request runs the
full suite and app checks in CI. No installed Bloom application or production database was used;
live provider calls and interactive UI behaviour were not exercised.

The separate standards review found lifecycle boundaries could disappear during presentation
catch-up and checkpoint linkage could race completion. Fixes preserve lifecycle boundaries in a
bounded temporary transport journal, replay them off the main actor without starting queued work
inside an autonomous turn, and associate provider turns atomically through Store. Follow-up
review also removed an unnecessary sequence-keyed cache and made absent checkpoint associations
normal for steering and workspace-free chats.

The separate specification review found setup could race rewind, plans were marked implemented
on queue acceptance, and learned planning incompatibility was not reflected in the controls.
Fixes add a shared workspace operation lease, mark implementation only after provider acceptance,
and disable unavailable planning with explicit rediscovery. Restore preflight now rejects
unsupported file restores before creating a blocking journal. The reviewers verified these
corrections and reported no remaining findings within their targeted follow-up scopes.
