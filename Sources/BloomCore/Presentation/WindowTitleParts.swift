import Foundation

/// The window's title and document as a time tracker reads them through Accessibility: a
/// workspace name alone does not say which project it belongs to.
public struct WindowTitleParts: Equatable, Sendable {
    public let name: String
    public let project: String?
    /// The worktree, nil when the selection is not a workspace.
    public let folder: String?

    static let separator = " · "

    public init(name: String, project: String? = nil, folder: String? = nil) {
        self.name = name
        self.project = project
        self.folder = folder
    }

    private var projectSuffix: String? {
        guard let project, !project.isEmpty, project != name else { return nil }
        return Self.separator + project
    }

    /// The window's own title: the name, then the project when it adds something.
    public var full: String {
        name + (projectSuffix ?? "")
    }

    /// The title bar's text, from the title read back off the window. Only the project comes off,
    /// so a prefix a build put in front of the title stays.
    public func drawn(from windowTitle: String) -> String {
        guard let projectSuffix, windowTitle.hasSuffix(projectSuffix) else { return windowTitle }
        return String(windowTitle.dropLast(projectSuffix.count))
    }

    /// The worktree as the file URL Accessibility expects for a window's document.
    public var documentURL: String? {
        guard let folder, !folder.isEmpty else { return nil }
        return URL(filePath: folder, directoryHint: .isDirectory).absoluteString
    }
}
