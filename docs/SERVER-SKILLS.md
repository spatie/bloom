# Server skills

Skill files live on the server, under its existing service account. Mac, iPhone and iPad share
`ServerSkillsSession` and the same protocol. No client opens the server database or needs root
access to manage these files.

## Capability and envelope

Read `diagnostics` and require `diagnostics._0.skillManagement == true` before sending skills
requests. This is additive to protocol 14. Missing or false means the server must be updated;
keep normal workspace connections usable and do not probe support with a mutation.

Requests use `operation.skills._0`; replies use `result.skills._0`. Each request has the normal
UUID command ID. Examples below show only the operation payload:

```json
{"skills":{"_0":{"action":"inspect"}}}
```

```json
{"skills":{"_0":{"action":"previewGit","repositoryURL":"https://github.com/example/skills.git","ref":"main"}}}
```

| Action | Fields | Behaviour |
| --- | --- | --- |
| `inspect` | Optional `workspaceID` | List managed and existing user skills, plus read-only project skills for a server-resolved workspace. |
| `read` | `skillID`, optional `planID` and `workspaceID` | Read the selected skill's bounded `SKILL.md`, including from a pending review. |
| `previewImport` | `files` | Validate an explicitly selected file bundle and return a review plan. |
| `previewGit` | `repositoryURL`, optional `ref`, optional `collectionID` | Resolve and stage a Git collection; an existing collection ID reviews an update. |
| `apply` | `planID`, `selectedSkillNames`, `agents` | Install the reviewed staged bytes for the selected agents. No second fetch occurs. |
| `setEnabled` | `skillID`, `revision`, `agents` | Change discovery links only if the reviewed revision still matches. An empty agent list disables the skill. |
| `remove` | `skillID`, `revision` | Remove a managed skill from discovery and the inventory without touching unmanaged files. |

Agent names are `claude` and `codex`. Sources are `personal`, `git`, `project` and `unmanaged`.
Project and unmanaged skills are read-only in this API. A Git plan identifies the exact resolved
commit. Plans expire after 15 minutes; `expiresAt` uses the protocol's standard numeric seconds
since 2001-01-01 UTC. Expiry requires a fresh review, never silently fetching a newer commit.

`ServerSkillsResponse` contains `skills`, optional `plan`, optional `content` and `warnings`.
Skill records include source, revision, enabled agents, file counts and bytes, server path and
optional repository, tracked ref and commit provenance. Inventory omits supporting file paths;
`read` returns the selected skill with its file paths alongside the bounded instructions. An update
with no explicit ref keeps the collection's original branch, tag or fixed commit. Treat server paths as display values, not client file URLs.
Only `inspect` and `read` bypass the durable command journal. Retrying a mutation must reuse its
exact original command UUID and payload. An uncertain response does not authorise a second
installation. If a server restart loses a pending review, create and approve a fresh plan.

## Import boundaries

Files use relative paths such as `example/SKILL.md`, Base64 `data` and optional `isExecutable`.
A bundle is limited to 512 files, 4 MB total and 1 MB per file. `SKILL.md` must be UTF-8 text of at
most 64 KB. Names and paths are checked by the shared client policy and checked again on the
server. Hidden files, credential filenames, traversal, duplicate paths, symlinks and special
files are refused. Executable bits are preserved for supporting scripts; importing does not run
those scripts.

Git imports read objects without checking out a working tree. Hooks, submodules and clean/smudge
filters do not run. Downloads have a 90-second deadline and a monitored 64 MB staging limit. At most four pending
plans retain up to 16 MB of payloads; expired plans are released on the next request. Git URLs must
use HTTPS without embedded credentials. GitHub repositories may use the server's existing `gh`
sign-in through a fixed host-scoped helper. Other hosts use no credential helper; import private
collections from the Mac instead. The server stages exact content before
presenting a plan; the client reviews names, supporting files, instructions and enabled agents.

Managed payloads and provenance use the server data directory's `skills` subdirectory. Discovery
links are individually owned and checked before replacement or removal. Existing unmanaged skills
are never overwritten. Removed immutable payloads remain available for recovery; removal does not
promise immediate disk reclamation.

The protocol schema is generated in `Protocol/bloom-v14.schema.json`. Swift-encoded examples in
`Protocol/vectors-v14.json` verify the unnamed enum wrapper, Base64 data and date representation.

## Agent discovery references

Claude Code documents personal skills at `~/.claude/skills/<name>/SKILL.md` and supports
symlinked skill folders. See [Claude Code skill locations](https://code.claude.com/docs/en/skills#choose-where-skills-load).

Codex discovers personal skills from `~/.agents/skills` and retains `$CODEX_HOME/skills` for
backward compatibility. Bloom publishes new managed Codex skills to `~/.agents/skills`.
Verified against [OpenAI's skill roots implementation](https://github.com/openai/codex/blob/516f2780fd227a80cd9fe89488f5039245090b71/codex-rs/ext/skills/src/host_roots.rs#L95-L108)
and [user-skill directory symlink policy](https://github.com/openai/codex/blob/516f2780fd227a80cd9fe89488f5039245090b71/codex-rs/ext/skills/src/loader/host.rs#L159-L163).

Skill publication and index changes use a durable transaction journal. A failed operation restores
previous links and provenance; restart recovery reconciles a committed index or restores the
previous settings. Recovery changes discovery links only and never executes skill scripts.

Legacy Codex personal skills in `~/.codex/skills` are also inventoried. Bloom refuses to publish a
new managed Codex skill with the same name, so an import cannot silently shadow that existing skill.

## Container agents

A wrapper with `execution.bridge = true` can opt into server-managed skills using
`BLOOM_SKILL_BUNDLES_DIRECTORY`, `BLOOM_CLAUDE_SKILLS_DIRECTORY` and
`BLOOM_CODEX_SKILLS_DIRECTORY`. Bloom exports these only for a server-side wrapped agent when
managed skills are enabled. Mount the bundle directory read-only at its same absolute path so
checked discovery symlinks resolve. Mount the Claude and Codex discovery directories read-only
at the container user's corresponding skill locations. Do not mount the server's whole home or
data directory. The There There development wrapper implements this contract for new agent
invocations; existing long-lived terminal containers need their own mounts before they see
server-wide skills. Repository-owned skills already travel with the workspace mount.
