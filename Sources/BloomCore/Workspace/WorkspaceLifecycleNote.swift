import Foundation

/// The `.notice` row a chat gets when its workspace is archived or restored.
///
/// The worktree is the only thing archiving removes, so without a row the transcript of an archived
/// workspace never says that, or that a restore has to run the setup script again.
public struct WorkspaceLifecycleNote: Sendable, Equatable {
    public enum Event: String, Sendable, Equatable {
        case archived
        case restored
    }

    /// What the archive did, read before the worktree went and after the branch was settled.
    public struct ArchiveFacts: Sendable, Equatable {
        public var branch: String
        public var branchKept: Bool
        public var ranArchiveScript: Bool
        public var hasSetupScript: Bool
        /// Set when Git no longer knew the folder, which is then left on disk with its branch.
        public var keptFolder: String?

        public init(
            branch: String, branchKept: Bool, ranArchiveScript: Bool,
            hasSetupScript: Bool, keptFolder: String? = nil
        ) {
            self.branch = branch
            self.branchKept = branchKept
            self.ranArchiveScript = ranArchiveScript
            self.hasSetupScript = hasSetupScript
            self.keptFolder = keptFolder
        }
    }

    public let event: Event
    public let sentence: String

    public static func archived(_ facts: ArchiveFacts) -> WorkspaceLifecycleNote {
        if let folder = facts.keptFolder {
            return WorkspaceLifecycleNote(event: .archived, sentence: "Workspace archived. Git no longer "
                + "recognises its folder as a worktree, so the folder at \(folder) and its branch were "
                + "kept, and the archive script was skipped.")
        }
        var sentence = "Workspace archived. Its worktree was removed"
        sentence += facts.ranArchiveScript ? " after the archive script ran." : "."
        guard facts.branchKept else {
            return WorkspaceLifecycleNote(
                event: .archived, sentence: sentence + " The branch \(facts.branch) was deleted."
            )
        }
        sentence += " The branch \(facts.branch) was kept. Restoring rebuilds the worktree from it"
        sentence += facts.hasSetupScript ? " and runs the setup script again." : "."
        return WorkspaceLifecycleNote(event: .archived, sentence: sentence)
    }

    /// `relocatedTo` is where the worktree went when its old place was taken.
    public static func restored(setupRuns: Bool, relocatedTo: String? = nil) -> WorkspaceLifecycleNote {
        var sentence = "Workspace restored. The worktree was rebuilt from its branch"
        sentence += relocatedTo.map { " at \($0), because something else was in its old place." } ?? "."
        if setupRuns {
            sentence += " The setup script is running again, because what it installed is gone."
        }
        return WorkspaceLifecycleNote(event: .restored, sentence: sentence)
    }

    /// The stored `.notice` row.
    public var payload: Data {
        let object = ["type": "bloom_note", "subtype": Self.subtype, "event": event.rawValue, "message": sentence]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    /// Nil when a `.notice` row is something else, such as a rate limit.
    public init?(payload: Data) {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: payload),
              json["subtype"]?.stringValue == Self.subtype,
              let event = json["event"]?.stringValue.flatMap(Event.init(rawValue:)),
              let sentence = json["message"]?.stringValue, !sentence.isEmpty else { return nil }
        self.init(event: event, sentence: sentence)
    }

    private init(event: Event, sentence: String) {
        self.event = event
        self.sentence = sentence
    }

    private static let subtype = "workspace_lifecycle"
}
