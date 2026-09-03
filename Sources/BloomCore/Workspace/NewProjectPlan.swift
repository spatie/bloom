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
//
// **Which is why this rule is now asked only of a target with nothing at it, or an empty folder.**
// `ProjectTargetVerdict` is the one caller, and it asks what a folder holds first. Two refusals
// used to live here that were not about the disk at all: a folder that was already a repository,
// and a folder with files in it. Both of their sentences ended by telling the person to close the
// window and come in through the other door, and there is one door now, so a repository is Add and
// a folder with work in it is Start Tracking. Retiring them is what the unification looks like
// from in here.

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
    /// Whether the target itself can be written to, which is a different question from the one
    /// above and is the one that matters once the folder is already there: `git init` writes
    /// inside it.
    public var isTargetWritable: Bool
    public var homeDirectory: String
    public var workspacesRoot: String
    /// Direct children of the target that are repositories of their own. Gathered only for a
    /// folder that is there and has something in it, because it answers one question and it is
    /// `FolderVerdict`'s: a folder holding three of these is somebody's projects directory.
    public var childRepositories: [String]

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
        isTargetWritable: Bool = true,
        homeDirectory: String = "",
        workspacesRoot: String = "",
        childRepositories: [String] = []
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
        self.isTargetWritable = isTargetWritable
        self.homeDirectory = homeDirectory
        self.workspacesRoot = workspacesRoot
        self.childRepositories = childRepositories
    }
}

extension NewProjectFacts {
    /// The same target, put to the rule that judges a folder that is there.
    ///
    /// **`isRepository` here means a `.git` in this very folder, and not git's own answer.** The
    /// facts are gathered while somebody is typing, so they cost no subprocess, and a walk up the
    /// tree with `FileManager` cannot tell a work tree from a folder that merely sits inside one.
    /// That is the honest answer anyway for a window that has to say what it will do to the path
    /// in front of it: `~/dev/code/bloom/Tools` is refused for being inside a repository, with the
    /// repository offered as the way out, rather than silently adding a project the person did not
    /// type.
    var folderFacts: FolderFacts {
        FolderFacts(
            path: path,
            isRepository: targetIsRepository,
            repositoryRoot: targetIsRepository ? path : nil,
            enclosingRepository: targetIsRepository ? nil : enclosingRepository,
            isWritable: isTargetWritable,
            isDirectory: targetIsDirectory,
            exists: targetExists,
            isAbsolute: !path.isEmpty,
            homeDirectory: homeDirectory,
            workspacesRoot: workspacesRoot,
            childRepositories: childRepositories
        )
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
    case insideRepository(String)
    case insideBloomsWorkspaces(String)
    /// A folder macOS or the Finder owns.
    case reservedLocation(String)
    case notWritable(String)
}

public extension NewProjectRefusal {
    /// The repository to offer as the way out, where there is an obvious one.
    ///
    /// The same accessor `FolderRefusal` has, for the same case and for the same reason: the two
    /// lists are one policy and a person meeting either of them should be offered the same way
    /// out. The path is the abbreviated one carried by the case, which is what goes back into the
    /// field.
    var alternative: String? {
        guard case .insideRepository(let root) = self else { return nil }
        return root
    }

    /// One sentence, said under the field. No command lines: none of these is fixed by running
    /// something, they are fixed by typing something else.
    var sentence: String {
        switch self {
        case .noName:
            "Give the project a name."
        case .nameHasSeparator:
            """
            A project's name is the name of its folder, and macOS reads a colon in one as a slash. \
            Pick another name, or type the whole path of the folder you mean.
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
        case .insideRepository(let root):
            """
            That location is inside the git repository at \(root). Starting another repository \
            here would nest one inside the other, which git cannot check out again. Add \(root) \
            instead, or pick a folder outside it.
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
    /// **Asked only of a target with nothing at it, or a folder that is there and empty.** What a
    /// folder holds is `FolderVerdict`'s question, and `ProjectTargetVerdict` asks that one first;
    /// see the head of this file for the two refusals that used to be here.
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
            // The target's own permissions rather than its parent's, because nothing is being made
            // above it: `git init` writes inside the folder that is already there.
            guard facts.isTargetWritable else { return .refuse(.notWritable(shown(facts.path))) }
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

    /// How many of the projects Bloom already has live in this folder.
    ///
    /// Said out loud in the block under the field, because "New projects go in ~/dev/code" is an
    /// assertion and "where three of your projects live" is the reason it is right. It is also the
    /// only part of the opening sentence that could be wrong on somebody else's machine.
    public static func projectsIn(_ location: String, projectPaths: [String]) -> Int {
        let folder = FolderPath.normalize(location)
        return projectPaths.count {
            (FolderPath.normalize($0) as NSString).deletingLastPathComponent == folder
        }
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
