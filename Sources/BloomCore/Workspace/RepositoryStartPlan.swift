import Foundation

/// What Bloom does about a folder it has been handed, decided before anything is done to it.
///
/// Everything in this file is pure. It takes facts that were gathered by looking at the disk and
/// answers three questions: what should become of this folder, what would be committed if it
/// became a repository, and is the GitHub name the user typed a name GitHub will accept. The
/// answers are what the dialog shows, and they are what the tests pin, because the alternative is
/// a dialog whose promises are only checked by running it against somebody's home directory.
///
/// **`FolderVerdict.of` is the one rule, and both doors ask it.** The owner's file panel and
/// `project_add` over the bridge used to have a policy each, and they did not agree: the panel
/// added anything git recognised, which meant it would register one of Bloom's own worktrees or
/// a home directory somebody had run `git init` in, and the bridge refused both. Two lists of
/// refusals maintained apart is the shape of that bug, so there is one list now. What genuinely
/// differs is how a refusal reads, which is `sentence` for a person in front of a file panel and
/// `agentSentence` for a caller that needs to be told whether retrying helps.

// MARK: - What the folder is

/// What was found by looking at a folder, with no judgement attached yet.
public struct FolderFacts: Sendable, Equatable {
    public var path: String
    /// Git already answers yes here. `git rev-parse --is-inside-work-tree` is true for a
    /// subdirectory too, so this covers "the folder is a repository" and "the folder is part of
    /// one" at the same time.
    public var isRepository: Bool
    /// The top level of the repository this folder is part of, when it is part of one.
    ///
    /// Where the location rules are applied, because `~/bloom/workspaces/x/src` is inside one of
    /// Bloom's worktrees exactly as much as `~/bloom/workspaces/x` is, and only the top level
    /// says so. Nil falls back to `path`, which is what it is for a folder that is not a
    /// repository and what it was for every caller before the top level was gathered.
    public var repositoryRoot: String?
    /// The top level of a repository this folder sits inside, when it sits inside one without
    /// being part of its work tree. Rare, and worth refusing over rather than nesting.
    public var enclosingRepository: String?
    public var isWritable: Bool
    public var isDirectory: Bool
    /// Whether anything is at the path at all. Split from `isDirectory` because "there is nothing
    /// there" and "there is a file there" are different mistakes and want different answers: one
    /// is a wrong path and the other is the right path with the wrong last component.
    public var exists: Bool
    /// Whether the caller gave a path that means something on its own.
    ///
    /// Always true for the file panel, which cannot produce anything else. False is reachable
    /// only from a caller that typed a path, and it matters there because Bloom's working
    /// directory is not the caller's.
    public var isAbsolute: Bool
    /// The user's home, passed in rather than read, so the rule can be tested on any machine.
    public var homeDirectory: String
    /// Where Bloom cuts its own worktrees, passed in for the same reason.
    public var workspacesRoot: String
    /// Direct children that are themselves git repositories, by name. A folder full of these is
    /// somebody's projects directory, not a project.
    public var childRepositories: [String]

    public init(
        path: String,
        isRepository: Bool,
        repositoryRoot: String? = nil,
        enclosingRepository: String? = nil,
        isWritable: Bool = true,
        isDirectory: Bool = true,
        exists: Bool = true,
        isAbsolute: Bool = true,
        homeDirectory: String,
        workspacesRoot: String = WorkspaceManager.workspacesRoot.path,
        childRepositories: [String] = []
    ) {
        self.path = path
        self.isRepository = isRepository
        self.repositoryRoot = repositoryRoot
        self.enclosingRepository = enclosingRepository
        self.isWritable = isWritable
        self.isDirectory = isDirectory
        self.exists = exists
        self.isAbsolute = isAbsolute
        self.homeDirectory = homeDirectory
        self.workspacesRoot = workspacesRoot
        self.childRepositories = childRepositories
    }
}

/// Why Bloom will not take a particular folder, whether it was asked to register one or to make
/// one.
///
/// A refusal rather than a warning in every case here, because all of them leave the owner with
/// something wrong in a way they would have to undo by hand, and none of them is something a
/// person means to do. Somebody who genuinely wants `git init` in their home directory can still
/// run `git init` in their home directory.
///
/// The first five are about a path that was never going to work. The next three refuse a
/// repository that exists but is not a project. The last four refuse making a repository out of a
/// folder that is not one. Which of them a given caller can reach is `FolderVerdict.of`'s
/// business and not this type's.
public enum FolderRefusal: Sendable, Equatable {
    /// A path that means nothing on its own. Bloom's working directory is not the caller's.
    case notAbsolute(String)
    /// Nothing at that path.
    case nothingThere(String)
    case notADirectory(String)

    /// A worktree Bloom cut itself. Registering one would make Bloom cut worktrees of a worktree.
    case insideBloomsWorkspaces(String)
    /// The root of the volume. A repository on some machines, and a project on none.
    case volumeRoot
    /// The home directory. Refused whether or not it already is a repository: it is one on plenty
    /// of machines and it is nobody's project.
    case homeDirectory

    /// The folder is inside another repository. Initialising here would nest one repository in
    /// another, and git commits the inner one as an unusable gitlink.
    case insideRepository(String)
    /// A folder macOS owns, or one the system puts things in.
    case systemDirectory
    case notWritable
    /// A container of other people's repositories. Carries what it found so the sentence can name
    /// them rather than assert.
    case containerOfProjects([String])
}

public extension FolderRefusal {
    /// How many sibling repositories make a folder a container of projects rather than a project.
    ///
    /// Two is survivable: a project can legitimately keep a vendored checkout or an example app
    /// beside it. Three is a pattern, and the folder is somebody's `~/dev`. Conductor offers to
    /// publish exactly that folder, `freekmurze/code`, which would push every project on the
    /// machine into one repository.
    static let projectContainerThreshold = 3

    /// What to put in front of a person. No command lines: none of these are fixed by running
    /// something, they are fixed by choosing a different folder.
    ///
    /// A person gets a short sentence because the window they are standing in front of can offer
    /// them the file panel again, and because they can see the folder they picked. See
    /// `agentSentence` for the other half of the same refusal.
    var sentence: String {
        switch self {
        case .notAbsolute(let path):
            "Bloom cannot tell where '\(path)' is, because it is not a full path."
        case .nothingThere:
            "There is nothing at that path any more."
        case .notADirectory:
            "That is not a folder."
        case .insideBloomsWorkspaces(let path):
            """
            \(path) is one of Bloom's own workspaces, which is a worktree of a project Bloom \
            already has. Add the project it was cut from instead.
            """
        case .volumeRoot:
            """
            This is the root of the volume. Even where that is a git repository it is not one \
            project. Pick the project folder itself.
            """
        case .insideRepository(let root):
            """
            This folder is already inside the git repository at \(root). Starting another \
            repository here would nest one inside the other, which git cannot check out again. \
            Add \(root) instead, or pick a folder outside it.
            """
        case .homeDirectory:
            """
            This is your home folder. A repository here would track every file on your account, \
            including your keys and your mail. Pick the project folder itself.
            """
        case .systemDirectory:
            """
            This folder belongs to macOS or holds unrelated things. A repository here would track \
            all of it. Pick the project folder itself.
            """
        case .notWritable:
            "Bloom cannot write to this folder, so it cannot create a repository in it."
        case .containerOfProjects(let names):
            """
            This folder holds \(Self.list(names)), which are repositories of their own. It is a \
            folder of projects rather than a project. Pick one of them instead.
            """
        }
    }

    /// The repository to offer as the alternative, when there is an obvious one.
    var alternative: String? {
        guard case .insideRepository(let root) = self else { return nil }
        return root
    }

    /// The same refusal, said to a caller that has no window.
    ///
    /// Same policy, different audience, and the differences are all presentation. A person is
    /// looking at the folder they picked and can pick another; a client cannot see the disk, has
    /// only what it typed, and will act on whatever this says. So each of these names the path in
    /// full, says whether trying again would help, and says what to do instead.
    ///
    /// The one that matters most is the folder that is not a repository, which is `FolderVerdict`
    /// `.offer` rather than a refusal and is `notARepositoryForAgent` below. **An agent reads "set
    /// my projects up" as permission to run `git init`**, and handed a bare "not a git repository"
    /// it will helpfully make one, in a folder the owner never meant to be a repository, with
    /// whatever happens to be lying in it as the first commit. Every sentence here that could be
    /// answered by creating a repository says out loud that creating it is not the caller's to do.
    ///
    /// Nothing here quotes a command line, and the only paths it quotes are ones the caller
    /// handed in.
    var agentSentence: String {
        switch self {
        case .notAbsolute(let path):
            """
            Bloom will not add '\(path)' as a project because it is not an absolute path. Bloom \
            is a separate application and its working directory is not yours, so a relative path \
            points somewhere neither of us can agree on. Ask again with the full path, starting \
            at / or ~.
            """

        case .nothingThere(let path):
            """
            Bloom will not add \(path) as a project because there is nothing at that path. Check \
            where the repository actually is and ask again with the right path. If you were \
            guessing, stop guessing and ask the owner.
            """

        case .notADirectory(let path):
            """
            Bloom will not add \(path) as a project because it is a file, not a folder. A project \
            is the folder holding the repository. Ask again with the folder it is in.
            """

        case .insideBloomsWorkspaces(let path):
            """
            Bloom will not add \(path) as a project because it is one of Bloom's own workspaces. \
            A workspace is a worktree Bloom already cut from a project it already has, so adding \
            it would give Bloom a project whose workspaces are worktrees of a worktree. Add the \
            repository it was cut from instead, if that is not already a project.
            """

        case .volumeRoot:
            Self.tooBroad("the root of the volume")

        case .homeDirectory:
            Self.tooBroad("your whole home folder")

        case .insideRepository(let root):
            """
            Bloom will not add that folder as a project because it sits inside the repository at \
            \(root) without being part of it. Ask again with \(root), if that is not already a \
            project. Do not run git init to make this call succeed: whether a folder should be a \
            repository is the owner's decision.
            """

        case .systemDirectory:
            """
            Bloom will not add that folder as a project because it belongs to macOS or holds \
            unrelated things, and it is not a git repository either. Retrying will not help and \
            neither will running git init: turning a folder into a repository is the owner's \
            decision. Ask again with the folder of the actual repository you meant.
            """

        case .notWritable:
            """
            Bloom will not add that folder as a project. It is not a git repository, and Bloom \
            cannot write to it either, so retrying will not help and neither will running git \
            init. Check the path with the owner.
            """

        case .containerOfProjects(let names):
            """
            Bloom will not add that folder as a project because it holds \(Self.list(names)), \
            which are repositories of their own, and is not a repository itself. It is a folder \
            of projects rather than a project. Ask again with one of them, and do not run git \
            init here: that would put every project on the machine into one repository.
            """
        }
    }

    /// What a caller with no window is told about a folder git does not recognise.
    ///
    /// Not a `FolderRefusal`, because to the owner it is not a refusal at all: the app offers to
    /// make the repository, with the owner in front of the offer. The bridge does not get a
    /// shortcut past that sheet, so the same verdict reads as a refusal here. See
    /// `agentSentence`.
    static func notARepositoryForAgent(path: String) -> String {
        """
        Bloom will not add \(path) as a project because git does not recognise it as a \
        repository. Bloom registers repositories that already exist and it does not create them, \
        so retrying will not help and neither will running git init: turning a folder into a \
        repository is the owner's decision and not something to do on their behalf while tidying \
        up a project list. If this folder should be a repository, say so and let the owner make \
        it one.
        """
    }

    private static func tooBroad(_ what: String) -> String {
        """
        Bloom will not add that folder as a project because it is \(what). Even where that is a \
        git repository it is not one project, and every workspace cut from it would carry \
        everything inside it. Ask again with the folder of the actual repository you meant.
        """
    }

    private static func list(_ names: [String]) -> String {
        let shown = names.prefix(3).joined(separator: ", ")
        guard names.count > 3 else { return shown }
        return "\(shown) and \(names.count - 3) more"
    }
}

/// What Bloom will do about a folder that was handed to it.
public enum FolderVerdict: Sendable, Equatable {
    /// Register the repository at `root`. The path handed in may have been a folder inside it.
    case alreadyRepository(root: String)
    case refuse(FolderRefusal)
    /// It is not a repository, and it could reasonably become one. The app offers the owner the
    /// sheet; a caller with no window is refused, because turning a folder into a repository is a
    /// decision the owner makes in front of it. See `FolderRefusal.notARepositoryForAgent`.
    case offer
}

public extension FolderVerdict {
    /// The whole rule, in one place, from facts alone.
    ///
    /// The order is the order a person would ask in: is this even a path, is anything there, is
    /// it a folder, and only then the two branches. A folder git already recognises is asked the
    /// three questions about *where* it is, because a repository can exist in a place that is
    /// still not a project. A folder git does not recognise is asked whether it should become
    /// one.
    ///
    /// **The location questions used to be asked of one branch only**, which meant the file panel
    /// would register one of Bloom's own worktrees, or a home directory somebody had run
    /// `git init` in, while `project_add` refused both. They are asked of the resolved top level
    /// rather than of the path handed in, because `~/bloom/workspaces/x/src` is inside a worktree
    /// exactly as much as `~/bloom/workspaces/x` is and git resolves either.
    static func of(_ facts: FolderFacts) -> FolderVerdict {
        guard facts.isAbsolute else { return .refuse(.notAbsolute(facts.path)) }
        guard facts.exists else { return .refuse(.nothingThere(facts.path)) }
        guard facts.isDirectory else { return .refuse(.notADirectory(facts.path)) }

        if facts.isRepository {
            // Git's own answer, carried through untouched. `normalize` strips a `/private` prefix
            // on this machine, and the row `Store` writes holds what git said, so a normalised
            // root would look up nothing and every second `project_add` would report itself as
            // the first. Normalising is for the comparisons below and for nothing else.
            let root = facts.repositoryRoot ?? facts.path
            if FolderPath.isInside(root, of: facts.workspacesRoot) {
                return .refuse(.insideBloomsWorkspaces(root))
            }
            if FolderPath.sameFolder(root, facts.homeDirectory) { return .refuse(.homeDirectory) }
            if FolderPath.normalize(root) == "/" { return .refuse(.volumeRoot) }
            return .alreadyRepository(root: root)
        }

        if let enclosing = facts.enclosingRepository { return .refuse(.insideRepository(enclosing)) }

        let path = FolderPath.normalize(facts.path)
        if FolderPath.sameFolder(path, facts.homeDirectory) { return .refuse(.homeDirectory) }
        if FolderPath.isReserved(path, home: facts.homeDirectory) { return .refuse(.systemDirectory) }
        guard facts.isWritable else { return .refuse(.notWritable) }

        if facts.childRepositories.count >= FolderRefusal.projectContainerThreshold {
            return .refuse(.containerOfProjects(facts.childRepositories.sorted()))
        }
        return .offer
    }
}

/// Path rules kept apart from the verdict so they can be read and tested on their own.
public enum FolderPath {
    /// Trailing slashes and `.` components removed, so `/Users/x/` and `/Users/x` are one folder.
    /// Deliberately not `standardizedFileURL`, which touches the disk to resolve symlinks.
    public static func normalize(_ path: String) -> String {
        let collapsed = (path as NSString).standardizingPath
        guard collapsed.count > 1, collapsed.hasSuffix("/") else { return collapsed }
        return String(collapsed.dropLast())
    }

    /// The same folder, resolving symlinks, for the two questions that cannot be answered without
    /// touching the disk.
    ///
    /// Kept apart from `normalize` rather than folded into it. `normalize` is used while a person
    /// is choosing a folder and must not go to the file system for every keystroke; these two are
    /// asked once, when something is about to be registered.
    public static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: normalize((path as NSString).expandingTildeInPath))
            .resolvingSymlinksInPath().path
    }

    /// Whether two paths name the same folder.
    ///
    /// Compared both ways because the cheap answer is right nearly always and the expensive one
    /// is right for the rest: a caller passing a home directory that happens to be reached
    /// through a symlink would otherwise slip past the rule that refuses it.
    public static func sameFolder(_ one: String, _ other: String) -> Bool {
        normalize(one) == normalize(other) || resolved(one) == resolved(other)
    }

    /// Whether `path` is `root` or sits under it. Compared as path components rather than as a
    /// string prefix, so `~/bloom/workspaces-old` is not read as being inside `~/bloom/workspaces`.
    ///
    /// Symlinks are resolved on both sides first, and that is not tidiness. `git rev-parse
    /// --show-toplevel` answers with the resolved path, so the top level of a worktree under a
    /// symlinked workspaces root comes back pointing at the real directory and matched nothing at
    /// all against the unresolved root. On this machine `/tmp` is a symlink to `/private/tmp`,
    /// which is where the test suite works, so the check passed everywhere except where it had to
    /// hold.
    public static func isInside(_ path: String, of root: String) -> Bool {
        let one = resolved(path)
        let other = resolved(root)
        return one == other || one.hasPrefix(other + "/")
    }

    /// Folders nobody means to turn into a repository.
    ///
    /// Three different shapes, because one blanket rule got it wrong in both directions. Refusing
    /// a whole subtree is right for the parts of the disk macOS owns and wrong for `/tmp`, where
    /// a scratch repository is an entirely reasonable thing to want. Refusing only exact matches
    /// is right for `/tmp` and wrong for `/Volumes`, where one level down is a whole mounted disk.
    public static func isReserved(_ path: String, home: String) -> Bool {
        let normalized = normalize(path)

        if ownedTrees.contains(normalized) { return true }
        for tree in ownedTrees where normalized.hasPrefix(tree + "/") { return true }

        if containerRoots.contains(normalized) { return true }
        // One level under a container root is an application bundle, a mounted volume or another
        // account's home directory. All three are containers themselves.
        let parent = (normalized as NSString).deletingLastPathComponent
        if containerRoots.contains(parent) { return true }

        if bareRoots.contains(normalized) { return true }

        let normalizedHome = normalize(home)
        return reservedHomeChildren.contains { normalized == normalizedHome + "/" + $0 }
    }

    /// Owned by macOS from the top down. Nothing anywhere inside these is somebody's project.
    static let ownedTrees: Set<String> = [
        "/System", "/Library", "/bin", "/sbin", "/usr", "/etc", "/dev", "/cores",
    ]

    /// Containers whose immediate children are containers too.
    static let containerRoots: Set<String> = ["/Applications", "/Users", "/Volumes"]

    /// Refused as themselves, while what is inside them stays the user's business. `/tmp/scratch`
    /// is exactly the kind of folder a local repository is the right answer for.
    static let bareRoots: Set<String> = ["/", "/opt", "/private", "/tmp", "/var"]

    static let reservedHomeChildren: Set<String> = [
        "Applications", "Desktop", "Documents", "Downloads", "Library", "Movies", "Music",
        "Pictures", "Public",
    ]
}

// MARK: - What would be committed

/// A file that will be kept out of the first commit, and why.
public struct ExcludedPath: Sendable, Equatable, Identifiable {
    public enum Reason: Sendable, Equatable {
        /// Looks like it holds a credential.
        case sensitive
        /// A git repository of its own. Committed as-is it becomes a gitlink with no submodule
        /// behind it, which checks out as an empty directory in every worktree.
        case nestedRepository
    }

    public var path: String
    public var reason: Reason

    public var id: String { path }

    public init(path: String, reason: Reason) {
        self.path = path
        self.reason = reason
    }

    /// The line to write into `.gitignore`. Anchored to the root and escaped, so a file called
    /// `#notes` or `foo[1].env` means itself rather than a comment or a character class.
    public var gitignoreLine: String {
        var escaped = ""
        for character in path {
            if "*?[]\\ ".contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return "/" + escaped + (reason == .nestedRepository ? "/" : "")
    }
}

/// What a folder holds, as far as a first commit is concerned.
public struct FolderContents: Sendable, Equatable {
    /// How many files the walk saw, not counting anything under an excluded path.
    public var fileCount: Int
    public var byteSize: Int64
    /// The walk stopped early. Every count here is a floor, not a total.
    public var truncated: Bool
    public var hasGitignore: Bool
    public var excluded: [ExcludedPath]
    /// Files GitHub will not accept. Carried separately because they fail the push rather than
    /// the commit, which is a different sentence.
    public var oversizeFiles: [String]

    public init(
        fileCount: Int = 0,
        byteSize: Int64 = 0,
        truncated: Bool = false,
        hasGitignore: Bool = false,
        excluded: [ExcludedPath] = [],
        oversizeFiles: [String] = []
    ) {
        self.fileCount = fileCount
        self.byteSize = byteSize
        self.truncated = truncated
        self.hasGitignore = hasGitignore
        self.excluded = excluded
        self.oversizeFiles = oversizeFiles
    }

    public var isEmpty: Bool { fileCount == 0 && excluded.isEmpty }

    public var sensitiveFiles: [String] {
        excluded.filter { $0.reason == .sensitive }.map(\.path)
    }

    public var nestedRepositories: [String] {
        excluded.filter { $0.reason == .nestedRepository }.map(\.path)
    }

    /// GitHub refuses a file of 100 MB outright.
    public static let oversizeLimit: Int64 = 100 * 1_024 * 1_024
    /// Above this, the dialog says the size out loud before anything is published.
    public static let largeUploadLimit: Int64 = 100 * 1_024 * 1_024
    public static let manyFilesLimit = 5_000

    public var isLargeUpload: Bool {
        byteSize >= Self.largeUploadLimit || fileCount >= Self.manyFilesLimit || truncated
    }

    /// What the first commit will contain, in one line, with the uncertainty kept in.
    ///
    /// "At most", because an existing `.gitignore` is applied by git and not by this walk, so the
    /// real number can only be smaller. Saying a number that turns out to be wrong in the
    /// direction of "more files than promised" is the failure worth avoiding.
    public var summary: String {
        if isEmpty { return "Nothing yet, so the first commit will be empty." }
        let files = fileCount == 1 ? "1 file" : "\(fileCount.formatted()) files"
        let size = byteSize.formatted(.byteCount(style: .file))
        let prefix = truncated
            ? "More than \(files)"
            : (hasGitignore ? "At most \(files)" : "\(files.prefix(1).uppercased())\(files.dropFirst())")
        return "\(prefix), \(size)."
    }
}

// MARK: - GitHub names

/// The rules GitHub applies to a repository name.
///
/// Pinned by tests rather than trusted to memory, because the failure mode is a dialog that says
/// a name is fine and then a `gh repo create` that says it is not, after the folder has already
/// been turned into a repository.
public enum GitHubRepositoryName {
    public enum Problem: Sendable, Equatable {
        case empty
        case tooLong
        /// The characters GitHub will not take, in the order they appeared, deduplicated.
        case invalidCharacters(String)
        /// `.` and `..` are paths, not names.
        case reserved
        /// GitHub rejects a name ending in `.git`, because that is what the clone URL adds.
        case gitSuffix
    }

    public static let maxLength = 100

    /// Letters, digits, hyphen, underscore and full stop. Everything else GitHub silently rewrites
    /// to a hyphen on its own website, which is worse than saying so.
    public static func isAllowed(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || "-_.".contains(character))
    }

    public static func problem(with name: String) -> Problem? {
        guard !name.isEmpty else { return .empty }
        guard name.count <= maxLength else { return .tooLong }
        if name == "." || name == ".." { return .reserved }
        if name.lowercased().hasSuffix(".git") { return .gitSuffix }

        var offenders = ""
        for character in name where !isAllowed(character) && !offenders.contains(character) {
            offenders.append(character)
        }
        return offenders.isEmpty ? nil : .invalidCharacters(offenders)
    }

    public static func isValid(_ name: String) -> Bool { problem(with: name) == nil }

    /// The name to put in the field when the dialog opens, derived from the folder's own name.
    ///
    /// A suggestion, never a silent rewrite of something the user typed: the field stays editable
    /// and what is in it is what gets created.
    public static func suggestion(from folderName: String) -> String {
        var mapped = ""
        for character in folderName {
            mapped.append(isAllowed(character) ? character : "-")
        }
        while mapped.contains("--") {
            mapped = mapped.replacingOccurrences(of: "--", with: "-")
        }
        while let last = mapped.last, last == "-" || last == "." { mapped.removeLast() }
        while let first = mapped.first, first == "-" { mapped.removeFirst() }
        if mapped.lowercased().hasSuffix(".git") { mapped.removeLast(4) }
        if mapped.count > maxLength { mapped = String(mapped.prefix(maxLength)) }
        while let last = mapped.last, last == "-" || last == "." { mapped.removeLast() }
        return mapped.isEmpty ? "repository" : mapped
    }
}

public extension GitHubRepositoryName.Problem {
    var sentence: String {
        switch self {
        case .empty: "Give the repository a name."
        case .tooLong: "A repository name can be at most \(GitHubRepositoryName.maxLength) characters."
        case .invalidCharacters(let characters):
            "GitHub does not accept \(characters.map { "\($0)" }.joined(separator: " ")) in a "
                + "repository name. Letters, digits, hyphens, underscores and full stops only."
        case .reserved: "That name is not a name GitHub can use."
        case .gitSuffix: "A repository name cannot end in .git."
        }
    }
}

/// Whether a name is still free on GitHub, and whether we actually know.
///
/// `unknown` is its own case and not a stand-in for available. A check that timed out has learned
/// nothing, and a dialog that says "available" on the strength of a failed network call sends the
/// user into a `gh repo create` that fails after the folder has already been committed.
public enum NameAvailability: Sendable, Equatable {
    case idle
    case checking
    case available
    case taken
    case unknown(String)

    /// A failed or pending check never blocks the button. The user pressing it is what settles the
    /// question, and gh gives a clear answer when a name is taken.
    public var blocksCreation: Bool {
        self == .taken
    }

    public var sentence: String? {
        switch self {
        case .idle: nil
        case .checking: "Checking with GitHub."
        case .available: "Repository name is available."
        case .taken: "That name is already taken on GitHub."
        case .unknown(let why): why
        }
    }
}

// MARK: - Secrets

/// Which files are kept out of a first commit because they probably hold a credential.
///
/// Bloom already knows this hazard from two directions. `WorkspaceSafetyReport` singles out a
/// modified `.env` as the file most likely to be destroyed and least likely to be checked, and
/// `filesToCopy` defaults to `.env*` precisely because a project folder holds secrets that git
/// never sees. That default is also why excluding them here costs nothing: a `.env` that is not
/// in the repository is still copied into every worktree Bloom creates, so agents keep working.
///
/// The list errs towards excluding too much. A file wrongly left out of the first commit is added
/// by the user in a second one. A private key pushed to GitHub is a key that has to be rotated.
public enum SensitiveFile {
    /// Names that are examples of a secret file rather than one.
    static let templateSuffixes = [
        ".example", ".sample", ".template", ".dist", ".defaults", ".test",
    ]

    static let exactNames: Set<String> = [
        ".netrc", ".npmrc", ".pypirc", ".htpasswd", ".pgpass", ".dockercfg",
        "auth.json", "credentials", "credentials.json", "secrets.json", "secrets.yml",
        "secrets.yaml", "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519",
    ]

    static let extensions: Set<String> = [
        "pem", "key", "p12", "pfx", "keystore", "jks", "ppk", "asc", "kdbx",
    ]

    /// `path` is relative to the folder, with `/` separators.
    public static func matches(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        let lowered = name.lowercased()

        // An example file is documentation. `.env.example` is committed to half of GitHub.
        for suffix in templateSuffixes where lowered.hasSuffix(suffix) { return false }
        if lowered.hasSuffix(".pub") { return false }

        if lowered == ".env" || lowered.hasPrefix(".env.") { return true }
        if exactNames.contains(lowered) { return true }
        if extensions.contains((lowered as NSString).pathExtension) { return true }

        // ~/.aws/credentials and friends, wherever they were copied to.
        if path.lowercased().hasSuffix(".aws/credentials") { return true }
        return false
    }
}
