import AppIntents
import BloomCore

/// Lets an `AppEntity` be identified by the same type the rest of Bloom identifies it by.
///
/// Without this, `ProjectEntity.ID` and `WorkspaceEntity.ID` would both have to be `String`, and
/// the Shortcuts boundary is the last place that is wanted: a `[ProjectEntity.ID]` handed back by
/// the system is exactly the sort of list that gets passed to a lookup expecting the other kind.
/// AppIntents ships this conformance for `String`, `Int` and `UUID` only, so a typed id needs it
/// spelled out.
extension RepoID: EntityIdentifierConvertible {
    public var entityIdentifierString: String { rawValue }

    public static func entityIdentifier(for string: String) -> RepoID? { RepoID(string) }
}

extension WorkspaceID: EntityIdentifierConvertible {
    public var entityIdentifierString: String { rawValue }

    public static func entityIdentifier(for string: String) -> WorkspaceID? { WorkspaceID(string) }
}
