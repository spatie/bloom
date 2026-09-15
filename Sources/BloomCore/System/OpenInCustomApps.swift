import Foundation

/// The applications the user has added to the "Open in" menus themselves.
///
/// `EditorCatalog` is a curated list and says why: the system's own register of handlers is
/// noise, and one addition from the system, the default handler for a file type, is the only
/// thing that reaches the menu uncurated. That addition cannot reach a folder, because the
/// handler for a folder is Finder on every Mac. So a git client the catalogue has not heard of
/// had no way into "Open Worktree in" at all, and the person who uses it every day could see the
/// four it does list and not theirs. This is the way in: a bundle chosen from a file panel, held
/// here, and merged after the catalogue by `EditorCatalog.catalogue(adding:)`.
///
/// User defaults rather than the store, for the reason `OpenInPreferences` sits there: it is
/// read while a menu is being built, which is synchronous, and a fact about how one person likes
/// to work rather than about any project. The same defaults domain, so the dev copy of Bloom
/// keeps its own list.
///
/// `@unchecked Sendable` for the same reason as `OpenInPreferences`: `UserDefaults` is thread safe
/// and not annotated as such, and there is no other state here.
public struct OpenInCustomApps: @unchecked Sendable {
    public static let key = "openIn.customApps"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// What is written to disk for one application, kept apart from `ExternalApp` on purpose.
    ///
    /// Encoding `ExternalApp` itself tied the stored shape to every stored property of a type the
    /// catalogue changes whenever it needs to, and a list that fails to decode reads as empty and
    /// is then written over by the next add. Only what a user's addition can actually have is
    /// here, and it changes only when this file says so.
    private struct Stored: Codable {
        let bundleID: String
        let name: String
        let targets: Int
        let fileName: String

        init(_ app: ExternalApp) {
            bundleID = app.bundleID
            name = app.name
            targets = app.targets.rawValue
            fileName = app.fileName
        }

        var app: ExternalApp {
            ExternalApp(bundleID: bundleID, name: name, targets: OpenTargets(rawValue: targets), fileName: fileName)
        }
    }

    /// In the order they were added, which is the order the menu shows them in after the
    /// catalogue. A value that cannot be decoded reads as empty rather than failing: the only
    /// writer is `apps`'s setter, so that is a corrupt preferences file and not a case worth a
    /// second code path.
    public var apps: [ExternalApp] {
        get {
            guard let data = defaults.data(forKey: Self.key) else { return [] }
            return ((try? JSONDecoder().decode([Stored].self, from: data)) ?? []).map(\.app)
        }
        nonmutating set {
            if newValue.isEmpty {
                defaults.removeObject(forKey: Self.key)
            } else if let data = try? JSONEncoder().encode(newValue.map(Stored.init)) {
                defaults.set(data, forKey: Self.key)
            }
        }
    }

    /// Why an application was not added.
    public enum Refusal: Equatable, Sendable {
        /// The catalogue already lists it, under this identifier or one of its variants, so it is
        /// in every menu already and adding it would draw it twice.
        case alreadyInCatalogue(name: String)
        case alreadyAdded
    }

    /// Adds an application, or says why not.
    ///
    /// The refusals are answered here rather than in the pane so the pane cannot get them wrong,
    /// and so the reason can be shown: "GitKraken is already in the menu" is a better answer to a
    /// click than a list that does not change.
    @discardableResult
    public func add(_ app: ExternalApp) -> Refusal? {
        if let owner = EditorCatalog.owner(ofBundleID: app.bundleID) {
            return .alreadyInCatalogue(name: owner.name)
        }
        var current = apps
        if current.contains(where: { $0.bundleID.caseInsensitiveCompare(app.bundleID) == .orderedSame }) {
            return .alreadyAdded
        }
        current.append(app)
        apps = current
        return nil
    }

    public func remove(bundleID: String) {
        apps = apps.filter { $0.bundleID.caseInsensitiveCompare(bundleID) != .orderedSame }
    }

    /// Changes what an application is offered for, leaving everything else about it alone.
    ///
    /// A picker's answer rather than a second add, so the application keeps its place in the
    /// list: a row that jumped to the bottom when its picker was changed would be the reorder
    /// `EditorCatalog.ordered` refuses to do.
    public func setTargets(_ targets: OpenTargets, forBundleID bundleID: String) {
        apps = apps.map { app in
            guard app.bundleID.caseInsensitiveCompare(bundleID) == .orderedSame else { return app }
            return ExternalApp(bundleID: app.bundleID, name: app.name, targets: targets, fileName: app.fileName)
        }
    }
}
