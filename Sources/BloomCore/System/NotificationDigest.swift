import Foundation

/// Something worth saying about one workspace, before it has been decided whether it gets a banner
/// of its own or a line in a summary.
public struct NotificationDraft: Sendable, Hashable {
    public var event: NotificationEvent
    public var workspaceID: WorkspaceID
    public var workspaceName: String
    /// The specific thing that happened, if there is one. The agent's closing sentence, the check
    /// rollup, the error. Empty falls back to the event's own wording.
    public var detail: String

    public init(event: NotificationEvent, workspaceID: WorkspaceID, workspaceName: String, detail: String = "") {
        self.event = event
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        self.detail = detail
    }
}

/// A banner, fully composed, with nothing left to decide.
public struct PreparedNotification: Sendable, Hashable {
    /// Reused deliberately. macOS replaces a delivered notification that carries an identifier it
    /// already has, so a workspace that finishes twice while the user is away leaves one banner
    /// saying the current thing rather than two saying different things.
    public var identifier: String
    /// Groups the banners in Notification Center. Per workspace for a single, per event for a
    /// summary, which is how they read when a dozen of them have piled up overnight.
    public var threadIdentifier: String
    public var title: String
    public var body: String
    /// Which workspace clicking it selects.
    public var workspaceID: WorkspaceID

    public init(
        identifier: String,
        threadIdentifier: String,
        title: String,
        body: String,
        workspaceID: WorkspaceID
    ) {
        self.identifier = identifier
        self.threadIdentifier = threadIdentifier
        self.title = title
        self.body = body
        self.workspaceID = workspaceID
    }
}

/// Collects drafts for a moment before turning them into banners.
///
/// Bloom's whole premise is several agents at once, which means they finish together: kick six off
/// with the same prompt and they land within seconds of each other. Six stacked banners is six
/// dismissals and no information, where "6 agents finished" plus their names is one glance. So a
/// short window collects whatever arrives, and only what is still alone at the end of it gets to be
/// its own banner with its own summary text.
///
/// The window is short on purpose. It is long enough to catch a cluster and far too short to make
/// a single agent's notification feel late, which matters because the whole point is to tell
/// somebody who has walked away that they can come back.
public struct NotificationDigest: Sendable {
    public static let window = Duration.milliseconds(2_500)

    /// macOS truncates a banner body to a couple of lines anyway, and an agent's closing summary
    /// can be several paragraphs.
    public static let bodyLimit = 240

    /// One batch per event. A failure and a finish arriving together are two different pieces of
    /// news, and merging them would produce a sentence that is true of neither.
    private var pending: [NotificationEvent: [NotificationDraft]] = [:]

    public init() {}

    public var isEmpty: Bool { pending.isEmpty }

    /// Adds a draft. Returns true when this one opened a new batch, which is the caller's cue to
    /// schedule the flush. A workspace that fires twice inside one window keeps only its latest,
    /// because the second event is the current truth about that workspace and the first is not.
    @discardableResult
    public mutating func add(_ draft: NotificationDraft) -> Bool {
        var batch = pending[draft.event] ?? []
        let isNewBatch = batch.isEmpty
        batch.removeAll { $0.workspaceID == draft.workspaceID }
        batch.append(draft)
        pending[draft.event] = batch
        return isNewBatch
    }

    /// Takes the batch for one event and composes it. Nil when there was nothing waiting.
    public mutating func drain(_ event: NotificationEvent) -> PreparedNotification? {
        guard let batch = pending.removeValue(forKey: event) else { return nil }
        return Self.prepare(batch)
    }

    /// The wording, as a pure function, because the wording is the part that is worth arguing
    /// about and the only way to argue about it is to be able to assert on it.
    public static func prepare(_ batch: [NotificationDraft]) -> PreparedNotification? {
        guard let first = batch.first else { return nil }
        guard batch.count > 1 else {
            let detail = first.detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return PreparedNotification(
                identifier: "bloom.\(first.event.rawValue).\(first.workspaceID)",
                threadIdentifier: first.workspaceID.rawValue,
                // The workspace name is the title rather than a prefix on the body, because the
                // one question a banner from this app has to answer is "which one?", and a title
                // survives truncation where the front of a body does not.
                title: first.workspaceName,
                body: cap(detail.isEmpty ? first.event.fallbackDetail : detail),
                workspaceID: first.workspaceID
            )
        }

        return PreparedNotification(
            identifier: "bloom.\(first.event.rawValue).digest",
            threadIdentifier: "bloom.\(first.event.rawValue)",
            title: first.event.summaryTitle(count: batch.count),
            // Names, not a count on its own. Knowing that six finished without knowing which six is
            // not worth a banner when the answer is already in the sidebar.
            body: cap(batch.map(\.workspaceName).joined(separator: ", ")),
            // Clicking a summary lands on the first of them, and the rest are one Next Unread away.
            // Landing nowhere would make the click do nothing but raise the window, which is the
            // one outcome that reads as broken.
            workspaceID: first.workspaceID
        )
    }

    private static func cap(_ text: String) -> String {
        // Cut on a line break first: an agent's summary usually opens with the sentence that
        // matters and continues with the detail, and half of the second sentence is worse than
        // none of it.
        let firstLine = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? text
        guard firstLine.count > bodyLimit else { return firstLine }
        return String(firstLine.prefix(bodyLimit)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }
}
