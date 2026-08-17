import SwiftUI
import Observation
import BatonCore

/// One candidate for an `@mention`.
///
/// The directory is carried separately from the file name because the menu shows them with
/// different weight: people recognise `Store.swift` first and only then care which folder it
/// came from.
struct FileMatch: Identifiable, Hashable, Sendable {
    /// Path relative to the workspace root, which is exactly what gets inserted in the draft.
    var path: String
    var score: Int

    var id: String { path }

    var fileName: String {
        (path as NSString).lastPathComponent
    }

    var directory: String {
        (path as NSString).deletingLastPathComponent
    }

    /// Ranks the whole candidate list against what the user typed after the `@`.
    ///
    /// Pure and nonisolated so it can run off the main actor: a large repository has tens of
    /// thousands of tracked files and this is called on every keystroke.
    nonisolated static func search(_ paths: [String], query: String, limit: Int) -> [FileMatch] {
        guard !query.isEmpty else {
            return paths.prefix(limit).map { FileMatch(path: $0, score: 0) }
        }

        var found: [FileMatch] = []
        found.reserveCapacity(min(paths.count, limit * 4))

        for path in paths {
            guard let score = FuzzyMatch.score(path, query: query) else { continue }
            // A hit inside the file name beats one that only matched folder names, because
            // people type the file they are thinking of, not the folder it lives in.
            let nameBonus = FuzzyMatch.score((path as NSString).lastPathComponent, query: query) ?? 0
            found.append(FileMatch(path: path, score: score + nameBonus))
        }

        found.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.path.count != rhs.path.count { return lhs.path.count < rhs.path.count }
            return lhs.path < rhs.path
        }
        return Array(found.prefix(limit))
    }
}

/// Subsequence scoring shared by the file menu and the slash command menu.
///
/// Deliberately not a real fuzzy finder. The rule is only "every character of the query appears
/// in order", plus bonuses that push the obvious answer to the top: runs of adjacent characters,
/// matches at the start of a word, and a prefix match on the whole candidate.
enum FuzzyMatch {
    static func score(_ candidate: String, query: String) -> Int? {
        guard !query.isEmpty else { return 0 }

        let haystack = Array(candidate.lowercased())
        let needle = Array(query.lowercased())
        guard needle.count <= haystack.count else { return nil }

        var total = 0
        var haystackIndex = 0
        var previousMatch = -2

        for character in needle {
            var matched = false
            while haystackIndex < haystack.count {
                let current = haystack[haystackIndex]
                haystackIndex += 1
                guard current == character else { continue }

                let position = haystackIndex - 1
                if position == previousMatch + 1 { total += 8 }
                if position == 0 { total += 12 }
                if position > 0, isBoundary(haystack[position - 1]) { total += 6 }
                total += 1
                previousMatch = position
                matched = true
                break
            }
            if !matched { return nil }
        }

        // Shorter candidates win ties, so `Store.swift` outranks `StoreMigrationsTests.swift`.
        return total + max(0, 40 - haystack.count)
    }

    private static func isBoundary(_ character: Character) -> Bool {
        character == "/" || character == "_" || character == "-" || character == "." || character == " "
    }
}

/// The list of files Baton offers for `@mention`, cached per workspace.
///
/// `git ls-files` is fast but not free, and it is asked for again on every character typed after
/// the `@`. Thirty seconds is long enough that a burst of typing costs one process, and short
/// enough that a file added a moment ago shows up without restarting anything.
actor FileIndex {
    static let shared = FileIndex()

    private struct Entry {
        var paths: [String]
        var loadedAt: Date
    }

    private var cache: [String: Entry] = [:]
    private var inFlight: [String: Task<[String], Never>] = [:]

    private let lifetime: TimeInterval = 30

    func files(workspacePath: String) async -> [String] {
        if let entry = cache[workspacePath], Date().timeIntervalSince(entry.loadedAt) < lifetime {
            return entry.paths
        }
        if let running = inFlight[workspacePath] {
            return await running.value
        }

        let task = Task<[String], Never> {
            let result = try? await Shell.run(
                "git",
                ["ls-files", "--cached", "--others", "--exclude-standard"],
                cwd: workspacePath,
                timeout: .seconds(10)
            )
            return result?.lines ?? []
        }
        inFlight[workspacePath] = task
        let paths = await task.value
        inFlight[workspacePath] = nil
        cache[workspacePath] = Entry(paths: paths, loadedAt: Date())
        return paths
    }

    /// Called after a turn finishes, when the agent may have created files.
    func invalidate(workspacePath: String) {
        cache[workspacePath] = nil
    }
}

/// The panel that drops above the composer while the user is typing an `@mention`.
///
/// It renders and nothing else. Selection and the arrow keys live in `ComposerView`, because the
/// text view keeps first responder the whole time and is the only thing that sees the key events.
struct FileMentionMenu: View {
    var matches: [FileMatch]
    var query: String
    var selectedIndex: Int
    var onPick: @MainActor (FileMatch) -> Void
    var onHighlight: @MainActor (Int) -> Void = { _ in }

    @State private var hoveredIndex: Int?

    var body: some View {
        MenuPanel {
            if matches.isEmpty {
                MenuEmptyRow(text: query.isEmpty ? "No files in this workspace" : "No file matches \(query)")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(matches.enumerated()), id: \.element.id) { index, match in
                                row(match, index: index)
                                    .id(index)
                            }
                        }
                        .padding(4)
                    }
                    .frame(maxHeight: 240)
                    .onChange(of: selectedIndex) { _, index in
                        proxy.scrollTo(index, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func row(_ match: FileMatch, index: Int) -> some View {
        HStack(spacing: 6) {
            Text(match.fileName)
                .font(Typo.bodyEmphasis)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
            Text(match.directory)
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: Metrics.rowHeight)
        .contentShape(Rectangle())
        .rowBackground(isSelected: index == selectedIndex, isHovered: index == hoveredIndex)
        .onHover { hovering in
            hoveredIndex = hovering ? index : (hoveredIndex == index ? nil : hoveredIndex)
            if hovering { onHighlight(index) }
        }
        .onTapGesture { onPick(match) }
    }
}

// MARK: - Shared menu chrome

/// The floating card both composer menus sit in. One definition so the slash menu and the file
/// menu cannot drift apart.
struct MenuPanel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .frame(width: 420, alignment: .leading)
        // The panel floats outside the composer, so it must size itself from its rows rather
        // than from the space the composer happens to occupy.
        .fixedSize(horizontal: false, vertical: true)
        .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: Metrics.corner))
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.corner)
                .stroke(Palette.border, lineWidth: Metrics.hairline)
        }
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
    }
}

struct MenuEmptyRow: View {
    var text: String

    var body: some View {
        Text(text)
            .font(Typo.label)
            .foregroundStyle(Palette.textTertiary)
            .padding(.horizontal, 12)
            .frame(height: 34)
    }
}
