import Foundation

/// What a project has to say about one of Bloom's own turns, over and above what Bloom says.
///
/// Bloom's own words used to be a file as well. Pressing Merge wrote `MergeInstructions` into
/// `.bloom/scratch/merge-instructions.md` and attached it straight back, so the turn could say
/// "follow the instructions in that file". That round trip earned nothing: those words are the
/// same on every press, in every repository, and a reader watching the transcript had to open an
/// invisible file to find out what the agent had been told about a command that changes a server.
/// They are in the message now, and a project's own words are the only thing this type attaches to
/// a merge.
///
/// Fix merge conflicts went the other way, and `ConflictInstructions` argues why: its steps are
/// long, they act on nothing but this worktree, and inline they made a bubble nobody read. So that
/// turn arrives here already carrying a file of Bloom's, and what this type adds goes after it and
/// outranks it.
///
/// **Two places a project can say it, and the file wins.**
///
/// - `.bloom/merge-instructions.md`, or `.bloom/conflict-instructions.md`, in the worktree. This
///   is the copy the branch itself carries, so it is reviewable in the same diff as the work it
///   governs, and pointing an agent at it writes nothing at all.
/// - `instructions.merge`, or `instructions.fix_conflicts`, in the project's settings file, typed
///   in the project settings window. Settings are read from the project's root rather than from
///   the worktree, so a sentence typed there applies to every workspace the moment it is saved,
///   including the ones cut before it existed. That is what the field buys, and it is why it is
///   not merely a second way to write the file.
///
/// The file wins for the same reason `SettingsLoader.readScript` lets `scripts.setup_file` beat
/// `scripts.setup` inside one file: a file dedicated to the subject is unambiguous about what it
/// is, where a string in a settings file is the general bucket. It is also the more specific of
/// the two, being the branch's own answer rather than the project's, and the one that reaches the
/// agent with nothing written on the way.
///
/// **Nothing is attached when a project has said nothing**, which is the common case and the one
/// the turn has to read cleanly in. A turn naming a file that says nothing is a turn asking the
/// agent to go and read nothing.
public enum ProjectInstructions {
    /// One turn Bloom composes itself and that a project may add to.
    public enum Subject: String, Sendable, Hashable, CaseIterable {
        case merge
        case fixConflicts
    }

    /// What this project turned out to have to say. `nothing` is not a failure, it is the answer
    /// most projects give.
    public enum Extra: Sendable, Hashable {
        case nothing
        /// A file in the worktree, named in the turn and read by the agent.
        case file(String)
        /// The words themselves, because nothing could be written. A read-only checkout is a
        /// reason to say it differently, not a reason to drop what the project asked for.
        case inline(String)
    }

    // MARK: - Where a subject's words live

    /// The project's own file, relative to the worktree, because that is where the agent is
    /// standing and a path inside the worktree is one it may read without asking.
    public static func projectPath(for subject: Subject) -> String {
        ".bloom/\(fileStem(for: subject))-instructions.md"
    }

    /// Where a settings value is spilled so it can be read as a file. In the shielded folder, so
    /// git cannot see it and an agent told to commit what it finds cannot commit it.
    public static func scratchPath(for subject: Subject) -> String {
        "\(WorktreeScratch.generated)/\(fileStem(for: subject))-instructions.md"
    }

    /// The settings key the project settings window writes.
    public static func settingsKey(for subject: Subject) -> SettingsKey {
        switch subject {
        case .merge: .mergeInstructions
        case .fixConflicts: .conflictInstructions
        }
    }

    /// What the settings files say about this subject, if anything.
    public static func stated(_ subject: Subject, in settings: RepoSettings) -> String? {
        switch subject {
        case .merge: settings.mergeInstructions
        case .fixConflicts: settings.conflictInstructions
        }
    }

    private static func fileStem(for subject: Subject) -> String {
        switch subject {
        case .merge: "merge"
        case .fixConflicts: "conflict"
        }
    }

    // MARK: - Reading

    /// What this project adds to `subject`, in this worktree.
    ///
    /// - Parameter stated: what the settings files said, from `stated(_:in:)`. Passed in rather
    ///   than loaded here because settings are read from the project's root and this function is
    ///   handed a worktree, and a function that quietly read a second directory would be a
    ///   function whose answer nobody could predict from its arguments.
    public static func resolve(
        _ subject: Subject, in worktree: String, stated: String? = nil
    ) -> Extra {
        let project = projectPath(for: subject)
        if let text = readable(project, in: worktree), !text.isEmpty { return .file(project) }

        let typed = stated?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !typed.isEmpty else { return .nothing }
        guard let spilled = spill(typed, for: subject, in: worktree) else { return .inline(typed) }
        return .file(spilled)
    }

    /// Every subject this checkout has a file of its own for, and where it is.
    ///
    /// For the project settings window, which has to say that a field it is showing is outranked
    /// by a file. Asked once when the settings are read rather than from a view's body, because it
    /// is a look at the disk and a body is evaluated on every keystroke in the box above it.
    public static func files(in worktree: String) -> [Subject: String] {
        var found: [Subject: String] = [:]
        for subject in Subject.allCases {
            let relative = projectPath(for: subject)
            guard let text = readable(relative, in: worktree), !text.isEmpty else { continue }
            found[subject] = relative
        }
        return found
    }

    /// The text of a file in the worktree, trimmed, or nil when there is no readable file there.
    ///
    /// Read rather than merely stat-ed, because a project that has committed an empty
    /// `.bloom/merge-instructions.md`, or one somebody emptied and left behind, has said nothing,
    /// and a turn that names it would send the agent to read nothing. Judging by the words in it
    /// stops there: a file with a heading and nothing else is somebody starting, and Bloom is in
    /// no position to tell them they have not said enough yet.
    private static func readable(_ relative: String, in worktree: String) -> String? {
        guard InstructionFile.isFile(relative, in: worktree) else { return nil }
        let full = (worktree as NSString).appendingPathComponent(relative)
        guard let text = try? String(contentsOfFile: full, encoding: .utf8) else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Writes a settings value out as a file the agent can be pointed at, and answers its path.
    ///
    /// Overwritten on every turn rather than kept once it exists, which is the one way this
    /// differs from the scratch file it replaces. That file held a constant, so writing it twice
    /// was a waste; this one holds whatever the settings said a moment ago, and a stale copy would
    /// be an agent following an instruction the project had already changed.
    ///
    /// Nil when nothing could be written, which is the caller's signal to put the words in the
    /// message instead. The path that comes back is a file that was on disk and readable at the
    /// moment of answering, which is the contract every path Bloom writes into a turn holds: a
    /// path in a turn is a promise to the agent that it can read what it names.
    private static func spill(_ text: String, for subject: Subject, in worktree: String) -> String? {
        let relative = scratchPath(for: subject)
        WorktreeScratch.shield(WorktreeScratch.generated, in: worktree)
        let full = (worktree as NSString).appendingPathComponent(relative)
        guard (try? (text + "\n").write(toFile: full, atomically: true, encoding: .utf8)) != nil
        else { return nil }
        return InstructionFile.isFile(relative, in: worktree) ? relative : nil
    }

    // MARK: - Composing the turn

    /// The whole turn: what the prompt rendered, Bloom's own steps for this subject, and the
    /// project's own words when it has any.
    ///
    /// Pure, and the only place the three are put in an order, so what an agent is about to be
    /// told can be asserted without a worktree, a store or GitHub. That is the same reason
    /// `MergePromptContext` is a value rather than a lookup.
    public static func turn(_ rendered: String, for subject: Subject, adding extra: Extra) -> String {
        var parts = [rendered.trimmingCharacters(in: .whitespacesAndNewlines)]
        if let canonical = canonical(for: subject) { parts.append(canonical) }
        if let closing = sentence(for: subject, adding: extra) { parts.append(closing) }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// Bloom's own steps, which no override can edit away.
    ///
    /// Merge has them here and resolving a conflict does not, and the asymmetry is the same one
    /// that put merging behind a confirmation and left the fix without one. Merging is the one
    /// destructive, off-machine thing this app offers, so which `gh` flags are forbidden and what
    /// to do when GitHub refuses are held in the message, where a prompt override cannot lose them
    /// and where the reader can see them without opening anything.
    ///
    /// Resolving a conflict has steps of Bloom's own too, and they are not nil because there are
    /// none: they are `ConflictInstructions`, a file in the worktree that the message names,
    /// because nothing in that turn acts on a server and eight paragraphs of mechanics in a chat
    /// bubble is what stopped anybody reading them. They are added before this call rather than
    /// inside it, by `WorkspaceModel.requestFixConflicts`, because the path they are at is a fact
    /// about one worktree and everything in this switch is a constant.
    public static func canonical(for subject: Subject) -> String? {
        switch subject {
        case .merge: MergeInstructions.canonical
        case .fixConflicts: nil
        }
    }

    /// The sentence that carries the project's own words, or nothing at all.
    ///
    /// The path goes inside the sentence that asks for it, as a code span, which is where every
    /// file Bloom names in a turn goes and how a person typing one writes a path. See
    /// `InstructionFile.asking` for the argument, and `AttachmentDraft` for why the code span is
    /// what makes the transcript able to draw it as a chip without being told anything.
    ///
    /// It says the project's words win, because the reader of the turn has to know which of two
    /// instructions applies when they disagree, and because the alternative is an agent picking.
    public static func sentence(for subject: Subject, adding extra: Extra) -> String? {
        switch extra {
        case .nothing:
            return nil
        case .file(let path):
            return "\(preamble(for: subject)) Follow the instructions in "
                + "\(AttachmentDraft.token(for: path)) as well, and where they disagree with "
                + "anything above, they win."
        case .inline(let text):
            return "\(inlineLead(for: subject))\n\n\(text)"
        }
    }

    /// The sentence that goes in front of a project's own words when they could not be written to
    /// a file.
    ///
    /// Its own function because it is read from two ends. This composes the turn with it, and
    /// `SentTurn` recognises it in a turn that has already gone, so that the words after it can be
    /// drawn as the same chip a project's own FILE gets and hovered for the same card. Two spellings
    /// of one sentence would be a chip that stopped appearing the day somebody reworded this.
    public static func inlineLead(for subject: Subject) -> String {
        "\(preamble(for: subject)) They could not be written to a file in this worktree, so they "
            + "are below. Where they disagree with anything above, they win."
    }

    private static func preamble(for subject: Subject) -> String {
        switch subject {
        case .merge: "This project has its own instructions for merging."
        case .fixConflicts: "This project has its own instructions for resolving merge conflicts."
        }
    }
}
