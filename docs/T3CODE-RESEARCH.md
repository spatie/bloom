**T3 Code investigation: Git operations and AI interactions**

Investigated 12 September 2026 using three research subagents and a separate integration review. Compared [T3 Code at a43f9b4](https://github.com/pingdotgg/t3code/tree/a43f9b45ae85caf37e0be8270ad3d27365ece2bd) with [Bloom at e00870c](https://github.com/spatie/bloom/tree/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01). Recommendations below apply to these snapshots.

There are worthwhile improvements, including a reproduced single-file revert that changes unrelated files, a reproduced shell deadline failure, and a source-established prompt delivery crash window. The best approach is a series of focused fixes and feature additions within Bloom's existing core/view architecture.

**Recommended order**

Priority reflects user impact and confidence, not the amount of machinery T3 uses. Small means a local change with focused regressions, medium crosses a few core/UI boundaries, and large needs a separate lifecycle or storage design. These are relative scopes, not time estimates.

| Order | Improvement | Evidence | Scope |
| --- | --- | --- | --- |
| 1 | Literal filename handling in single-file revert and diff | Reproduced unrelated edits being discarded, including `[id].tsx` matching `i.tsx` and `d.tsx` | Small |
| 2 | Recover prompts claimed before provider send | Source-established crash window; fault injection still needed | Medium |
| 3 | End-to-end subprocess deadlines and output budgets | Actual Bloom Swift probe exceeded 200 ms deadline and returned success after 2 seconds | Medium |
| 4 | Stable machine-readable patch output | External diff setting reproduced an empty successful patch for a changed file | Small |
| 5 | Preserve refresh invalidations; watch actual Git metadata | Source-established race and linked-worktree coverage gap | Medium |
| 6 | NUL-delimited worktree enumeration | Newline path format failure reproduced at command level | Small |
| 7 | Explicit Codex child cancellation on Stop | Missing explicit guarantee; child leakage not measured | Medium |
| 8 | Codex Plan/Build independent of permissions | T3 implements and tests collaboration mode; Bloom deliberately omits it | Medium |
| 9 | Bound presentation event queues and coordinate GitHub cooldowns | Confirmed implementation differences; performance benefit unmeasured | Medium |
| 10 | Terminal selection into a draft | Concrete workflow addition using existing attachment patterns | Small |
| 11 | Historical turn diffs from snapshots | Stronger replacement for tool-derived summaries | Large |
| 12 | Submodule readiness, publication remotes, plan handoff | Valuable extensions depending on repository/workflow needs | Medium |
| Later | Conversation rewind and idle provider eviction | Separate lifecycle risks and product tradeoffs | Large / medium |

For the first implementation batch, prioritise literal paths, delivery recovery, shell deadlines and controlled patch output. For the first feature batch, choose Codex planning and terminal excerpts. Design historical turn diffs before attempting rewind.

**Evidence and limits**

The Git reproductions ran in fresh temporary repositories with global/system Git configuration neutralised. They exercised Bloom's command shapes, not the app UI. The shell probe compiled three unchanged Bloom source files into a temporary executable. Existing test files in both projects were inspected, but neither full suite was run. No provider calls, paid requests, live fault injection, app launches or installations were performed. No application source changed. This report is the only repository addition.

Observed reproductions, source-derived defects and proposed features are distinguished throughout. T3 implementation tests are useful regression specifications, not proof that its whole application is more reliable or faster. No end-to-end performance comparison was made.

---

**Git operations and worktrees**

**Highest priority: literal filenames must not become Git pathspecs**

**P1, command-level reproduced data loss.** Bloom uses `--` to separate paths from options, but this does not turn off Git pathspec globbing or pathspec magic. `FileRevert` uses `git checkout <base> -- <file.path>` and `git rm -f -- <file.path>` at [Sources/Bloom/Views/Inspector/FileRevert.swift:65-76](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/Bloom/Views/Inspector/FileRevert.swift#L65). Its command wrapper at lines 103-105 supplies no global `--literal-pathspecs` or equivalent environment variable. Reverting a tracked file named literally `*.txt` restores all matching tracked `.txt` files, including edits the user did not ask to lose. A filename using `:(exclude)` is another dangerous variant.

A follow-up isolated reproduction used the realistic route filename `[id].tsx` alongside `i.tsx` and `d.tsx`. After all three changed from `before\n` to `after\n`, `git checkout HEAD -- '[id].tsx'` restored all three to `before\n`. The command was again an argv call with no shell expansion and neutralised global/system config. This is not limited to intentionally unusual star filenames. Temp repository: `/var/folders/l4/r8h3dm6911q73cn70zxxp8z80000gn/T/bloom-route-path-repro-le2ewacu`.

Bloom's per-file patch command has the same scope issue at [Sources/BloomCore/Git/Git+Diffs.swift:241-254](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/BloomCore/Git/Git+Diffs.swift#L241). A single selected file can return a multiple-file patch. This increases the risk that the review and the confirmation do not describe the operation accurately.

T3 explicitly uses `--literal-pathspecs` before `add -A -- <selected paths>` in its selected-file preparation ([apps/server/src/vcs/GitVcsDriverCore.ts:1875-1889](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/vcs/GitVcsDriverCore.ts#L1875)) and temporary-index review assembly (`:2352-2362`). Its regression test creates the literal file `:(exclude)after.ts` and verifies that the review includes its content ([GitVcsDriverCore.test.ts:899-915](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/vcs/GitVcsDriverCore.test.ts#L899)). This is a transferable mechanism, not evidence that every T3 Git command handles every hostile path.

Source: [T3 literal selected paths](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/vcs/GitVcsDriverCore.ts#L1875), [T3 regression](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/vcs/GitVcsDriverCore.test.ts#L899).

Recommendation: centralise literal-path command construction and apply it to per-file diff, checkout/restore and rm operations. Move the destructive operation from the app-only FileRevert helper into BloomCore so a real-repository regression can verify that a neighbouring file and index entry remain untouched. Cover `*`, `?`, brackets, `:(exclude)`, tabs, spaces, newlines and renamed paths. Do not claim `--` alone provides this guarantee.

Reproduction details: Python `tempfile.mkdtemp`, fresh `git init -b main`, repository-local dummy user.name/email, `GIT_CONFIG_GLOBAL=/dev/null` and `GIT_CONFIG_NOSYSTEM=1`. No user repository or global configuration was mutated. Both tracked files began with `original\n`, were committed, and both were changed to `edited\n`. Commands were invoked as argv through `subprocess.run`, so no shell expansion occurred.

```text
git diff --no-color -M HEAD -- '*.txt'
=> diff --git a/*.txt b/*.txt
=> diff --git a/victim.txt b/victim.txt

git checkout HEAD -- '*.txt'
=> {'*.txt': 'original\n', 'victim.txt': 'original\n'}

# After editing both again:
git --literal-pathspecs checkout HEAD -- '*.txt'
=> {'*.txt': 'original\n', 'victim.txt': 'edited\n'}
```

Temp repository: `/var/folders/l4/r8h3dm6911q73cn70zxxp8z80000gn/T/bloom-git-repro-a02ec84v`. This reproduced the exact command shape used by Bloom, not a UI click or a compiled FileRevert invocation.

**Make rendered patches independent of personal Git diff settings**

**P2, empty patch reproduced.** T3's review diff commands use `--no-ext-diff`, `--no-textconv`, and explicit `--src-prefix=a/ --dst-prefix=b/` ([GitVcsDriverCore.ts:2271-2296](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/vcs/GitVcsDriverCore.ts#L2271); prefix definition `:56-59`). Bloom's patch command sets `--no-color` only ([Git+Diffs.swift:244-254](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/BloomCore/Git/Git+Diffs.swift#L244)). Configured external diff tools can replace the machine-readable patch entirely. Text conversion can also make displayed lines describe converted content rather than the bytes Bloom edits.

In a fresh isolated repository with the same neutralised global/system config, I set repository-local `diff.external=/usr/bin/true`, changed note.txt from `before\n` to `after\n`, and ran:

```text
git diff --no-color -M HEAD -- note.txt
=> ''
git diff --numstat -M -z HEAD --
=> '1\t1\tnote.txt\0'
git diff --no-color --no-ext-diff --no-textconv HEAD -- note.txt
=> a normal patch containing '+after'
```

Temp repository: `/var/folders/l4/r8h3dm6911q73cn70zxxp8z80000gn/T/bloom-diff-config-repro-por120qo`. This shows a changed-file list reporting an edit while the patch command succeeds with no diff.

Explicit prefixes also remove configuration-dependent paths. Bloom's parser strips only `a/` and `b/` ([Sources/BloomCore/Git/DiffParser.swift:768](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/BloomCore/Git/DiffParser.swift#L768)), and its header splitting relies on ` b/` or falls back to the first space (`:661-698`). T3 tests both `diff.noprefix=true` and `diff.mnemonicPrefix=true` ([GitVcsDriverCore.test.ts:872-897](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/vcs/GitVcsDriverCore.test.ts#L872)). Bloom handles some prefix-less patches through `---`/`+++` lines, so do not claim all such patches fail. Mode-only/binary paths containing spaces and mnemonic prefixes are the cases to cover.

Recommendation: one patch-output policy for tracked and untracked previews: literal path selection where applicable, no colour, no external diff, no text conversion, fixed prefixes, and explicit handling of nonzero exit status. Bloom currently returns stdout from untracked `--no-index` diff without distinguishing expected exit 1 from genuine errors ([Git+Diffs.swift:244-250](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/BloomCore/Git/Git+Diffs.swift#L244)); include that small correctness fix in the same work.

Source: [T3 controlled patch output](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/vcs/GitVcsDriverCore.ts#L2271), [prefix regression](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/vcs/GitVcsDriverCore.test.ts#L872).

**Preserve file-system events that arrive during a Git refresh**

**P2, source-derived race, not runtime reproduced.** In [Sources/Bloom/State/AppModel.swift:856-859](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/Bloom/State/AppModel.swift#L856), file-system events insert workspace ids into `changedWorkspaceIDs`. A refresh awaits a task-group result at line 917 and clears that id at line 925, after asynchronous Git work. An event delivered during that suspension can therefore be cleared by completion of the older refresh. The comment at lines 922-924 says such events remain fresh, but the set carries no generation that could distinguish old from new events.

Concrete interleaving: refresh reads file state A; external terminal writes B; watcher inserts the workspace id; the A refresh finishes; completion removes the id. A non-running background workspace can then wait until the 300-second backstop. The selected workspace has a 30-second backstop. Agent-active workspaces continue at six seconds, reducing the impact there.

T3 uses repository generations for ref snapshots: reads capture a generation, and only return a snapshot if the generation still matches after the async operation ([GitVcsDriverCore.ts:2902-2926](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/vcs/GitVcsDriverCore.ts#L2902)); invalidation advances the generation (`:2928-2945`). This is the relevant pattern, not a suggestion to transplant its whole cache.

Recommendation: remove consumed invalidations before starting the refresh, letting events during the await reinsert them, or maintain per-workspace event generations and acknowledge only the generation sampled by the read. Preserve retry eligibility after a failed read. Add a deterministic delayed-reader test with a second invalidation delivered in the middle, rather than a timing-dependent FSEvents test.

Source: [T3 generation guard](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/vcs/GitVcsDriverCore.ts#L2902).

**Watch the real Git metadata of linked worktrees**

**P2, source-derived freshness gap; Git directory layout confirmed in isolated repo.** Bloom watches `workspaces.map(\.path)` at [Sources/Bloom/State/AppModel.swift:625](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/Bloom/State/AppModel.swift#L625); `WorktreeWatcher` registers those roots ([Sources/BloomCore/System/WorktreeWatcher.swift:88-99](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/BloomCore/System/WorktreeWatcher.swift#L88), `:130-151`) and attributes events only under those roots (`:216-231`). In a linked worktree, `.git` is a pointer file. Its index, HEAD and reflog are in the main repository's `.git/worktrees/<name>`, while branches/remotes are in the shared Git directory. They do not live underneath the watched worktree directory.

An external `git commit --allow-empty`, branch rename, or ref update need not write a tracked file underneath the workspace root. The watcher comment that `.git` is deliberately not excluded is therefore insufficient for linked worktrees. Existing tests cover a file written inside a root, root matching and teardown ([Tests/BloomCoreTests/WorktreeWatcherTests.swift:15-100](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Tests/BloomCoreTests/WorktreeWatcherTests.swift#L15)), not metadata living elsewhere.

The isolated worktree above reported:

```text
git rev-parse --absolute-git-dir
=> .../bloom-git-repro-a02ec84v/.git/worktrees/bloom-git-repro-a02ec84v-with-newline
git rev-parse --git-common-dir
=> .../bloom-git-repro-a02ec84v/.git
```

T3 resolves/canonicalises the common Git directory ([GitVcsDriverCore.ts:1040-1118](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/vcs/GitVcsDriverCore.ts#L1040)), shares ref snapshots by that identity (`:2880-2894`), and coalesces network refreshes by `(gitCommonDir, remoteName)` (`:1253-1279`). T3 does not provide a like-for-like FSEvents implementation to copy here. Its shared-repository identity is the useful architectural lesson.

Recommendation: resolve both per-worktree Git dir and common Git dir once, watch them too, and map shared-ref events to the affected sibling workspaces. Distinguish worktree-local index/HEAD updates from common ref changes. Reuse this identity for worktree-operation coordination and ref-list caching, while retaining worktree-specific indexes and diffs. Do not put all reads/writes from every project behind one global lock.

Source: [T3 repository identity](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/vcs/GitVcsDriverCore.ts#L1040).

**Use NUL-delimited worktree enumeration**

**P2 for correctness, low occurrence, command output reproduced.** Bloom's changed-file parsers already use byte-based `-z` records, but its worktree enumeration does not: [Git+Worktrees.swift:16-17](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/BloomCore/Git/Git+Worktrees.swift#L16) invokes `worktree list --porcelain`; [WorktreeListing.swift:77-92](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/BloomCore/Git/WorktreeListing.swift#L77) splits on newlines. A real worktree directory containing a newline is truncated into a path that does not exist. This can break branch-holder identification and stale-worktree restoration checks. It does not prove that Bloom subsequently deletes an unrelated worktree, because those paths have additional guards.

T3 runs `worktree list --porcelain -z` ([GitVcsDriverCore.ts:2745](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/vcs/GitVcsDriverCore.ts#L2745)) and splits fields on NUL (`:250-274`). A regression explicitly preserves newline-containing worktree paths ([GitVcsDriverCore.test.ts:1556-1581](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/vcs/GitVcsDriverCore.test.ts#L1556)).

In the first isolated repo, Python created a worktree whose absolute path ended with `-with\nnewline` through an argv argument to `git worktree add -b feature <path>`. Real `git worktree list --porcelain` returned:

```text
worktree .../bloom-git-repro-a02ec84v-with
newline
HEAD b1a6ecf4382abb269a19e25964ba541bf2c2c758
branch refs/heads/feature
```

Bloom's parser will retain only the first line's path. Its existing real-worktree and spaces tests ([Tests/BloomCoreTests/WorktreeListingTests.swift:127-181](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Tests/BloomCoreTests/WorktreeListingTests.swift#L127)) do not cover this format break.

Recommendation: adopt raw `-z` enumeration and keep all current fields, especially locked/prunable states. Do not copy T3's smaller branch-to-path projection wholesale: Bloom needs these states for safe archive/restore decisions, and T3's parser deliberately drops prunable holders.

Source: [T3 NUL parser](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/vcs/GitVcsDriverCore.ts#L250), [newline regression](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/vcs/GitVcsDriverCore.test.ts#L1556).

**Make submodule readiness part of creating a workspace**

**P2 feature gap, source-verified.** `git worktree add` leaves submodule content unpopulated. T3 detects `.gitmodules` and runs `git submodule update --init --recursive` after creating the worktree; a failure is logged and the workspace survives ([GitVcsDriverCore.ts:3027-3050](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/vcs/GitVcsDriverCore.ts#L3027)). Tests cover both populated files and an unreachable submodule ([GitVcsDriverCore.test.ts:1585-1668](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/vcs/GitVcsDriverCore.test.ts#L1585)).

Bloom's worktree helpers create/check out the worktree and return ([Git+Worktrees.swift:35-69](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/BloomCore/Git/Git+Worktrees.swift#L35)); the manager then copies configured files and records the workspace ([WorkspaceManager.swift:218-240](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/BloomCore/Workspace/WorkspaceManager.swift#L218), `:306-350`). Searches across Sources and tests found submodule mentions in project-init safeguards, but no automatic submodule initialisation in the creation/restore paths. A project's setup script can already initialise submodules; this is a gap in the default path, not an impossibility.

Recommendation: add a bounded, cancellable readiness step when `.gitmodules` exists, before starting an agent or setup script that relies on those files. Keep the workspace on failure and surface which submodules are missing, with a retry. T3's log-only warning is weaker than Bloom's existing setup failure UX and need not be copied. Cover normal, nested, offline and local-transport-restricted cases without enabling unsafe Git transports globally.

Source: [T3 initialisation](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/vcs/GitVcsDriverCore.ts#L3027), [T3 tests](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/vcs/GitVcsDriverCore.test.ts#L1585).

**Resolve base and publication remotes separately**

**P2 capability improvement, source-verified, no wrong-remote incident reproduced.** Bloom deliberately fixes `Git.remote = "origin"` ([Git+Branches.swift:32-36](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/BloomCore/Git/Git+Branches.swift#L32)) and its direct push uses `origin HEAD:refs/heads/<branch>` ([GitHub.swift:334-348](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/BloomCore/GitHub/GitHub.swift#L334)). This protects against option injection and accidental pushes to an upstream base branch, but does not honour fork workflows configured through `branch.<name>.pushRemote` or `remote.pushDefault`.

T3 resolves the publish remote through those Git settings before choosing its primary remote ([GitVcsDriverCore.ts:1351-1378](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/vcs/GitVcsDriverCore.ts#L1351)). It distinguishes an upstream that is actually the feature branch's base from its intended publication target, records `branch.<name>.gh-merge-base` before retargeting upstream, and publishes with explicit `HEAD:refs/heads/<name>` (`:2047-2114`). Its tests cover a branch tracking its base and a Git-mangled alias ([GitVcsDriverCore.test.ts:2097-2189](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/vcs/GitVcsDriverCore.test.ts#L2097)).

Recommendation: introduce one repository context that carries the base remote/ref and publish remote/ref, and use it consistently in fetch, baseline, create/continue, PR lookup and direct push. Preserve Bloom's branch validation and `--` option boundary. Treat this as a coordinated improvement, not changing the one origin constant and hoping all callers agree.

Qualification: Bloom's normal Commit/Push and Create PR buttons already delegate to the current agent ([Sources/Bloom/State/WorkspaceModel.swift:1961-2010](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/Bloom/State/WorkspaceModel.swift#L1961), `:2014-2048`). Agents can inspect and honour a project's remotes themselves. The hardcoded direct helper limitation therefore does not mean every UI push ignores configured remotes.

Source: [T3 remote resolution](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/vcs/GitVcsDriverCore.ts#L1351), [safe base-versus-publish handling](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/vcs/GitVcsDriverCore.ts#L2047).

**What Bloom already does well and should retain**

1. **Archive safety is richer than T3's raw worktree removal.** Bloom inventories uncommitted/untracked work, commits unique to the branch, detached-HEAD commits and meaningful ignored-file differences ([Git+Safety.swift:266-320](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/BloomCore/Git/Git+Safety.swift#L266)). Ignored-file differences are informational notes, not necessarily a reason to refuse, which existing tests explicitly document. Archive refuses unsafe work unless authorised, aborts on a failing archive script, preserves a recreated non-checkout folder, only deletes a branch after finding a worktree, and updates only its own stored columns ([WorkspaceManager.swift:653-773](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/BloomCore/Workspace/WorkspaceManager.swift#L653)). T3's core removal mostly invokes `git worktree remove` with optional force and handles already-gone paths ([GitVcsDriverCore.ts:3254-3302](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/vcs/GitVcsDriverCore.ts#L3254)). This comparison is the core method, not a claim that no higher T3 layer has confirmation UX.
2. **Per-repository worktree creation is already serialised.** [WorkspaceManager.swift:172-185](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/BloomCore/Workspace/WorkspaceManager.swift#L172) wraps the complete read-name/path-then-create sequence in `WorktreeCutQueue`; the queue deliberately serialises distinct creates rather than coalescing them ([WorktreeCutQueue.swift:1-57](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/BloomCore/Workspace/WorktreeCutQueue.swift#L1)). [WorkspaceStartTests.swift:394-418](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Tests/BloomCoreTests/WorkspaceStartTests.swift#L394) launches three simultaneous starts and checks distinct branches and sessions. No generic 'add a mutex' recommendation is warranted. Canonical common-dir identity can improve the key for aliases/imported linked worktrees, but this needs a demonstrated caller path before declaring an existing race.
3. **Changed-file paths already use NUL-delimited bytes.** [Git+Diffs.swift:122-164](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/BloomCore/Git/Git+Diffs.swift#L122) and `:167-215` handle tabs/newlines, renames and binary counts. [GitSafetyTests.swift:329-438](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Tests/BloomCoreTests/GitSafetyTests.swift#L329) exercises awkward paths. T3's local status still uses non-NUL porcelain v2 and newline-split numstat ([GitVcsDriverCore.ts:1626](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/vcs/GitVcsDriverCore.ts#L1626), `:1668`, `:1728-1740`, parser `:172-190`). Do not replace Bloom's parsers with these.
4. **Polling is already bounded and event-assisted.** Six-second ticks, four concurrent worktree reads, 30-second selected backstop and five-minute idle backstop are deliberate ([DiffRefreshSchedule.swift:41-79](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/BloomCore/Presentation/DiffRefreshSchedule.swift#L41)). Bloom also has fingerprint-based baseline caching with single-flight resolution and a bounded patch cache. T3 cache lessons should target correctness and common-repository work, not add a second cache blindly.
5. **Bloom already avoids optional index writes from reads.** Git's wrappers set `GIT_OPTIONAL_LOCKS=0` and disable terminal prompts ([Git.swift:31-39](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/BloomCore/Git/Git.swift#L31), `:78-81`); raw output is drained concurrently and nonzero status does not become an empty clean diff. Preserve these properties while addressing the independent process-bound issues examined later in this report.
6. **Agent-driven Git actions are an intentional product choice.** T3 offers a typed commit/push/PR workflow with phase events ([GitManager.ts:2566-2740](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/git/GitManager.ts#L2566)), which can inspire clearer progress. Bloom deliberately routes actions into the existing conversation, keeping project instructions and recovery reasoning available ([WorkspaceModel.swift:1961-2023](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/Bloom/State/WorkspaceModel.swift#L1961)). The better improvement is structured progress/results around that model, not necessarily replacing it with a generic generated commit message workflow.

**Suggested implementation order**

1. Literal path selection for destructive single-file operations and patch reads, with a two-file data-loss regression.
2. Controlled patch output and explicit `--no-index` error handling.
3. Event acknowledgement generations, then real Git metadata watch roots.
4. NUL worktree listing.
5. Submodule readiness.
6. Unified base/publication remote context if fork and non-origin workflows are important to Bloom users.

The literal-path data loss, external-diff empty patch, and newline-containing worktree listing received command-level reproduction. Other statements are source/test inspection or explicitly marked design proposals. Existing tests were read, not executed.


---

**AI runtime and recovery**

**1. Highest priority: distinguish a claimed prompt from a delivered prompt**

**Source-established crash window, not reproduced with fault injection.** Bloom has a durable delivery queue and a correct atomic single-claimant check. However, `TranscriptModel.drain` removes the delivery from the pending set before calling the runner. `claimForDelivery` writes `delivered_at`, then awaits a queue refresh, then calls `deliver`. Runner startup and thread opening happen before the user transcript row is persisted. A process crash in this interval leaves a delivery marked delivered with neither an actual provider send nor necessarily a transcript row.

Bloom evidence:

- [Sources/Bloom/State/TranscriptModel.swift:764-775](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/Bloom/State/TranscriptModel.swift#L764) claims before sending; `789-805` calls `markDelivered` then awaits other work; `1052-1073` calls `runner.send` and restores only after an error returned in this process.
- [Sources/BloomCore/Persistence/Store.swift:2669-2677](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/BloomCore/Persistence/Store.swift#L2669) only returns deliveries whose `delivered_at IS NULL`; `2719-2724` marks a delivery atomically; `2753-2757` explicitly restores it.
- [Sources/BloomCore/Agent/Codex/CodexRunner.swift:136-153](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/BloomCore/Agent/Codex/CodexRunner.swift#L136) opens the connection/thread before persisting the user's message.
- [Sources/Bloom/State/AppModel.swift:392-405](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/Bloom/State/AppModel.swift#L392) resets sessions, closes stale asks and recovers setups at launch, but does not recover delivery claims. Searching all uses of `delivered_at`, `restoreDelivery`, `markDelivered`, and `deliveredSeq` found no such recovery.
- [Tests/BloomCoreTests/AuditPersistenceTests.swift:34-58](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Tests/BloomCoreTests/AuditPersistenceTests.swift#L34) covers competing claimants and failed claim persistence. It does not cover crash after successful claim. Enqueue plus draft clear is already transactional, covered at `61-74`.

T3 Code has a useful smaller lesson than adopting its whole event-sourced architecture: command IDs and durable acceptance are explicit. Its engine reads an existing receipt before accepting a retry, verifies its aggregate, and writes events, their projection and the receipt in one SQLite transaction. A retry returns the same sequence and does not append the same user message again. [Receipt lookup](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/orchestration/Layers/OrchestrationEngine.ts#L144-L171), [transaction](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/orchestration/Layers/OrchestrationEngine.ts#L273-L314), [retry test](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/orchestration/Layers/OrchestrationEngine.test.ts#L1928-L1990).

**Recommendation:** introduce explicit `pending`, `claimed`, `accepted`, and `uncertain` delivery states, with a persistent `DeliveryID` association to the transcript message and provider turn where available. Make claiming plus creating the transcript placeholder atomic. On launch, recover an unfinished claim into a visible state. Never silently replay an uncertain provider send: acceptance may have happened just before the crash and a replay can duplicate paid work or edits. An unsent prompt should remain recoverable even if nobody can prove whether the provider saw it. Keep today's optimistic bubble suppression as presentation state rather than making `delivered_at` mean both claimed and sent.

Tests worth adding when implementing: crash/reopen after claim before runner start; after message persistence before provider request; after provider acceptance before recording acceptance; duplicate retry with same DeliveryID; do not automatically start paid work on relaunch. Bloom deliberately does not drain on launch or after Stop ([TranscriptModel.swift:730-738](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/Bloom/State/TranscriptModel.swift#L730)), which should be preserved.

**Limit on the comparison:** T3's database receipt is not a distributed transaction with the AI provider and does not prove exactly-once provider execution across a server crash. Its architecture separates accepted domain commands from provider-side effects. Borrow durable intent and reconciliation, not an unsupported exactly-once promise.

**2. High priority: Stop should explicitly account for Codex child turns**

**Confirmed missing explicit guarantee in Bloom; actual provider child leakage not measured.** Bloom captures the current parent turn and sends one interrupt for that thread/turn. Its `CodexSubagents` tracks known child identities and generates transcript status signals, but does not retain an active turn ID per child for cancellation.

Bloom evidence: [Sources/BloomCore/Agent/Codex/CodexRunner.swift:223-227](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/BloomCore/Agent/Codex/CodexRunner.swift#L223), `263-276`; [Sources/BloomCore/Agent/Codex/CodexSubagents.swift:5-46](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/BloomCore/Agent/Codex/CodexSubagents.swift#L5). Searching Codex sources found no child-interrupt path.

T3 Code explicitly handles the case where child agents are independent threads. Stop interrupts every known live child with concurrency 8, a 3-second deadline per child and 10-second overall budget, then interrupts the parent. Its fake-peer integration test deliberately leaves a child interrupt unanswered and checks that other children and the parent still receive theirs. It also tests a child whose turn-start arrived before its registration event. [Cancellation implementation](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/provider/Layers/CodexSessionRuntime.ts#L2494-L2525), [adversarial integration test](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/provider/Layers/CodexCollabRuntime.integration.test.ts#L478-L603).

**Recommendation:** track owned child thread IDs with their current turn IDs, including out-of-order announcements, and define whether Stop means this conversation's entire native agent family. Apply bounded child interruption without permitting an unresponsive child to block the parent. Capture the family being stopped at the same intent/generation boundary as the parent, so Stop cannot interrupt a replacement turn. A local fake JSON-RPC peer is sufficient for regression coverage, without paid model calls.

Preserve Bloom's strengths: Stop and permanent termination are intentionally different, so ordinary Stop keeps session grants alive; shutdown kills the provider process and its group. Bloom already guards delayed start responses and late stopped completions ([CodexRunner.swift:178-182](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/BloomCore/Agent/Codex/CodexRunner.swift#L178); [Tests/BloomCoreTests/CodexRunnerTests.swift:88](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Tests/BloomCoreTests/CodexRunnerTests.swift#L88), `130`, `450`, `574`). Killing the entire server on each Stop would discard this deliberate behaviour.

**3. Medium priority: bound event fanout before the UI consumes it**

**Confirmed unbounded queue, practical severity requires a load measurement.** Every Bloom `EventFanout` subscriber gets `AsyncStream(bufferingPolicy: .unbounded)`, and `yield` neither examines its result nor accounts for bytes. A consumer stalled on the main actor or database can retain arbitrary queued payloads. [Sources/BloomCore/Agent/SessionRunner.swift:114-137](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/BloomCore/Agent/SessionRunner.swift#L114).

T3 Code limits each live subscriber to 1,000 retained items and 8 MiB of serialised data. Its budget counts queued, coalescing, and in-flight items waiting for a client acknowledgement. Overflow terminates that subscription with an instruction to resume from the last received sequence. It coalesces consecutive `tool.updated` events over 50 ms using turn plus stable tool-call identity, preserves anonymous/parallel calls, and flushes before a completion boundary. [Budget](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/orchestration/LiveStreamBudget.ts#L10-L112), [coalescer](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/orchestration/ThreadLiveEventCoalescer.ts#L18-L102), [ACK retention regression](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/orchestration/LiveStreamBudget.test.ts#L10-L44), [identity and boundary tests](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/orchestration/ThreadLiveEventCoalescer.test.ts#L93-L132).

Bloom already batches text/thinking redraws every 50 ms ([TranscriptModel.swift:1706-1755](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/Bloom/State/TranscriptModel.swift#L1706)) and fetches persisted transcript rows after a sequence cursor (`1665-1692`). Do not report batching or incremental reload as missing. The improvement is bounding the queue before those mechanisms can run.

**Recommendation:** start with measurements and a bounded UI-specific subscription. Coalesce replaceable progress snapshots by stable identity, concatenate text deltas without dropping bytes, preserve approvals/results and lifecycle boundaries, and reload durable transcript rows from the cursor on overflow. Bloom normally does not persist every text delta ([AgentRunner.swift:129-132](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/BloomCore/Agent/AgentRunner.swift#L129), `537`), so changing `.unbounded` directly to `.bufferingNewest` would lose live text and potentially critical protocol events. Separate the protocol ingestion channel from presentation notifications and keep full authoritative state outside the bounded presentation queue.

**Limit:** T3's own provider-ingestion queues are still unbounded ([CodexSessionRuntime.ts:1297](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/provider/Layers/CodexSessionRuntime.ts#L1297), `1351`). It is evidence for robust client fanout, not evidence that every stage of its runtime has end-to-end backpressure.

**4. Medium priority: idle provider eviction with resumable sessions**

**Confirmed feature difference, performance benefit not measured.** T3 Code sweeps every five minutes and stops sessions idle for thirty minutes. It checks both the binding timestamp and session-update timestamp, skips active turns, and skips live background agent/workflow/monitor work. Failures stopping one provider do not prevent the rest of the sweep. [Reaper](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/provider/Layers/ProviderSessionReaper.ts#L17-L115), [active-turn and background-work tests](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/provider/Layers/ProviderSessionReaper.test.ts#L272-L411).

Bloom retains long-lived provider processes until permanent shutdown on close/archive/quit or a preference-driven runner replacement; ordinary Codex Stop intentionally keeps the process alive. See [TranscriptModel.swift:1215-1255](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/Bloom/State/TranscriptModel.swift#L1215), `1282-1287`; no provider idle reaper found. Bloom already persists and resumes Codex thread IDs ([CodexRunner.swift:400-434](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/BloomCore/Agent/Codex/CodexRunner.swift#L400)), so lazy restart is an existing foundation. T3's recovery additionally resolves the provider instance, adopts an existing live runtime if possible, otherwise starts using persisted cwd, model selection and resume cursor. [Recovery](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/provider/Layers/ProviderService.ts#L1227-L1301).

**Recommendation:** measure per-provider idle resident memory and session counts first. If material, add a configurable idle budget, suspend only resumable sessions with no active turns, asks, queued sends or live children, and recheck generation/state immediately before killing. Do not reuse UI busy status as the only liveness source. Account for the real tradeoff: Codex process-local approvals disappear on restart, which is why Bloom intentionally keeps the process after Stop. This makes eviction an optimisation with product consequences, not an unconditional correctness fix.

**Existing Bloom behaviour to retain**

- Durable pending messages, atomic queue claiming, transactional enqueue/draft clearing, FIFO order, explicit retry, and no automatic paid delivery on restart are already implemented. The claim/send crash gap above is narrower than lacking persistence.
- Session state has an explicit transition table ([SessionLifecycle.swift:54-106](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/BloomCore/Agent/SessionLifecycle.swift#L54)). Process death during an unfinished turn produces a useful error even for exit code zero ([UnfinishedRun.swift:60-75](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/BloomCore/Agent/UnfinishedRun.swift#L60)).
- Pending asks are settled on Stop and abandoned after restart ([CodexRunner.swift:223-238](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/BloomCore/Agent/Codex/CodexRunner.swift#L223); [AppModel.swift:392-398](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/Bloom/State/AppModel.swift#L392)). T3 similarly identifies recovered callbacks as stale rather than pretending they can be answered. Its tests include stale Codex approval callbacks and non-resumable user-input callbacks ([ProviderCommandReactor.test.ts:3933](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/orchestration/Layers/ProviderCommandReactor.test.ts#L3933), `4028`). Neither architecture can revive an in-memory callback that died with the provider connection.
- Bloom already has native Codex steering ([CodexRunner.swift:131-165](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/BloomCore/Agent/Codex/CodexRunner.swift#L131)) and provider-specific mid-turn support ([Models.swift:770-805](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/BloomCore/Model/Models.swift#L770)). Do not propose generic steering as absent.
- Bloom already has a 120-second Codex RPC deadline ([CodexClient.swift:252-289](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/BloomCore/Agent/Codex/CodexClient.swift#L252)). T3's comments explicitly identify its underlying request wait as unbounded and add targeted timeouts for child Stop, so it is not a uniformly better transport to copy.
- Bloom already presents model overload retries and per-subagent retry signals ([AgentRetry.swift](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/BloomCore/Agent/AgentRetry.swift)). No evidence found that adding another application-level automatic retry loop would improve reliability. Blind retries are especially risky around turn acceptance.

**Architecture judgement**

T3 separates provider adapters, session directory, service routing, durable commands/events/projections and runtime ingestion. This makes remote clients, multiple configured instances of one provider, and event replay easier to support. Its adapter declares model-switch, promptless-continuation, rollback and compaction capabilities explicitly. [Adapter contract](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/provider/Services/ProviderAdapter.ts#L37-L104).

Bloom already has a small `SessionRunner` seam and shared events around native Swift actors, appropriate for a local macOS app. Keep it. Adopt explicit capabilities when adding an actual new capability or a second provider instance, rather than creating a generic registry to emulate T3. The first concrete runtime work should be delivery recovery, child cancellation, and bounded presentation delivery. Full event sourcing or a transport rewrite has no demonstrated need from this investigation.


---

**AI interaction workflows**

**1. Separate planning from permissions, then support Codex planning**

**High-value, high-confidence improvement.** Bloom currently deliberately suppresses Plan on Codex. [Sources/BloomCore/Agent/ComposerControls.swift:101-112](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/BloomCore/Agent/ComposerControls.swift#L101) explains that Codex has no plan entry because approval policy crossed with sandbox has no planning setting. This correctly identifies a missing permission setting but draws an overly broad conclusion about planning capability. [Sources/BloomCore/Agent/Codex/CodexClient.swift:379-397](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/BloomCore/Agent/Codex/CodexClient.swift#L379) sends approvalPolicy, sandboxPolicy and approvalsReviewer on turn/start but no collaborationMode. A repository-wide Sources search found no collaborationMode or interactionMode implementation.

T3 models two independent dimensions. Its [Codex turn builder](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/provider/Layers/CodexSessionRuntime.ts#L584-L654) puts `interactionMode` into `collaborationMode.mode`, carrying model, reasoning effort and developer instructions in settings, while independently setting sandbox and approval fields. Its [tests](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/provider/Layers/CodexSessionRuntime.test.ts#L184-L272) assert plan mode with full access, and default mode with workspace write. This proves the source implementation distinguishes the two axes. It is not proof that every older installed Codex binary supports it.

Recommended Bloom shape: a core interaction mode value, `.build` / `.plan`, separate from PermissionMode; provider capability drives whether the control appears. Carry it through composer, session persistence, queued delivery and turn/start. Verify installed app-server schema or protocol fixture before enabling. Returning to Build must explicitly send default mode because protocol state can persist across turns. Do not simply expose Bloom's existing `.plan` permission case for Codex: [CodexRunner.swift:463-471](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/BloomCore/Agent/Codex/CodexRunner.swift#L463) maps that to read-only sandbox, which is not collaboration planning.

Test targets: round-trip the new interaction mode through stored composer defaults and queued messages; assert plan/default payloads preserve the chosen approval policy; provider switching cannot leak an unsupported mode; old/missing capability has a predictable fallback.

**2. Reusable plan artefacts and a clean implementation handoff**

**Medium-value extension once planning is separate.** T3 turns the proposed plan into an artefact with an identity and markdown, then makes the next action specific: entering text refines the plan and keeps plan mode, while an empty composer offers Implement and moves to default mode. [Pure follow-up policy](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/web/src/proposedPlan.ts#L74-L111), [tests](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/web/src/proposedPlan.test.ts#L66-L112), [composer actions](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/web/src/components/chat/ComposerPrimaryActions.tsx#L180-L251).

It additionally offers Implement in a new thread. [The handler](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/web/src/components/ChatView.tsx#L8016-L8114) creates a conversation on the existing branch/worktree, sends only the plan with selected model settings, and persists `sourceProposedPlan` with originating thread and plan IDs. This creates a clean context without requiring a new checkout. The implementation uses the app's default runtime mode for the new thread, which should not be copied blindly: Bloom should visibly preserve or explicitly choose implementation permissions.

Bloom already has proper Claude ExitPlanMode handling: [Sources/Bloom/Views/Transcript/PermissionAskRowView.swift:312-347](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/Bloom/Views/Transcript/PermissionAskRowView.swift#L312) offers Approve and implement, alternate permission choices and Keep planning. [Sources/BloomCore/Agent/PlanApproval.swift:8-44](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/BloomCore/Agent/PlanApproval.swift#L8) normalises implementation mode, stores approval choices and keeps the rejection nonterminal. This is not missing plan approval. The narrower opportunity is a backend-independent plan record and an optional new-conversation implementation action with source provenance. Bloom already has a useful creation precedent in [Sources/BloomCore/Agent/BackendChange.swift:5-28](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/BloomCore/Agent/BackendChange.swift#L5): switching provider on a spoken chat creates a new conversation in the same worktree.

Suggested test cases: plan-only handoff carries the latest plan version, model and permission choice; source link remains after reload; failed thread creation does not mark the plan implemented; refining never starts implementation; no implicit worktree duplication.

**3. Snapshot-backed turn diffs, followed by optional rewind**

**High-value Git/AI crossover.** T3's changed-file section is backed by checkpoint files and opens a diff for the selected turn/file. [MessagesTimeline](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/web/src/components/chat/MessagesTimeline.tsx#L2455-L2505) consumes TurnDiffSummary, rather than reconstructing changes from tool display events. [CheckpointStore contract](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/checkpointing/CheckpointStore.ts#L51-L77) describes isolated temporary-index capture into hidden Git refs. Capture and restore semantics are examined in the shared implementation section below.

Bloom does have per-turn file summaries. [Sources/Bloom/Views/Transcript/TurnScan.swift:5-79](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/Bloom/Views/Transcript/TurnScan.swift#L5) scans up to 400 transcript rows and aggregates Claude Edit/Write/MultiEdit/NotebookEdit and Codex fileChange payloads. [TurnFileChip.swift:8-31](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/Bloom/Views/Transcript/TurnFileChip.swift#L8) displays counts and Quick Look on the current file. This answers approximately what tools wrote, not the net repository change across the turn, and does not reconstruct the old file. Consequences inferred directly from the code: shell scripts or formatters that edit files are absent; writing a file twice accumulates operation counts; sufficiently long turns lose earlier edits; a historical chip previews current contents. This should be described as a stronger implementation of an existing feature, not a missing turn summary.

Start with immutable before/after snapshots plus a turn-scoped diff accessible from the existing file chips. Capturing real worktree state can include external changes from another chat or terminal during the same time interval, so describe the result as changes during the turn rather than guaranteed authorship. Bloom can run multiple sessions per worktree, making that distinction material. Keep attributed tool activity alongside the snapshot diff where useful.

T3 adds Edit from here on old user messages. [Rewind action](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/web/src/components/ChatView.tsx#L6552-L6651) gates by provider rollback capability and idle state, waits for the reverted state to project, and restores prompt plus attachments without dropping an existing draft. Its [dialog](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/web/src/components/ChatView.tsx#L9246-L9288) separately offers conversation rewind with file restore or with current files retained. Tests in [apps/web/src/components/ChatView.logic.test.ts:2280](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/web/src/components/ChatView.logic.test.ts#L2280) onward cover waiting for state projection and checkpoint failure handling; timeline tests at [MessagesTimeline.logic.test.ts:1240](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/web/src/components/chat/MessagesTimeline.logic.test.ts#L1240) cover mapping rewind counts to user rows.

Bloom Sources search found no conversation rollback / turn checkpoint facility. FileRevert is a different operation. Ship the turn diff first; only then add rewind with provider capability checks, draft/attachment recovery, worktree-wide running-agent checks, a backup/recovery path and explicit semantics for index state, untracked files and edits since checkpoint. Do not present deleting transcript rows as rollback if the provider still retains them in context.

**4. Terminal selection as structured prompt context**

**Small, concrete quality-of-life feature.** T3 exposes Add to chat next to Copy for terminal selections, then captures terminal ID, label, line range and the exact selected text. [Menu](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/web/src/components/ThreadTerminalDrawer.tsx#L250-L284), [capture](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/web/src/components/ThreadTerminalDrawer.tsx#L566-L607). It does not rely on a later agent rereading mutable scrollback. [Structured record](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/web/src/lib/composerContextRecords.ts#L158-L170) preserves that provenance and text. [ThreadTerminalDrawer.test.ts:12-28](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/web/src/components/ThreadTerminalDrawer.test.ts#L12) covers hiding Add to chat without a target; context record tests cover expired chips and serialisation.

Bloom's [Sources/Bloom/Views/Terminal/TerminalPaneMenu.swift:19-60](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/Bloom/Views/Terminal/TerminalPaneMenu.swift#L19) only creates split, zoom and close items. [TerminalView.swift:222-224](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/Bloom/Views/Terminal/TerminalView.swift#L222) returns that custom menu when available. Searching Sources found no terminal selection-to-composer context path. Users can copy and paste today, so this is convenience and preservation of provenance, not missing terminal access for agents.

Add an action on an existing selection that stages a named terminal excerpt into the destination conversation's draft, letting the user add instructions before sending. Keep the exact snapshot even if the terminal scrolls, clears or closes. Follow Bloom's existing attachment and review-comment draft patterns; do not introduce a generic context subsystem solely for this one producer.

**5. Typed context references are worth borrowing incrementally**

T3 has canonical records for terminal excerpts, review comments, browser annotations and uploaded attachments, and inline references point to stable IDs. [Reference helpers](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/web/src/lib/composerContextReferences.ts#L13-L137) preserve placement, deduplicate references and scope IDs. [Record conversion](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/web/src/lib/composerContextRecords.ts#L294-L321) constructs message context from producer records. The [tests](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/web/src/lib/composerContextRecords.test.ts#L190-L275) include colliding IDs and screenshot linkage; later tests cover partial-copy selection carrying only selected backing records (:709-751).

Bloom already has inline attachment tokens, copied file staging, persisted review comments, browser region capture and draft recovery. [Sources/BloomCore/Transcript/AttachmentDraft.swift:84-128](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/BloomCore/Transcript/AttachmentDraft.swift#L84) parses attachment tokens, and [PromptAttachments.swift:12-27](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/BloomCore/Transcript/PromptAttachments.swift#L12) puts accessible copies in ignored worktree scratch space. Review comments are stronger than bare line numbers: [ReviewComment.swift:17-58,177-224](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/BloomCore/Transcript/ReviewComment.swift#L17) captures neighbouring text, re-finds shifted lines and explicitly marks outdated anchors. [Tests/BloomCoreTests/ReviewCommentTests.swift:67-148](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Tests/BloomCoreTests/ReviewCommentTests.swift#L67) covers edits above the anchor, deletion, indentation changes and repeated-line disambiguation. Browser UI lives in [Sources/Bloom/Views/Center/Browser/BrowserRegionCanvas.swift](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/Bloom/Views/Center/Browser/BrowserRegionCanvas.swift) and [BrowserRegionCaptureView.swift](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/Bloom/Views/Center/Browser/BrowserRegionCaptureView.swift).

The opportunity is one typed payload boundary when adding terminal excerpts or plan artefacts, so restore/copy/recall does not have to reverse-engineer visible labels. Do not replace Bloom's content-based review anchoring with T3's diff-coordinate records or claim attachments/browser annotations are absent.

**6. Areas where Bloom already meets or exceeds the relevant pattern**

- **Queues and steering:** Bloom has a durable SQLite delivery queue, optimistic pending bubbles, retry, remove, edit-back-to-composer, explicit steer, and stop/relaunch rules. See [Sources/Bloom/State/TranscriptModel.swift:599-684,816-975](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/Bloom/State/TranscriptModel.swift#L599), [Sources/BloomCore/Agent/DeliverySteer.swift:3-50](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/BloomCore/Agent/DeliverySteer.swift#L3); [Tests/BloomCoreTests/DeliveryTests.swift:224-385](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Tests/BloomCoreTests/DeliveryTests.swift#L224) covers ordering, relaunch survival, cancellation and failed start. Codex already uses native `turn/steer` with expectedTurnId in [CodexClient.swift:400-416](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/BloomCore/Agent/Codex/CodexClient.swift#L400). Do not recommend adding basic steering or a second queue.
- **Permission scope:** Bloom already offers once/session/project only where the request and context can support it, explains scope and stores implementation permission choices. [PermissionScopeOffer.swift:36-64](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/BloomCore/Agent/PermissionScopeOffer.swift#L36), [PermissionAskRowView.swift:312-357](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/Bloom/Views/Transcript/PermissionAskRowView.swift#L312). T3's provider-advertised action choices and explicit session labels are good regression fixtures, but are not a broad missing feature. See [apps/web/src/components/chat/ComposerPendingApprovalActions.test.tsx:8-45](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/web/src/components/chat/ComposerPendingApprovalActions.test.tsx#L8) and [ComposerPendingApprovalPanel.test.tsx:8-51](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/web/src/components/chat/ComposerPendingApprovalPanel.test.tsx#L8).
- **Question drafts:** Bloom retains answer state outside recycled transcript cells in [AgentQuestionDraft.swift:3-22](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/BloomCore/Agent/AgentQuestionDraft.swift#L3), supports multi-select and Other, and validates completion. T3's composer-integrated question flow is a different presentation, not inherently a better fit for Bloom. No recommendation to relocate Bloom's existing question UI without user evidence.
- **Provider-specific settings:** Bloom already dynamically loads supported reasoning efforts, filters permission choices, hides output styles outside Claude and context-window overrides outside Codex. [ComposerControls.swift:109-165](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/BloomCore/Agent/ComposerControls.swift#L109), [Sources/Bloom/Views/Center/Composer/ComposerModelCatalog.swift:128-136](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/Bloom/Views/Center/Composer/ComposerModelCatalog.swift#L128). Improve the capability contract where adding plan/rollback instead of copying T3's much broader web/mobile/provider-instance architecture.

**Workflow acceptance criteria**

Relative scope and minimum acceptance criteria:

| Improvement | Scope | Regression criteria |
| --- | --- | --- |
| Codex Plan/Build | Medium | Plan/default turn payloads retain permission settings; persisted defaults and queued messages retain mode; unsupported provider/version does not expose a working-looking control; returning to Build clears planning. |
| Snapshot-backed turn diffs | Large | Include shell edits and new files; repeated edits report net diff; historical results survive later turns and relaunch; real Git index is unchanged by capture; snapshot failure is visible; concurrent session edits are not mislabelled as certain authorship. |
| Rewind with optional files | Large, separate from diff | Refuse with any mutating work in same worktree; server context and visible transcript converge; failure retains history and draft; restored attachments preserve existing draft; pre-existing untracked/index changes and later edits have explicit tested treatment; unsupported rollback cannot silently truncate UI history. |
| Terminal excerpt to draft | Small | Disabled without selection/destination; immutable text survives terminal close/scroll; workspace/chat switching cannot send excerpt to wrong session; attaching never sends automatically; draft survives relaunch. |
| Plan artefact and clean handoff | Medium | Latest plan version, source link, model and selected permissions survive creation/reload; refine stays in planning; failed start does not mark implemented; same-worktree handoff does not accidentally create a checkout. |

Avoid wholesale adoption of T3's component structure. [ChatView.tsx](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/web/src/components/ChatView.tsx) is over 9,000 lines and [ChatComposer.tsx](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/web/src/components/chat/ChatComposer.tsx) over 6,000 lines at this snapshot. Their pure policy helpers and targeted regression cases are useful references; Bloom's existing BloomCore/view boundary is the better home for these decisions.


---

**Shared process handling, GitHub coordination and architectural fit**

**Shared subprocess reliability**

Bloom's short-lived process runner should gain an output budget and a deadline covering process exit and output collection. These are separate from the long-lived AI stream changes below.

T3's `ProcessRunner` defaults to a 60-second timeout and an 8 MiB output limit per stream, exposes typed spawn/stdin/read/output-limit/timeout errors, and allows either failure or explicitly marked truncation. Its timeout wraps the scoped operation, including concurrent output collection. Those defaults are examples, not values to copy indiscriminately into Git mutation commands. See [process contract and defaults](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/processRunner.ts#L20-L160), [collection and deadline implementation](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/processRunner.ts#L197-L283), and [output-budget tests](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/processRunner.test.ts#L203-L289). T3's tests were inspected, not executed.

Bloom's `Shell.run` reads both pipes with `readDataToEndOfFile`, stores all output, writes stdin before installing its timeout, sends SIGTERM on timeout, cancels the timeout after direct-child exit, then waits for both pipes to reach EOF. It returns a process status with no distinct timed-out outcome. `Git.runRaw` duplicates the unrestricted pipe collection and has no timeout argument. See [Shell.run](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/BloomCore/System/Shell.swift#L132-L233) and [Git.runRaw](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/BloomCore/Git/Git.swift#L63-L130).

**Reproduced using Bloom's actual unchanged Swift sources:** compiled [Shell.swift](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/BloomCore/System/Shell.swift), [ExecutableSearchPath.swift](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/BloomCore/System/ExecutableSearchPath.swift) and [ProcessExitGate.swift](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/BloomCore/System/ProcessExitGate.swift) with a tiny async executable. Both calls used `Shell.run("/bin/sh", ["-c", script], timeout: .milliseconds(200))`:

| Script | Observed elapsed | Returned status |
| --- | --- | --- |
| `sleep 2` | 0.210906542 seconds | 15 |
| `(sleep 2) & exit 0` | 2.016809583 seconds | 0 |

The second case shows that an exited parent with an inherited pipe can outlive the requested deadline and still report success. It is not a measurement of a production Git hang, and there was no app launch or access to Bloom's database. The short-lived descendants exited naturally. The probe source is reproduced here so the finding survives cleanup of `/tmp`:

```swift
import Foundation

@main struct Probe {
    static func main() async throws {
        let clock = ContinuousClock()
        for script in ["sleep 2", "(sleep 2) & exit 0"] {
            let start = clock.now
            let result = try await Shell.run(
                "/bin/sh", ["-c", script], timeout: .milliseconds(200)
            )
            print(start.duration(to: clock.now), result.status)
        }
    }
}
```

Compile with `swiftc -swift-version 6 -parse-as-library Sources/BloomCore/System/Shell.swift Sources/BloomCore/System/ExecutableSearchPath.swift Sources/BloomCore/System/ProcessExitGate.swift /tmp/Probe.swift -o /tmp/bloom-shell-probe`, after saving the snippet to `/tmp/Probe.swift`.

Recommended scope: medium. Add byte-preserving collection policies, typed timeout/cancellation/output-limit results, and owned subprocess cleanup with a bounded final drain. Keep stderr tails bounded. Structured Git output must fail explicitly or spill to a file when too large; silently truncating status or a patch would create correctness bugs. Use purpose-specific policies for mutations and long-running hooks. Regression cases should cover a descendant holding stdout, a child ignoring SIGTERM, blocked stdin, large output, invalid UTF-8, and a normal child flushing its last bytes.

Bloom already solves part of this in `StreamingProcess`: EOF quiet/hard limits and group-aware signalling are present. Reuse those lessons, while retaining the ordered drains and SIGPIPE protection. Do not claim Bloom lacks subprocess cancellation in general. See [stream shutdown](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/BloomCore/System/StreamingProcess.swift#L293-L320) and [bounded EOF settling](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/BloomCore/System/StreamingProcess.swift#L360-L400).

**Coordinate GitHub backoff and distinguish stale data from missing data**

T3 has a provider-and-host cooldown shared across PR operations, with provider reset times, exponential fallback from 30 seconds to 15 minutes, and generation leases so an older successful request cannot erase a newer rate limit. `PullRequestService` wraps provider calls with it. Background reads pause; explicit interactive operations can bypass the pause. Its GraphQL budget separately reserves quota for reads after observing a quota snapshot and accounts conservatively for out-of-order responses. See [cooldown](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/sourceControl/SourceControlRateLimit.ts#L63-L163), [wrapper and interactive bypass](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/pullRequest/PullRequestService.ts#L420-L525), [actual PR integration](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/pullRequest/PullRequestService.ts#L670), [GraphQL integration](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/pullRequest/GitHubPullRequestCli.ts#L1100-L1132), and [race/reset tests](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/sourceControl/SourceControlRateLimit.test.ts#L18-L121).

The scoped T3 timeout is an implementation reference, not a measured hard wall-clock cleanup guarantee. Its inspected timeout tests use fake process handles; the real inherited-pipe probe above was run only against Bloom.

Bloom already serialises sidebar lookups, polls at 120 seconds with a 110-second cache, skips irrelevant workspaces, and retains the last good result on failure. Its inspector has a separate freshness policy and shares displayed PR state. The improvement is a host-wide budget and explicit stale/error state, not another cache. See [sidebar polling](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/Bloom/Views/Sidebar/WorkspacePullRequests.swift#L20-L33), [sequential lookup](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/Bloom/Views/Sidebar/WorkspacePullRequests.swift#L94-L115), and [shared inspector result](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/Bloom/State/WorkspaceModel.swift#L1917-L1952).

One concrete boundary issue: Bloom's lookup by PR number converts process failures, nonzero responses and decoding failures to cached `nil`. That conflates unavailable with absent even though a preceding request succeeding does not guarantee this one succeeds. By contrast, its branch lookup distinguishes a known not-found response from an error. See [number lookup](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/BloomCore/GitHub/GitHub.swift#L425-L449) and [branch lookup](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/Sources/BloomCore/GitHub/GitHub.swift#L373-L406). Existing last-good UI retention reduces visible flicker; no production loss of a PR badge was reproduced.

Recommended scope: medium. Introduce typed results for present, absent, stale and unavailable; share cooldowns and in-flight requests at the GitHub boundary; preserve last-good content with a retry time. Distinguish host/account identity if multi-account support is added. Honour `Retry-After` or reset data where obtainable; use a bounded fallback for CLI error text. Do not switch to custom GraphQL solely for this feature. Regression tests should cover a 429 or CLI rate-limit response followed by another workspace poll, stale success racing a fresh rate limit, genuine not-found versus malformed JSON, and independent enterprise hosts.

**Checkpoint implementation details worth preserving and changing**

T3's concrete Git implementation creates a unique temporary index inside the common Git directory, reads HEAD into it if present, runs `add -A`, writes a tree, creates a parentless checkpoint commit and updates a hidden ref. Cleanup removes the temporary index. This captures the resulting worktree contents without altering the user's real index or branch history. See [capture implementation](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/vcs/GitVcsDriver.ts#L715-L793) and [index/path preservation tests](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/checkpointing/CheckpointStore.test.ts#L307-L402).

There are important limits to copying this as an Undo feature. The snapshot records worktree contents, not a separate snapshot of the user's staging choices. Restore writes the snapshot to both index and worktree, then runs `git clean -fd -- .`; that can discard later non-ignored untracked files. The reactor checks provider rollback support before touching files, which is good, but restores files before requesting the provider rollback. Those operations are not atomic. A later provider failure therefore needs recovery semantics in any Bloom implementation. See [restore implementation](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/vcs/GitVcsDriver.ts#L801-L845) and [revert ordering](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/apps/server/src/orchestration/Layers/CheckpointReactor.ts#L728-L797).

For Bloom, start with read-only historical turn diffs. Before adding restore, specify staging preservation, non-ignored untracked recovery, ignored-file exclusions, nested repositories/submodules, concurrent sessions in the same workspace, ref ownership and retention. Take a recovery snapshot before changing files, and persist restore progress so a partial failure is visible and recoverable. These are design requirements inferred from the inspected implementation; T3 restore failures were not exercised live.

**Architectural fit and licensing**

T3 has broader product scope: server-owned execution with web, desktop and mobile clients, remote environments, and provider adapters. Its durable event log, command receipts and projected state address reconnects and multiple clients. Bloom is a native Mac application with a core actor and SQLite store; these differences explain much of T3's machinery. Copy specific contracts and failure tests before considering an event-sourcing or server/client rewrite. See [T3 architecture](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/docs/internals/overview.md) and [Bloom boundaries](https://github.com/spatie/bloom/blob/e00870ceec7cdb3c5d92a610dea0f1ac610e4d01/CLAUDE.md).

GitLab, Bitbucket and Azure DevOps are supported alongside GitHub in T3. They are evidence of a useful host abstraction if Bloom needs more hosts, not sufficient reason to prioritise four new integrations now. See [source control documentation](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/docs/user/source-control.md).

T3's repository is MIT licensed. If implementation code is copied rather than independently reimplemented from the behaviour, preserve the applicable copyright and permission notice. See [licence](https://github.com/pingdotgg/t3code/blob/a43f9b45ae85caf37e0be8270ad3d27365ece2bd/LICENSE).
