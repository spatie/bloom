import SwiftUI
import AppKit
import BatonCore

/// The whole worktree, not just what changed.
///
/// `git ls-files` is asked once and turned into a directory index. Rows are then produced only
/// for directories the user actually opened, so a repository with fifty thousand files costs one
/// subprocess and a handful of views rather than a tree of fifty thousand nodes.
struct FileTreeView: View {
    let model: WorkspaceModel

    @State private var children: [String: [TreeNode]] = [:]
    @State private var expanded: Set<String> = []
    @State private var selection: String?
    @State private var hovered: String?
    @State private var isLoading = true

    struct TreeNode: Identifiable, Hashable, Sendable {
        var name: String
        var path: String
        var isDirectory: Bool

        var id: String { path }
    }

    private struct TreeRow: Identifiable {
        var node: TreeNode
        var depth: Int

        var id: String { node.path }
    }

    private struct LoadID: Hashable {
        var workspaceID: String
        var workspacePath: String
    }

    private var changedPaths: Set<String> {
        Set(model.changedFiles.map(\.path))
    }

    private var rows: [TreeRow] {
        var result: [TreeRow] = []
        append(directory: "", depth: 0, into: &result)
        return result
    }

    private func append(directory: String, depth: Int, into result: inout [TreeRow]) {
        for node in children[directory] ?? [] {
            result.append(TreeRow(node: node, depth: depth))
            if node.isDirectory, expanded.contains(node.path) {
                append(directory: node.path, depth: depth + 1, into: &result)
            }
        }
    }

    var body: some View {
        VSplitLayout(
            top: {
                tree
            },
            bottom: {
                detail
            },
            hasBottom: selection != nil
        )
        .task(id: LoadID(workspaceID: model.workspace.id, workspacePath: model.workspace.path)) {
            await load()
        }
    }

    // MARK: - Tree

    @ViewBuilder
    private var tree: some View {
        if isLoading {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if children.isEmpty {
            Text("Nothing tracked in this worktree yet")
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        treeRow(row)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func treeRow(_ row: TreeRow) -> some View {
        let node = row.node
        let isChanged = changedPaths.contains(node.path)
        let isSelected = selection == node.path

        return Button {
            if node.isDirectory {
                if expanded.contains(node.path) {
                    expanded.remove(node.path)
                } else {
                    expanded.insert(node.path)
                }
            } else {
                selection = isSelected ? nil : node.path
                if isChanged { model.selectedFilePath = node.path }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: node.isDirectory
                      ? (expanded.contains(node.path) ? "chevron.down" : "chevron.right")
                      : "doc")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Palette.textTertiary)
                    .frame(width: 10)
                Text(node.name)
                    .font(Typo.label)
                    .foregroundStyle(node.isDirectory ? Palette.textSecondary : Palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if isChanged {
                    Circle()
                        .fill(Palette.warning)
                        .frame(width: 5, height: 5)
                }
            }
            .padding(.leading, CGFloat(row.depth) * 12 + 8)
            .padding(.trailing, 8)
            .frame(height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .rowBackground(isSelected: isSelected, isHovered: hovered == node.path)
        .padding(.horizontal, 4)
        .onHover { hovering in
            hovered = hovering ? node.path : (hovered == node.path ? nil : hovered)
        }
        .contextMenu {
            Button("Open in Editor") { Reveal.inEditor(fullPath(node.path)) }
            Button("Reveal in Finder") { Reveal.inFinder(fullPath(node.path)) }
            Button("Copy path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(node.path, forType: .string)
            }
        }
        .help(node.path)
    }

    // MARK: - Detail

    /// A changed file is more usefully read as a diff, so the tree hands those to `DiffView` and
    /// only renders raw contents for files nobody has touched.
    @ViewBuilder
    private var detail: some View {
        if let selection {
            if let changed = model.changedFiles.first(where: { $0.path == selection }) {
                DiffView(model: model, file: changed)
            } else {
                FilePreview(model: model, path: selection)
            }
        }
    }

    private func fullPath(_ relative: String) -> String {
        (model.workspace.path as NSString).appendingPathComponent(relative)
    }

    // MARK: - Loading

    private func load() async {
        isLoading = true
        let worktree = model.workspace.path

        let paths = await Task.detached(priority: .userInitiated) { () -> [String] in
            let result = try? await Shell.run(
                "git",
                ["ls-files", "--cached", "--others", "--exclude-standard"],
                cwd: worktree,
                timeout: .seconds(30)
            )
            return result?.lines ?? []
        }.value

        guard !Task.isCancelled else { return }
        children = Self.index(paths)
        isLoading = false
    }

    /// One pass over the path list builds every directory's children, which is what makes
    /// expanding a folder free later on.
    static func index(_ paths: [String]) -> [String: [TreeNode]] {
        var children: [String: Set<TreeNode>] = [:]

        for path in paths where !path.isEmpty {
            let components = path.components(separatedBy: "/")
            var parent = ""
            for (offset, component) in components.enumerated() {
                let isLast = offset == components.count - 1
                let full = parent.isEmpty ? component : parent + "/" + component
                children[parent, default: []].insert(
                    TreeNode(name: component, path: full, isDirectory: !isLast)
                )
                if isLast { break }
                parent = full
            }
        }

        return children.mapValues { nodes in
            nodes.sorted {
                $0.isDirectory == $1.isDirectory
                    ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    : $0.isDirectory
            }
        }
    }
}

// MARK: - Preview of an unchanged file

/// Read-only source, highlighted with the same primitives the diff uses.
struct FilePreview: View {
    let model: WorkspaceModel
    let path: String

    /// Far more than fits on a screen, and enough that scrolling never reaches the truncation on
    /// any file a person would open on purpose.
    private static let lineLimit = 5_000

    @State private var lines: [String] = []
    @State private var carries: [LexState] = []
    @State private var language: Language = .plainText
    @State private var maxColumns = 0
    @State private var isTruncated = false
    @State private var isLoading = true

    private struct LoadID: Hashable {
        var workspaceID: String
        var path: String
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if lines.isEmpty {
                Text("Nothing to show for \((path as NSString).lastPathComponent)")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                content
            }
        }
        .background(Palette.surface)
        .task(id: LoadID(workspaceID: model.workspace.id, path: path)) { await load() }
    }

    private var content: some View {
        GeometryReader { proxy in
            let width = max(
                proxy.size.width,
                CGFloat(maxColumns) * CodeMetrics.advance + CodeMetrics.numberWidth + 24
            )
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines.indices, id: \.self) { index in
                        HStack(spacing: 0) {
                            Text("\(index + 1)")
                                .font(Typo.codeTiny)
                                .monospacedDigit()
                                .foregroundStyle(Palette.textTertiary)
                                .frame(width: CodeMetrics.numberWidth, alignment: .trailing)
                                .padding(.trailing, 6)
                                .background(Palette.diffGutter)
                            CodeText(
                                line: lines[index],
                                language: language,
                                carry: index < carries.count ? carries[index] : LexState()
                            )
                            Spacer(minLength: 0)
                        }
                        .frame(width: width, height: CodeMetrics.rowHeight, alignment: .leading)
                    }
                    if isTruncated {
                        Text("Showing the first \(Self.lineLimit) lines")
                            .font(Typo.micro)
                            .foregroundStyle(Palette.textTertiary)
                            .padding(8)
                    }
                }
                .frame(width: width, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private func load() async {
        isLoading = true
        let source = model.contents(of: path)
        let detected = Language.detect(path: path)

        guard let source else {
            lines = []
            isLoading = false
            return
        }

        let all = source.components(separatedBy: "\n")
        let truncated = all.count > Self.lineLimit
        let kept = truncated ? Array(all.prefix(Self.lineLimit)) : all

        let states = await Task.detached(priority: .userInitiated) {
            CarryPass.states(for: kept, language: detected)
        }.value

        guard !Task.isCancelled else { return }
        lines = kept
        carries = states
        language = detected
        isTruncated = truncated
        maxColumns = min(kept.reduce(0) { max($0, CodeMetrics.columns(of: $1)) }, 800)
        isLoading = false
    }
}

/// A list above and a detail below, with the list giving up room as soon as there is something
/// to show underneath it.
struct VSplitLayout<Top: View, Bottom: View>: View {
    @ViewBuilder var top: () -> Top
    @ViewBuilder var bottom: () -> Bottom
    var hasBottom: Bool

    var body: some View {
        VStack(spacing: 0) {
            top()
                .frame(maxHeight: hasBottom ? 220 : .infinity)
            if hasBottom {
                Hairline()
                bottom()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
