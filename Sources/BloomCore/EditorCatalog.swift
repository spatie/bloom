import Foundation

/// What an application can usefully be handed.
///
/// The distinction is not pedantry. Ghostty opens a folder and gives you a shell in it; handed a
/// single `.php` file it has nothing sensible to do. Xcode is the other way round for a loose file
/// outside a project. A menu that offers both without saying which is which is a menu that
/// sometimes does nothing when it is clicked.
public struct OpenTargets: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let file = OpenTargets(rawValue: 1 << 0)
    public static let folder = OpenTargets(rawValue: 1 << 1)
    public static let both: OpenTargets = [.file, .folder]
}

/// One application Bloom knows how to hand a path to.
///
/// Identified by bundle id rather than by path, because the path is the one thing about an
/// installed application that is not knowable in advance: Setapp keeps its copies inside its own
/// container, a homebrew cask can land in `~/Applications`, and plenty of people keep their
/// editors somewhere else entirely. LaunchServices knows where all of them are, and answers by
/// bundle id.
public struct ExternalApp: Identifiable, Sendable, Hashable {
    public var id: String { bundleID }
    public let bundleID: String
    /// What to call it in the menu. The bundle's own name is used for anything not on this list.
    public let name: String
    public let targets: OpenTargets
    /// What the bundle is called on disk, for the one case LaunchServices cannot answer.
    ///
    /// Almost always the name with `.app` after it, which is why it is derived rather than typed
    /// out thirty-four times. See `EditorCatalog` for when a path is looked at at all.
    public let fileName: String

    public init(bundleID: String, name: String, targets: OpenTargets, fileName: String? = nil) {
        self.bundleID = bundleID
        self.name = name
        self.targets = targets
        self.fileName = fileName ?? "\(name).app"
    }

    public func opens(_ target: OpenTargets) -> Bool { targets.contains(target) }
}

/// The applications a developer might reasonably want a file or a worktree opened in.
///
/// # Why a curated list rather than whatever the system reports
///
/// `NSWorkspace.urlsForApplications(toOpen:)` answers with every registered handler for a file
/// type, and for a `.php` file on a normal Mac that is PhpStorm and VS Code, but also Safari,
/// Preview, TextEdit, Xcode and anything that ever claimed a text UTI. That list is not wrong, it
/// is just not a list of places you would deliberately open code, and a menu of nine items where
/// six are noise is worse than no menu.
///
/// So the shape is: a curated list of tools, each resolved through LaunchServices by bundle id so
/// wherever the user actually keeps it is where it is found, plus one addition made by the system
/// rather than by this file. See `EditorCatalog.knownIDs` and the app layer's use of
/// `NSWorkspace.urlForApplication(toOpen:)`: the single application the user has themselves set as
/// the default for this kind of file is worth offering even when it is not on this list, because
/// the user chose it. The full registry is not, because nobody chose it.
///
/// # Why a path is looked at at all
///
/// LaunchServices is asked first and is usually right, but it is not always right: on the machine
/// this was written on it answers `nil` for `com.apple.dt.Xcode` while `/Applications/Xcode.app` is
/// sitting there, because its registration for that bundle has gone. An "Open in" menu with no
/// Xcode in it, on a Mac with Xcode installed, is a bug however defensible its cause. So anything
/// LaunchServices does not know is looked for by name in the handful of folders applications
/// actually live in, and the bundle found there is only used if its identifier is the one wanted.
/// `fileName` is what that lookup looks for.
///
/// Order is the order below and it does not change: editors, then terminals, then the git clients.
/// Only the most recently used one moves, and it moves to the top. See `ordered(_:lastUsed:)`.
public enum EditorCatalog {
    public static let known: [ExternalApp] = [
        // Editors and IDEs.
        ExternalApp(bundleID: "com.microsoft.VSCode", name: "Visual Studio Code", targets: .both),
        ExternalApp(
            bundleID: "com.microsoft.VSCodeInsiders", name: "VS Code Insiders", targets: .both,
            fileName: "Visual Studio Code - Insiders.app"
        ),
        ExternalApp(bundleID: "com.vscodium", name: "VSCodium", targets: .both),
        ExternalApp(bundleID: "com.todesktop.230313mzl4w4u92", name: "Cursor", targets: .both),
        ExternalApp(bundleID: "com.exafunction.windsurf", name: "Windsurf", targets: .both),
        ExternalApp(bundleID: "dev.zed.Zed", name: "Zed", targets: .both),
        ExternalApp(bundleID: "dev.zed.Zed-Preview", name: "Zed Preview", targets: .both),
        ExternalApp(bundleID: "com.apple.dt.Xcode", name: "Xcode", targets: .both),
        ExternalApp(bundleID: "com.jetbrains.PhpStorm", name: "PhpStorm", targets: .both),
        ExternalApp(bundleID: "com.jetbrains.WebStorm", name: "WebStorm", targets: .both),
        ExternalApp(bundleID: "com.jetbrains.intellij", name: "IntelliJ IDEA", targets: .both),
        ExternalApp(bundleID: "com.jetbrains.intellij.ce", name: "IntelliJ IDEA CE", targets: .both),
        ExternalApp(bundleID: "com.jetbrains.pycharm", name: "PyCharm", targets: .both),
        ExternalApp(bundleID: "com.jetbrains.rubymine", name: "RubyMine", targets: .both),
        ExternalApp(bundleID: "com.jetbrains.goland", name: "GoLand", targets: .both),
        ExternalApp(bundleID: "com.jetbrains.CLion", name: "CLion", targets: .both),
        ExternalApp(bundleID: "com.jetbrains.rider", name: "Rider", targets: .both),
        ExternalApp(bundleID: "com.google.android.studio", name: "Android Studio", targets: .both),
        ExternalApp(bundleID: "com.sublimetext.4", name: "Sublime Text", targets: .both),
        ExternalApp(bundleID: "com.panic.Nova", name: "Nova", targets: .both),
        ExternalApp(bundleID: "com.barebones.bbedit", name: "BBEdit", targets: .both),
        ExternalApp(bundleID: "com.macromates.TextMate", name: "TextMate", targets: .both),
        ExternalApp(bundleID: "org.gnu.Emacs", name: "Emacs", targets: .both),
        ExternalApp(bundleID: "org.vim.MacVim", name: "MacVim", targets: .both),

        // Terminals. A folder is a place to stand; a single file is not.
        ExternalApp(bundleID: "com.mitchellh.ghostty", name: "Ghostty", targets: .folder),
        ExternalApp(bundleID: "com.googlecode.iterm2", name: "iTerm", targets: .folder),
        ExternalApp(bundleID: "dev.warp.Warp-Stable", name: "Warp", targets: .folder),
        ExternalApp(bundleID: "net.kovidgoyal.kitty", name: "kitty", targets: .folder),
        ExternalApp(bundleID: "com.github.wez.wezterm", name: "WezTerm", targets: .folder),
        ExternalApp(bundleID: "com.apple.Terminal", name: "Terminal", targets: .folder),

        // Git clients, which want the repository rather than a file out of it.
        ExternalApp(bundleID: "com.github.GitHubClient", name: "GitHub Desktop", targets: .folder),
        ExternalApp(bundleID: "com.fournova.Tower3", name: "Tower", targets: .folder),
        ExternalApp(bundleID: "com.sublimemerge", name: "Sublime Merge", targets: .folder),
        ExternalApp(bundleID: "com.DanPristupov.Fork", name: "Fork", targets: .folder),
    ]

    public static let knownIDs = Set(known.map(\.bundleID))

    /// The known applications that are installed, in the catalogue's own order.
    ///
    /// `isInstalled` is the LaunchServices lookup, passed in rather than called here so this stays
    /// a pure function with a test that does not depend on what happens to be on the machine.
    public static func installed(_ isInstalled: (String) -> Bool) -> [ExternalApp] {
        known.filter { isInstalled($0.bundleID) }
    }

    /// Those of `apps` that can be handed this kind of path.
    public static func opening(_ target: OpenTargets, from apps: [ExternalApp]) -> [ExternalApp] {
        apps.filter { $0.opens(target) }
    }

    /// The menu's order: the one used last at the top, everything else exactly where it was.
    ///
    /// Deliberately not a full most-recently-used list. A menu whose whole order changes every
    /// time it is used can never be learned, and the second item is the one that would move most.
    /// One entry moving to a fixed place is a rule a person can hold: the top of this menu is
    /// always what you used last, and the rest is always the same list in the same order.
    public static func ordered(_ apps: [ExternalApp], lastUsed: String?) -> [ExternalApp] {
        guard let lastUsed, let index = apps.firstIndex(where: { $0.bundleID == lastUsed })
        else { return apps }
        var result = apps
        result.insert(result.remove(at: index), at: 0)
        return result
    }
}

/// Which application a path was last handed to.
///
/// # Per repository, falling back to whatever was used last anywhere
///
/// Globally alone would be wrong here. Somebody who writes Laravel in PhpStorm and this app in
/// Xcode switches editors when they switch project, not when they switch file, and a single global
/// memory would be wrong every time they moved between the two. Per repository alone would be
/// wrong too: a project opened for the first time has no memory, and defaulting a new project to
/// the top of an alphabetical list rather than to the editor this person always uses is a worse
/// first guess than the one we already have.
///
/// So both are recorded on every use, the repository's answer is preferred, and the global one is
/// what a project that has never been opened in anything inherits.
///
/// `@unchecked Sendable` for the same reason as `PromptOverrides`: `UserDefaults` is thread safe
/// and not annotated as such, and there is no other state here.
public struct OpenInPreferences: @unchecked Sendable {
    public static let globalKey = "openIn.lastUsed"

    public static func key(forRepo id: String) -> String { "openIn.lastUsed.\(id)" }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func lastUsed(repo: String?) -> String? {
        if let repo, let stored = defaults.string(forKey: Self.key(forRepo: repo)) { return stored }
        return defaults.string(forKey: Self.globalKey)
    }

    public func record(_ bundleID: String, repo: String?) {
        defaults.set(bundleID, forKey: Self.globalKey)
        if let repo { defaults.set(bundleID, forKey: Self.key(forRepo: repo)) }
    }
}
