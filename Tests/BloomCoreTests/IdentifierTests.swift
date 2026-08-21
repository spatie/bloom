import Foundation
import Testing
@testable import BloomCore

/// What a typed identifier has to keep doing, now that every id in Bloom is one.
///
/// None of this is about the compiler catching a swapped id, which is the point of the types and
/// needs no test: a mismatch does not build. This is about the three places a typed id leaves the
/// type system and has to arrive as the same bytes it always did, because the owner's database and
/// user defaults are already full of the old ones.
@Suite("Typed identifiers")
struct IdentifierTests {
    /// The conformance the whole change rests on, and it is not Bloom's.
    ///
    /// The standard library ships `Codable` for any `RawRepresentable` whose `RawValue` is
    /// `String`, and that implementation uses a single value container. Without it Swift would
    /// synthesise the ordinary member-wise coding for these structs and every id in every stored
    /// payload would become `{"rawValue":"..."}`, which would not decode on any row already
    /// written. Pinned here because it is inherited from another module: nothing in this
    /// repository would notice it changing.
    @Test("an identifier encodes as a bare JSON string, not as an object")
    func encodesAsABareString() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        #expect(String(decoding: try encoder.encode(WorkspaceID("w1")), as: UTF8.self) == "\"w1\"")
        #expect(String(decoding: try encoder.encode(SessionID("s1")), as: UTF8.self) == "\"s1\"")
        #expect(String(decoding: try encoder.encode(RepoID("r1")), as: UTF8.self) == "\"r1\"")
    }

    /// A payload written before any of this existed, decoding into the typed shape unchanged.
    ///
    /// The shape is `CenterTab`, which lives in the app target and so cannot be reached from here,
    /// copied field for field: it is the only value Bloom stores as JSON with an id inside it, and
    /// there is a copy of it in the owner's user defaults under `center.tabs.<workspace>` for every
    /// workspace he has a terminal open in. If `WorkspaceID` ever stopped encoding through a single
    /// value container this payload would become unreadable and every one of those tabs would
    /// silently close, which is exactly the failure the whole change was made to stop.
    @Test("a payload stored when ids were strings decodes into the typed shape")
    func oldPayloadsStillDecode() throws {
        struct Tab: Codable, Equatable {
            var id: String
            var workspaceID: WorkspaceID
            var kind: String
            var title: String
            var url: String
            var path: String
        }

        // Byte for byte what `CenterTabStore` has already written, keys in the order
        // `.sortedKeys` puts them so the comparison below can be on the bytes themselves.
        let stored = #"""
        {"id":"t1","kind":"terminal","path":"","title":"Terminal","url":"","workspaceID":"9d4b0f1e-1111-2222-3333-444455556666"}
        """#.trimmingCharacters(in: .whitespacesAndNewlines)

        let tab = try JSONDecoder().decode(Tab.self, from: Data(stored.utf8))
        #expect(tab.workspaceID == WorkspaceID("9d4b0f1e-1111-2222-3333-444455556666"))

        // And back out again as the same bytes, so a tab rewritten by this build is still readable
        // by one from before the change. Nothing migrates these: the round trip is the migration.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(String(decoding: try encoder.encode(tab), as: UTF8.self) == stored)
    }

    /// Why `Identifier` requires `CustomStringConvertible`.
    ///
    /// `OpenInPreferences`, `ComposerControls`, `WorkspaceStartMode` and `ViewedToggle` all build a
    /// user defaults key by interpolating an id into a string. Without `description` the
    /// interpolation would render the struct, every key in the owner's preferences would change at
    /// once, and every remembered editor, output style and viewed file would silently be orphaned.
    /// The compiler cannot see that: interpolation accepts anything.
    @Test("an identifier interpolates as its raw value, so stored keys do not move")
    func interpolatesAsTheRawValue() {
        let workspace = WorkspaceID("w1")

        #expect("\(workspace)" == "w1")
        #expect(OpenInPreferences.key(forRepo: RepoID("r1")) == "openIn.lastUsed.r1")
        #expect(ComposerControls.fastModeKey(sessionID: SessionID("s1")) == "session.s1.fastMode")
    }

    /// The SQLite seam. `Store` binds ids as `.text(workspace.id)` exactly as it did when they
    /// were strings, and what reaches the statement has to be the raw value rather than anything
    /// wrapping it. The columns are still `TEXT` and no migration goes with this change.
    @Test("a typed identifier binds as the text it always was")
    func bindsAsText() {
        #expect(SQLValue.text(WorkspaceID("w1")) == .text("w1"))
        #expect(SQLValue.text(SessionID("s1")) == .text("s1"))

        // The nullable columns, `workspaces.parent_workspace_id` among them.
        #expect(SQLValue.text(WorkspaceID?.none) == .null)
        #expect(SQLValue.text(WorkspaceID?.some(WorkspaceID("w1"))) == .text("w1"))
    }
}
