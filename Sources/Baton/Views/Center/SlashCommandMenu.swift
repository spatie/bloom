import SwiftUI
import Observation

/// A `/command` the user can run.
///
/// Baton ships no list of its own. The commands that exist are whatever markdown files sit in the
/// user's and the repository's `.claude/commands` folders, and those change while the app is
/// running without anything telling us, so they are read from disk rather than modelled.
struct SlashCommand: Identifiable, Hashable, Sendable {
    enum Origin: String, Sendable {
        case project
        case user

        var label: String {
            switch self {
            case .project: "project"
            case .user: "user"
            }
        }
    }

    var name: String
    var detail: String
    var origin: Origin

    var id: String { "\(origin.rawValue):\(name)" }
}

/// Finds and caches the command files for one workspace.
///
/// The scan is a directory walk plus a small read per file, which is cheap once and wasteful on
/// every keystroke, so the result is held until the workspace changes.
@MainActor
@Observable
final class SlashCommandCatalog {
    private(set) var commands: [SlashCommand] = []
    private var loadedPath: String?

    func load(workspacePath: String) async {
        guard loadedPath != workspacePath else { return }
        let home = NSHomeDirectory()
        commands = await Task.detached(priority: .utility) {
            SlashCommandCatalog.scan(home: home, workspacePath: workspacePath)
        }.value
        loadedPath = workspacePath
    }

    func reload(workspacePath: String) async {
        loadedPath = nil
        await load(workspacePath: workspacePath)
    }

    /// Filters on the text typed after the `/`, so `/comm` finds `commit` and `cmt` finds it too.
    func matches(_ query: String) -> [SlashCommand] {
        guard !query.isEmpty else { return commands }
        return commands
            .compactMap { command -> (SlashCommand, Int)? in
                guard let score = FuzzyMatch.score(command.name, query: query) else { return nil }
                return (command, score)
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.name < rhs.0.name
            }
            .map(\.0)
    }

    // MARK: - Disk

    /// Project commands come last so they win the name collision, matching how Claude Code
    /// resolves a command that exists in both places.
    nonisolated static func scan(home: String, workspacePath: String) -> [SlashCommand] {
        var byName: [String: SlashCommand] = [:]
        var order: [String] = []

        for (directory, origin) in [
            ("\(home)/.claude/commands", SlashCommand.Origin.user),
            ("\(workspacePath)/.claude/commands", SlashCommand.Origin.project),
        ] {
            for command in scan(directory: directory, origin: origin) {
                if byName[command.name] == nil { order.append(command.name) }
                byName[command.name] = command
            }
        }

        return order.compactMap { byName[$0] }.sorted { $0.name < $1.name }
    }

    nonisolated static func scan(directory: String, origin: SlashCommand.Origin) -> [SlashCommand] {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            return []
        }
        guard let walker = manager.enumerator(atPath: directory) else { return [] }

        var found: [SlashCommand] = []
        for case let relative as String in walker {
            guard relative.hasSuffix(".md") else { continue }
            let full = (directory as NSString).appendingPathComponent(relative)
            // A command in a subfolder is namespaced with a colon, the way the CLI writes it.
            let name = String(relative.dropLast(3)).replacingOccurrences(of: "/", with: ":")
            found.append(SlashCommand(name: name, detail: describe(full), origin: origin))
        }
        return found
    }

    /// Prefers the `description:` line from YAML frontmatter. Without one, the first real line of
    /// the file is a better summary than showing nothing.
    nonisolated static func describe(_ path: String) -> String {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return "" }
        var lines = contents.components(separatedBy: .newlines)

        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            lines.removeFirst()
            var frontmatter: [String] = []
            while let line = lines.first {
                lines.removeFirst()
                if line.trimmingCharacters(in: .whitespaces) == "---" { break }
                frontmatter.append(line)
            }
            for line in frontmatter {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.lowercased().hasPrefix("description:") else { continue }
                return clean(String(trimmed.dropFirst("description:".count)))
            }
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            return clean(String(trimmed.drop { $0 == "#" }))
        }
        return ""
    }

    nonisolated private static func clean(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
            value = String(value.dropFirst().dropLast())
        }
        return value.count > 90 ? String(value.prefix(89)) + "\u{2026}" : value
    }
}

/// The panel that drops above the composer once the draft is a lone `/command`.
///
/// Rendering only. The composer owns the selection and the key handling, because its text view
/// never gives up first responder while the menu is open.
struct SlashCommandMenu: View {
    var commands: [SlashCommand]
    var query: String
    var selectedIndex: Int
    var onPick: @MainActor (SlashCommand) -> Void
    var onHighlight: @MainActor (Int) -> Void = { _ in }

    @State private var hoveredIndex: Int?

    var body: some View {
        MenuPanel {
            if commands.isEmpty {
                MenuEmptyRow(
                    text: query.isEmpty
                        ? "No commands in ~/.claude/commands or .claude/commands"
                        : "No command matches /\(query)"
                )
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                                row(command, index: index)
                                    .id(index)
                            }
                        }
                        .padding(Metrics.cornerSmall)
                    }
                    .frame(maxHeight: Metrics.sidebarWidth)
                    .onChange(of: selectedIndex) { _, index in
                        proxy.scrollTo(index, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func row(_ command: SlashCommand, index: Int) -> some View {
        HStack(spacing: Metrics.corner) {
            Text("/\(command.name)")
                .font(Typo.code)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
            if !command.detail.isEmpty {
                Text(command.detail)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if command.origin == .project {
                Chip(text: command.origin.label)
            }
        }
        .padding(.horizontal, Metrics.corner)
        .frame(height: Metrics.rowHeight)
        .contentShape(Rectangle())
        .rowBackground(isSelected: index == selectedIndex, isHovered: index == hoveredIndex)
        .onHover { hovering in
            hoveredIndex = hovering ? index : (hoveredIndex == index ? nil : hoveredIndex)
            if hovering { onHighlight(index) }
        }
        .onTapGesture { onPick(command) }
    }
}
