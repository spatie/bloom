import Foundation

// A project that is not a repository yet: where it should go, what it will be called, and whether
// the path that makes is one Bloom is willing to create.
//
// Everything in this file is pure, for the same reason `RepositoryStartPlan` is. The sheet asks
// two questions of a person, a name and a location, and answers four of its own from them: where
// to open, what the line under the field says, whether the button can be pressed and what the
// refusal reads like. Written inside the sheet, all four would be decisions nothing can look at,
// and the location one reads the owner's own disk layout, which is exactly the kind of answer that
// has to be pinned somewhere a test can reach.
//
// **`FolderVerdict` is not this rule and could not be.** It judges a folder that is there, from
// facts git and the file system already have. This judges a path that mostly is not there yet, and
// the difference is not cosmetic: the parent of a new project is usually `~/dev/code`, which
// `FolderVerdict` correctly refuses as a container of projects. So the location rules that still
// apply (Bloom's own worktrees, a repository above, the folders macOS owns) are asked here of the
// target, and the ones about what a folder holds are asked only when the folder exists.

// MARK: - What the disk says about the path being typed

/// What was found by looking for the folder a new project would live in. Gathered by
/// `NewProjectStarter.inspect`, judged by `NewProjectVerdict.of`.
public struct NewProjectFacts: Sendable, Equatable {
    /// The name as typed, untrimmed. Trimming is `NewProjectPlan.folderName`, and it happens here
    /// rather than at the field so an all-spaces name is refused rather than silently accepted.
    public var name: String
    /// The location as typed, tilde and all.
    public var location: String
    /// Location and name resolved into one absolute path. Empty when there is not enough typed to
    /// resolve one.
    public var path: String
    public var locationExists: Bool
    public var targetExists: Bool
    public var targetIsDirectory: Bool
    /// Whether the folder holds nothing worth keeping. `.DS_Store` does not count, because the
    /// Finder writes one into any folder somebody has opened and nobody means it as content.
    public var targetIsEmpty: Bool
    /// A `.git` in the target itself.
    public var targetIsRepository: Bool
    /// The repository the target would sit inside, when there is one above it.
    public var enclosingRepository: String?
    /// The deepest folder above the target that does exist, which is the one that has to be
    /// writable for anything below it to be created.
    public var nearestExistingAncestor: String
    public var isAncestorWritable: Bool
    public var homeDirectory: String
    public var workspacesRoot: String

    public init(
        name: String = "",
        location: String = "",
        path: String = "",
        locationExists: Bool = false,
        targetExists: Bool = false,
        targetIsDirectory: Bool = false,
        targetIsEmpty: Bool = false,
        targetIsRepository: Bool = false,
        enclosingRepository: String? = nil,
        nearestExistingAncestor: String = "",
        isAncestorWritable: Bool = true,
        homeDirectory: String = "",
        workspacesRoot: String = ""
    ) {
        self.name = name
        self.location = location
        self.path = path
        self.locationExists = locationExists
        self.targetExists = targetExists
        self.targetIsDirectory = targetIsDirectory
        self.targetIsEmpty = targetIsEmpty
        self.targetIsRepository = targetIsRepository
        self.enclosingRepository = enclosingRepository
        self.nearestExistingAncestor = nearestExistingAncestor
        self.isAncestorWritable = isAncestorWritable
        self.homeDirectory = homeDirectory
        self.workspacesRoot = workspacesRoot
    }
}

// MARK: - Why not

/// Why Bloom will not make a project at the path that has been typed.
///
/// Every one of these is said under the field while the person is still typing, so each names the
/// path it is about and each ends in something to do. That is the register `FolderRefusal.sentence`
/// set and it is deliberately the same one: the two lists are one policy split by which question
/// was asked, and a person who meets both should not be able to tell they came from two files.
///
/// The paths in these cases are already abbreviated for reading, because the verdict is built by
/// something that knows the home directory and the sentence is not.
public enum NewProjectRefusal: Sendable, Equatable {
    case noName
    /// A name with a path separator in it. On macOS a colon is one too: the Finder draws it as a
    /// slash and the file system takes it as a directory break.
    case nameHasSeparator(String)
    /// `.`, `..`, or anything else starting with a dot.
    case nameIsHidden(String)
    case noLocation
    case locationNotAbsolute(String)
    /// Something is there and it is not a folder.
    case somethingThere(String)
    /// The folder is there and has things in it. The one refusal that is really a redirection:
    /// the sheet that turns an existing folder into a repository is the answer, not this one.
    case folderNotEmpty(String)
    /// The folder is there and is already a repository, so it is a project waiting to be added
    /// rather than one waiting to be made.
    case alreadyRepository(String)
    case insideRepository(String)
    case insideBloomsWorkspaces(String)
    /// A folder macOS or the Finder owns.
    case reservedLocation(String)
    case notWritable(String)
}

public extension NewProjectRefusal {
    /// One sentence, said under the field. No command lines: none of these is fixed by running
    /// something, they are fixed by typing something else.
    var sentence: String {
        switch self {
        case .noName:
            "Give the project a name."
        case .nameHasSeparator:
            """
            A project's name is the name of its folder, so it cannot hold a slash or a colon. \
            Choose where it goes with the location field instead.
            """
        case .nameIsHidden:
            """
            A name starting with a dot makes a folder the Finder hides, which is not somewhere a \
            project can be worked in. Pick another name.
            """
        case .noLocation:
            "Choose where the project should live."
        case .locationNotAbsolute(let path):
            "Bloom cannot tell where '\(path)' is, because it is not a full path."
        case .somethingThere(let path):
            "There is already a file called \(path). Pick another name."
        case .folderNotEmpty(let path):
            """
            \(path) already exists and has things in it. Bloom starts a new project in a folder it \
            makes or in an empty one. Pick another name, or add that folder as a project instead.
            """
        case .alreadyRepository(let path):
            """
            \(path) is already a git repository. Add it as a project rather than creating a new \
            one over the top of it.
            """
        case .insideRepository(let root):
            """
            That location is inside the git repository at \(root). Starting another repository \
            here would nest one inside the other, which git cannot check out again. Pick a folder \
            outside it.
            """
        case .insideBloomsWorkspaces(let path):
            """
            \(path) is inside the folder Bloom cuts its own worktrees into. A project lives where \
            you keep your own work, and Bloom makes the worktrees from it.
            """
        case .reservedLocation(let path):
            """
            \(path) is one of your Mac's own folders, so a repository there would track far more \
            than a project. Pick somewhere your projects live.
            """
        case .notWritable(let path):
            "Bloom cannot write to \(path), so it cannot create the project folder there."
        }
    }
}

// MARK: - What will happen

/// What pressing Create Project would do, decided before the button can be pressed.
public enum NewProjectVerdict: Sendable, Equatable {
    /// Bloom makes the folder. `makesLocation` is true when the location above it has to be made
    /// as well, which is the ordinary first run: nobody has a `~/Developer` until something makes
    /// one.
    case create(makesLocation: Bool)
    /// The folder is already there and empty, so Bloom takes it as it is.
    ///
    /// Adopted rather than refused because an empty folder is what somebody who half started
    /// already has, most often from the file panel's own New Folder button, and refusing it would
    /// send them to the Finder to delete a folder so that Bloom could make the same one back.
    case adopt
    case refuse(NewProjectRefusal)
}

public extension NewProjectVerdict {
    /// The whole rule, from facts alone.
    ///
    /// The order is what a person would ask in: is there a name, is there a location, is the path
    /// they make somewhere Bloom is willing to work at all, and only then what is already there.
    /// The location questions come before the contents questions because a `~/Desktop/thing` that
    /// happens to be empty is still not a place for a project, and answering "that folder is
    /// empty, go ahead" first would have said so.
    static func of(_ facts: NewProjectFacts) -> NewProjectVerdict {
        let name = NewProjectPlan.folderName(from: facts.name)
        guard !name.isEmpty else { return .refuse(.noName) }
        if name.contains("/") || name.contains(":") { return .refuse(.nameHasSeparator(name)) }
        if name.hasPrefix(".") { return .refuse(.nameIsHidden(name)) }

        let location = facts.location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !location.isEmpty else { return .refuse(.noLocation) }
        guard !facts.path.isEmpty else { return .refuse(.locationNotAbsolute(location)) }

        func shown(_ path: String) -> String {
            NewProjectPlan.display(path, home: facts.homeDirectory)
        }

        if FolderPath.isInside(facts.path, of: facts.workspacesRoot) {
            return .refuse(.insideBloomsWorkspaces(shown(facts.path)))
        }
        if FolderPath.isReserved(facts.path, home: facts.homeDirectory)
            || FolderPath.sameFolder(facts.path, facts.homeDirectory) {
            return .refuse(.reservedLocation(shown(facts.path)))
        }
        if let enclosing = facts.enclosingRepository {
            return .refuse(.insideRepository(shown(enclosing)))
        }

        if facts.targetExists {
            guard facts.targetIsDirectory else { return .refuse(.somethingThere(shown(facts.path))) }
            // Asked before emptiness, because a repository is never empty and "it has things in
            // it" would be a true sentence that hid the useful one.
            if facts.targetIsRepository { return .refuse(.alreadyRepository(shown(facts.path))) }
            guard facts.targetIsEmpty else { return .refuse(.folderNotEmpty(shown(facts.path))) }
            return .adopt
        }

        guard facts.isAncestorWritable else {
            return .refuse(.notWritable(shown(facts.nearestExistingAncestor)))
        }
        return .create(makesLocation: !facts.locationExists)
    }

    /// Whether Create Project can be pressed.
    var allowsCreation: Bool {
        switch self {
        case .create, .adopt: true
        case .refuse: false
        }
    }

    /// The line under the location field. It says the whole path and then what Bloom will do to
    /// it, because the path is the part a sentence in a chat can never show and it is the only
    /// thing on this sheet that is about to be written to disk.
    func hint(path: String, home: String) -> String {
        let shown = NewProjectPlan.display(path, home: home)
        switch self {
        case .create(let makesLocation):
            return makesLocation
                ? "\(shown). Bloom will create both."
                : "\(shown). Bloom will create it."
        case .adopt:
            return "\(shown) is already there and empty, so Bloom will use it."
        case .refuse(let refusal):
            return refusal.sentence
        }
    }
}

// MARK: - The two answers Bloom fills in for you

public enum NewProjectPlan {
    /// Where a first project goes when there is nothing to learn it from.
    ///
    /// `~/Developer` rather than a name of Bloom's own choosing. It is the one folder name macOS
    /// itself gives an icon to, so it reads as a convention rather than as an app's opinion, and
    /// somebody who has never made one still recognises what it is for.
    public static let fallbackLocationName = "Developer"

    /// The location the sheet opens on: the folder the owner's projects already sit in.
    ///
    /// Counted rather than guessed, and counted off the projects Bloom already has, because the
    /// honest default for somebody who has been using Bloom for a week is the folder they have
    /// been using for a week. Three projects under `~/dev/code` and one under `~/scratch` means
    /// the answer is `~/dev/code` and it is right the first time.
    ///
    /// Ties go to the parent that came first, which is the order the sidebar is in, so the answer
    /// does not move about between two folders holding one project each.
    ///
    /// The volume root is skipped: a repository directly under `/` is somebody's unusual choice
    /// and never the folder they keep projects in.
    public static func suggestedLocation(projectPaths: [String], home: String) -> String {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for path in projectPaths {
            let parent = (FolderPath.normalize(path) as NSString).deletingLastPathComponent
            guard parent.count > 1 else { continue }
            if counts[parent] == nil { order.append(parent) }
            counts[parent, default: 0] += 1
        }
        let commonest = order.max { (counts[$0] ?? 0) < (counts[$1] ?? 0) }
        return commonest ?? (FolderPath.normalize(home) as NSString)
            .appendingPathComponent(fallbackLocationName)
    }

    /// The name as a folder name: trimmed, and nothing else.
    ///
    /// Deliberately not sanitised. `GitHubRepositoryName.suggestion` rewrites a name because
    /// GitHub will refuse one it does not like; a folder on this Mac takes almost anything, and
    /// silently turning "my app" into "my-app" would name a folder something the person did not
    /// type and would then say so in a line they had stopped reading. The two names it cannot be
    /// are refused instead, out loud.
    public static func folderName(from typed: String) -> String {
        typed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Location and name as one absolute path, or nil when the location is not one Bloom can place.
    public static func target(name: String, location: String, home: String) -> String? {
        let folder = folderName(from: name)
        guard !folder.isEmpty, !folder.contains("/") else { return nil }
        let trimmed = location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = expand(trimmed, home: home)
        guard expanded.hasPrefix("/") else { return nil }
        return (FolderPath.normalize(expanded) as NSString).appendingPathComponent(folder)
    }

    /// A tilde in a typed location expanded against a home this function was told about, rather
    /// than against the one `expandingTildeInPath` reads out of the process. The suite has to be
    /// able to ask this about a machine that is not the one running it.
    public static func expand(_ path: String, home: String) -> String {
        let home = FolderPath.normalize(home)
        if path == "~" { return home }
        guard path.hasPrefix("~/") else { return path }
        return home + String(path.dropFirst(1))
    }

    /// A path as it is shown to a person: under the home directory it wears a tilde, because
    /// `~/Developer/sparkline` is read at a glance and `/Users/freek/Developer/sparkline` is read
    /// twice.
    public static func display(_ path: String, home: String) -> String {
        let home = FolderPath.normalize(home)
        let normalized = FolderPath.normalize(path)
        guard !home.isEmpty, normalized == home || normalized.hasPrefix(home + "/") else {
            return normalized
        }
        return "~" + normalized.dropFirst(home.count)
    }
}
