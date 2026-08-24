import Foundation

/// The panes of one thing, as JSON in user defaults.
///
/// One shape on both sides of the phase A migration. It is byte for byte what `CenterPaneStore`
/// has been writing under `center.panes.<workspaceID>` since the centre column could be split, and
/// it is what a tab is written as now, so the migration re-files a record rather than converting
/// one and there is a single codec to be wrong about.
///
/// User defaults rather than SQLite, for the reason the tab list is there: what somebody had open
/// is worth restoring and not worth a table or a migration. Losing it costs an arrangement, never
/// a conversation.
public struct StoredPaneArrangement: Codable, Sendable, Equatable {
    /// `SplitLayout.encoded`.
    public var layout: String

    /// Pane id to what that pane points at. A pane with no entry is a pane pointing at nothing,
    /// which is how `CenterPaneStore` wrote one: assigning nil to a dictionary subscript removes
    /// the key rather than storing a null.
    public var contents: [String: PaneContent]

    public init(layout: String, contents: [String: PaneContent]) {
        self.layout = layout
        self.contents = contents
    }

    /// Sorted keys, and that is the entire reason encoding goes through here rather than through a
    /// `JSONEncoder` at each call site.
    ///
    /// `contents` is a dictionary, and a dictionary's iteration order is seeded afresh every
    /// launch, so the same value encodes to different bytes on different runs. Phase A has to be
    /// replayable: it writes the new key before it deletes the old one, so a crash between those
    /// two lines leaves the migration to run again next launch, and "run again" is only harmless
    /// if the second run writes exactly what the first one did.
    public var encoded: Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(self)
    }

    /// Decoding is deliberately not hand written, because both fields have been there since the
    /// first byte was written. A field added later would have to be read with `decodeIfPresent`
    /// even though it is stored as required: see `CenterTab`, whose synthesized decoder threw on
    /// every record already on disk and silently closed every tab the user had open.
    public init?(decoding data: Data) {
        guard let value = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        self = value
    }

    /// Every content this arrangement holds that is not the one at its root.
    ///
    /// This is what a tab absorbs. `TabSet` filters the strip by it, so the rule that a thing lives
    /// in exactly one pane of exactly one tab is stated once, here, rather than at each caller.
    /// The root is excluded on purpose: it names the tab, so it keeps its place in the strip even
    /// when the same chat is also showing in a second pane of that same tab.
    public func claimedContents(root: PaneContent) -> Set<PaneContent> {
        Set(contents.values).subtracting([root])
    }
}
