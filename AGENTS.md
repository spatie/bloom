# Working on Bloom

Read [CLAUDE.md](CLAUDE.md) for the shared architecture, coding, testing and app isolation rules.
Those rules apply to every agent, including Codex.

## Project skills

Read the matching `SKILL.md` before building an installed dev app, releasing, or doing the Swift
work described below. Load supporting references only when relevant to the task.

| Skill | Use for |
| --- | --- |
| [bloom-dev-build](.claude/skills/bloom-dev-build/SKILL.md) | Build and install the isolated Bloom Dev app from a committed revision. |
| [bloom-release](.claude/skills/bloom-release/SKILL.md) | Publish a release, generate and publish notes on GitHub and runbloom.app, or package signed local artefacts. |
| [swiftui-pro](.claude/skills/swiftui-pro/SKILL.md) | Write or review Bloom's macOS SwiftUI views. |
| [swift-concurrency-pro](.claude/skills/swift-concurrency-pro/SKILL.md) | Write or review async code, actor isolation, cancellation and streams. |
| [swift-testing-pro](.claude/skills/swift-testing-pro/SKILL.md) | Write or review Swift Testing tests in BloomCoreTests. |

The maintained files live in `.claude/skills/`. Each entry under `.agents/skills/` is a relative
symlink to the same folder, so Claude and Codex use identical instructions. Add a matching symlink
when adding a skill; keep references relative and commands relative to the repository root.
