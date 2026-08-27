import Foundation

// One field, and everything Bloom works out from the line typed into it.
//
// The `+` beside Projects used to ask which of two things you were doing before you had said
// anything: New Project, or Add Project Folder. Both answers end in the same place, a project in
// the sidebar, and which door you came through was never the person's business to know. The
// evidence was in the code rather than in a taste about menus: two of `NewProjectRefusal`'s cases
// existed only because the other door existed, and both of their sentences ended by telling the
// person to go and use it. Those two are gone. A repository is Add. A folder with work in it is
// Start Tracking. Neither is a refusal any more.
//
// **Both rules are kept exactly as they were, and neither is merged into the other.**
// `NewProjectVerdict` judges a path that mostly is not there yet; `FolderVerdict` judges a folder
// that is, from what it holds. What did not exist is the parser that turns one typed line into a
// target, and the dispatcher that decides which of the two questions that target is. Both are
// here, both are pure, and the sheet draws what they say.

// MARK: - What was typed

/// A name or a path, read as the folder a project would live in.
///
/// Two fields became one, so the split they carried has to be made somewhere, and here is a
/// function rather than a `body`: which of "sparkline" and "~/dev/code/sparkline" the person meant
/// is the one genuinely ambiguous thing about the whole design, and an ambiguity resolved inside a
/// view is one nothing can look at.
public struct ProjectTarget: Sendable, Equatable {
    /// The project's folder name, which is the last component of whatever was typed.
    public var name: String
    /// The folder it sits in: the parent of a typed path, or the default location for a bare name.
    public var location: String

    public init(name: String, location: String) {
        self.name = name
        self.location = location
    }
}

public extension ProjectTarget {
    /// Whether what was typed names a place rather than a project.
    ///
    /// A slash anywhere, or a leading tilde, and nothing cleverer. `NewProjectPlan.target` refuses
    /// a name with a slash in it and that refusal is still right, because a slash is not something
    /// a folder name can hold; this decides which of the two questions the line is before that
    /// rule is asked, so "dev/sparkline" is now read as a place that Bloom cannot find rather than
    /// as a name it will not take.
    static func looksLikeAPath(_ typed: String) -> Bool {
        typed.contains("/") || typed.hasPrefix("~")
    }

    /// One typed line as the two things the rules below need.
    ///
    /// - Parameters:
    ///   - defaultLocation: where a bare name goes, which is `NewProjectPlan.suggestedLocation`.
    ///   - home: the home directory to expand a tilde against, passed in rather than read, so the
    ///     suite can ask this about a machine that is not the one running it.
    static func resolve(
        _ typed: String,
        defaultLocation: String,
        home: String
    ) -> ProjectTarget {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard looksLikeAPath(trimmed) else {
            return ProjectTarget(name: trimmed, location: defaultLocation)
        }
        let expanded = NewProjectPlan.expand(trimmed, home: home)
        // Standardised before it is split, so the trailing slash a Finder drag leaves on the end
        // does not make the name empty and `~/dev/code/./sparkline` is the same target as its
        // tidier spelling.
        let normalized = FolderPath.normalize(expanded)
        return ProjectTarget(
            name: (normalized as NSString).lastPathComponent,
            location: (normalized as NSString).deletingLastPathComponent
        )
    }
}

// MARK: - Which of the two rules the target belongs to

/// Why Bloom will not take the target that was typed.
///
/// Two lists behind one accessor, because they were always one policy split by which question was
/// asked. Both are written in the same register on purpose, so somebody who meets one of each in
/// the same window cannot tell they came from two files.
public enum ProjectTargetRefusal: Sendable, Equatable {
    /// From `NewProjectVerdict`: about a path with nothing at it.
    case target(NewProjectRefusal)
    /// From `FolderVerdict`: about a folder that is there and what it holds.
    case folder(FolderRefusal)

    /// One sentence, said under the field while the person is still typing.
    public var sentence: String {
        switch self {
        case .target(let refusal): refusal.sentence
        case .folder(let refusal): refusal.sentence
        }
    }

    /// The repository to offer instead, where the refusal has an obvious one.
    ///
    /// Only ever the enclosing repository of a path inside one, from either list. It is drawn as a
    /// button that writes the path into the field, which is the first place either list has had
    /// somewhere to put it: `FolderRefusal.alternative` has returned this for as long as it has
    /// existed and nothing has ever drawn it.
    public var alternative: String? {
        switch self {
        case .target(let refusal): refusal.alternative
        case .folder(let refusal): refusal.alternative
        }
    }

    /// What the button says while this refusal stands.
    ///
    /// It keeps a title rather than going blank, because a disabled button that still names a verb
    /// is what tells the reader Bloom understood the target and will not take it. Which verb is
    /// decided by which list refused: a folder that is there was going to be added, and a path
    /// that is not was going to be created.
    public var buttonTitle: String {
        switch self {
        case .target: ProjectTargetVerdict.createTitle
        case .folder: ProjectTargetVerdict.addTitle
        }
    }
}

/// What Bloom will do about the target that was typed. One of these is named on the button before
/// it is pressed, so a verb that is not what will happen can never be pressed.
public enum ProjectTargetVerdict: Sendable, Equatable {
    /// Nothing is there. Bloom makes the folder, and the location above it when `makesLocation`.
    case create(makesLocation: Bool)
    /// A folder is there and it is empty, so Bloom uses it as it is.
    case adopt
    /// A git repository. Bloom registers it and writes nothing.
    case add(root: String)
    /// A folder with somebody's work in it and no repository. `git init`, and the real files as
    /// the first commit. This is the case that used to be `NewProjectRefusal.folderNotEmpty`.
    case track
    case refuse(ProjectTargetRefusal)
}

public extension ProjectTargetVerdict {
    static let createTitle = "Create Project"
    static let addTitle = "Add Project"
    static let trackTitle = "Start Tracking"

    /// The whole dispatch, from the facts one walk of the file system gathered.
    ///
    /// **The branch is on whether anything is there, and it cannot be "ask `FolderVerdict` first
    /// and fall back".** The default location is the folder the owner's projects already live in,
    /// which `FolderVerdict` correctly refuses as a container of projects, so a dispatcher that
    /// asked it first would refuse `~/dev/code/sparkline` for what its parent holds. That is the
    /// same argument `NewProjectPlan`'s header makes about why the two rules are two rules.
    static func of(_ facts: NewProjectFacts) -> ProjectTargetVerdict {
        if facts.targetExists, facts.targetIsDirectory, !facts.targetIsEmpty {
            switch FolderVerdict.of(facts.folderFacts) {
            case .alreadyRepository(let root): return .add(root: root)
            case .offer: return .track
            case .refuse(let refusal): return .refuse(.folder(refusal))
            }
        }
        switch NewProjectVerdict.of(facts) {
        case .create(let makesLocation): return .create(makesLocation: makesLocation)
        case .adopt: return .adopt
        case .refuse(let refusal): return .refuse(.target(refusal))
        }
    }

    /// Whether the button can be pressed.
    var isAllowed: Bool {
        if case .refuse = self { return false }
        return true
    }

    /// Whether pressing it makes a commit, which is the only case where git having no name and no
    /// address configured is a reason to hold the button. Adding a repository writes nothing, so
    /// an unconfigured git is none of its business.
    var makesACommit: Bool {
        switch self {
        case .create, .adopt, .track: true
        case .add, .refuse: false
        }
    }

    /// Whether the window goes on to the New Workspace sheet.
    ///
    /// Only where Bloom made the repository. A project with an empty first commit is not something
    /// anybody wanted for its own sake: they had an idea, and the next thing is an agent working
    /// on it. A project that already had work in it ends in the sidebar, because they may well
    /// have come to look at what is already there. The footer says which of the two is about to
    /// happen, in four words, because in one window it is otherwise a branch nobody was told
    /// about.
    var opensAWorkspace: Bool {
        switch self {
        case .create, .adopt: true
        case .add, .track, .refuse: false
        }
    }

    /// The verb, which is also the button.
    var buttonTitle: String {
        switch self {
        case .create, .adopt: Self.createTitle
        case .add: Self.addTitle
        case .track: Self.trackTitle
        case .refuse(let refusal): refusal.buttonTitle
        }
    }
}

// MARK: - What the block under the field says

/// How the consequence block reads, which the window turns into an ink and a symbol.
public enum ProjectConsequenceTone: Sendable, Equatable {
    /// Nothing typed yet.
    case waiting
    /// Bloom will do it, and there is nothing to weigh up.
    case going
    /// Bloom will do it, and this is the one to read before pressing: somebody's existing files
    /// are about to become a first commit.
    case caution
    case refusal
}

/// The one block under the field, which never moves and is never empty.
///
/// Everything the four verdicts and the eleven refusals have to say is in this shape, so the sheet
/// draws one thing rather than five, and nothing appears or disappears as the target changes under
/// the keyboard. Held together here rather than in the view because every sentence in it is
/// already argued next to the code that produces it, and a view assembling them is a view that can
/// reword one of them by accident.
public struct ProjectConsequence: Sendable, Equatable {
    /// The path, and what becomes of it. Nil where there is no path worth naming yet.
    public var lead: String?
    /// What pressing the button does, in one paragraph.
    public var detail: String
    public var tone: ProjectConsequenceTone
    /// What will be kept out of the first commit. Drawn open rather than behind a chevron: it is
    /// the one thing on this sheet worth reading before pressing, and a folder with a `.env` in it
    /// is exactly the case that goes wrong quietly.
    public var excluded: [ExcludedPath]
    /// A path to offer as the way out of a refusal, written into the field when it is taken.
    public var alternative: String?

    public init(
        lead: String? = nil,
        detail: String,
        tone: ProjectConsequenceTone,
        excluded: [ExcludedPath] = [],
        alternative: String? = nil
    ) {
        self.lead = lead
        self.detail = detail
        self.tone = tone
        self.excluded = excluded
        self.alternative = alternative
    }
}

public extension ProjectConsequence {
    /// The block before anything has been typed.
    ///
    /// It has one job the rest of the sheet cannot do: say that a path is as good an answer as a
    /// name. Nothing else on screen mentions it, and a person who does not know it can paste a
    /// folder here is a person who goes looking for the door that was just removed.
    static func opening(location: String, projectsThere: Int, home: String) -> ProjectConsequence {
        let shown = NewProjectPlan.display(location, home: home)
        let placement = switch projectsThere {
        case 0: "New projects go in \(shown)."
        case 1: "New projects go in \(shown), where your other project lives."
        default: "New projects go in \(shown), where \(projectsThere) of your projects live."
        }
        return ProjectConsequence(
            detail: placement
                + " Type a name to make one there, or point at a folder you already have.",
            tone: .waiting
        )
    }

    /// What the verdict says, at the length the sentences were written at.
    ///
    /// - Parameters:
    ///   - branch: what the first commit's branch will be, asked of git rather than asserted,
    ///     because a machine with `init.defaultBranch` set gets its own answer.
    ///   - contents: what the folder holds, once the walk that counts it has come back. Nil until
    ///     then, and the sentence is written so that it is true either way rather than jumping
    ///     when the counts land.
    static func of(
        _ verdict: ProjectTargetVerdict,
        path: String,
        home: String,
        branch: String,
        contents: FolderContents? = nil
    ) -> ProjectConsequence {
        switch verdict {
        case .create(let makesLocation):
            ProjectConsequence(
                lead: NewProjectVerdict.create(makesLocation: makesLocation)
                    .hint(path: path, home: home),
                detail: firstCommit(on: branch),
                tone: .going
            )

        case .adopt:
            ProjectConsequence(
                lead: NewProjectVerdict.adopt.hint(path: path, home: home),
                detail: firstCommit(on: branch),
                tone: .going
            )

        case .add(let root):
            ProjectConsequence(
                lead: "\(NewProjectPlan.display(root, home: home)) is a git repository.",
                detail: "Bloom will add it as a project. Nothing is written to it and nothing in "
                    + "it is changed.",
                tone: .going
            )

        case .track:
            ProjectConsequence(
                lead: "\(NewProjectPlan.display(path, home: home)) has files in it and is not a "
                    + "repository.",
                detail: tracking(contents: contents, branch: branch),
                tone: .caution,
                excluded: contents?.excluded ?? []
            )

        case .refuse(let refusal):
            ProjectConsequence(
                detail: refusal.sentence,
                tone: .refusal,
                alternative: refusal.alternative
            )
        }
    }

    /// The whole content of this sentence is that Bloom wrote none of it. A language-guessed
    /// `.gitignore` or a generated README is a guess that is wrong for ever in a history nobody
    /// rewrites, and the agent about to start is a better scaffolder than a menu because it
    /// explains itself in a diff.
    private static func firstCommit(on branch: String) -> String {
        "git init, and an empty first commit on \(branch). Bloom writes no files of its own: "
            + "no README, no .gitignore."
    }

    private static func tracking(contents: FolderContents?, branch: String) -> String {
        var detail = "git init, and what is already here as the first commit on \(branch)."
        guard let contents else { return detail }
        detail += " " + contents.summary
        if let excluded = contents.excludedSummary { detail += " " + excluded }
        return detail
    }
}
