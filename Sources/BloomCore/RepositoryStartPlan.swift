import Foundation

/// Turning a plain folder into a git repository, decided before anything is done to it.
///
/// Everything in this file is pure. It takes facts that were gathered by looking at the disk and
/// answers three questions: may this folder become a repository at all, what would be committed
/// if it did, and is the GitHub name the user typed a name GitHub will accept. The answers are
/// what the dialog shows, and they are what the tests pin, because the alternative is a dialog
/// whose promises are only checked by running it against somebody's home directory.

// MARK: - What the folder is

/// What was found by looking at a folder, with no judgement attached yet.
public struct FolderFacts: Sendable, Equatable {
    public var path: String
    /// Git already answers yes here. `git rev-parse --is-inside-work-tree` is true for a
    /// subdirectory too, so this covers "the folder is a repository" and "the folder is part of
    /// one" at the same time.
    public var isRepository: Bool
    /// The top level of a repository this folder sits inside, when it sits inside one without
    /// being part of its work tree. Rare, and worth refusing over rather than nesting.
    public var enclosingRepository: String?
    public var isWritable: Bool
    public var isDirectory: Bool
    /// The user's home, passed in rather than read, so the rule can be tested on any machine.
    public var homeDirectory: String
    /// Direct children that are themselves git repositories, by name. A folder full of these is
    /// somebody's projects directory, not a project.
    public var childRepositories: [String]

    public init(
        path: String,
        isRepository: Bool,
        enclosingRepository: String? = nil,
        isWritable: Bool = true,
        isDirectory: Bool = true,
        homeDirectory: String,
        childRepositories: [String] = []
    ) {
        self.path = path
        self.isRepository = isRepository
        self.enclosingRepository = enclosingRepository
        self.isWritable = isWritable
        self.isDirectory = isDirectory
        self.homeDirectory = homeDirectory
        self.childRepositories = childRepositories
    }
}

/// Why Bloom will not make a repository out of a particular folder.
///
/// A refusal rather than a warning in every case here, because all of them produce a repository
/// that is wrong in a way the user would have to undo by hand, and none of them is something a
/// person means to do. Somebody who genuinely wants `git init` in their home directory can still
/// run `git init` in their home directory.
public enum FolderRefusal: Sendable, Equatable {
    /// The folder is inside another repository. Initialising here would nest one repository in
    /// another, and git commits the inner one as an unusable gitlink.
    case insideRepository(String)
    case homeDirectory
    /// A folder macOS owns, or one the system puts things in.
    case systemDirectory
    case notWritable
    case notADirectory
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
    var sentence: String {
        switch self {
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
        case .notADirectory:
            "That is not a folder."
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

    private static func list(_ names: [String]) -> String {
        let shown = names.prefix(3).joined(separator: ", ")
        guard names.count > 3 else { return shown }
        return "\(shown) and \(names.count - 3) more"
    }
}

/// What Bloom will do about a folder that was handed to it.
public enum FolderVerdict: Sendable, Equatable {
    /// Nothing to decide. The existing path adds it.
    case alreadyRepository
    case refuse(FolderRefusal)
    /// Offer to make it one.
    case offer
}

public extension FolderVerdict {
    /// The whole rule, in one place, from facts alone.
    static func of(_ facts: FolderFacts) -> FolderVerdict {
        guard facts.isDirectory else { return .refuse(.notADirectory) }
        if facts.isRepository { return .alreadyRepository }
        if let enclosing = facts.enclosingRepository { return .refuse(.insideRepository(enclosing)) }

        let path = FolderPath.normalize(facts.path)
        if path == FolderPath.normalize(facts.homeDirectory) { return .refuse(.homeDirectory) }
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

    /// Folders nobody means to turn into a repository.
    ///
    /// The list is short on purpose. It covers the roots macOS owns and the handful of folders in
    /// a home directory that are containers by definition. Anything else is the user's business.
    public static func isReserved(_ path: String, home: String) -> Bool {
        let normalized = normalize(path)
        if systemRoots.contains(normalized) { return true }
        // Everything directly under a system root that is not a user's own folder, such as
        // /Volumes/Backup or /Library/Fonts.
        for root in systemRoots where root != "/" && root != "/Users" {
            if normalized.hasPrefix(root + "/") { return true }
        }

        let normalizedHome = normalize(home)
        for name in reservedHomeChildren where normalized == normalizedHome + "/" + name {
            return true
        }
        return false
    }

    static let systemRoots: Set<String> = [
        "/", "/Applications", "/Library", "/System", "/Users", "/Volumes",
        "/bin", "/sbin", "/usr", "/opt", "/private", "/tmp", "/var", "/etc", "/cores", "/dev",
    ]

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
