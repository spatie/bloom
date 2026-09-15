import Foundation

/// The sea a new workspace is christened after, and the branch cut from it.
///
/// This used to live in `AppModel.startWorkspace` alone, which is the local create window, and so
/// a server never claimed one: a terminal or browser workspace started on a server with nothing
/// typed came back as "New workspace" on a branch called `workspace`, then `workspace-2`, while
/// the same start on this Mac came back as "Amundsen Sea" on `amundsen-sea`. Both routes now ask
/// here, so the rule in `OceanCatalog.shouldClaim`, the draw in `Store.claimOcean` and the prefix
/// in `WorkspaceNaming.prefixedBranch` are applied once rather than once per route.
public struct WorkspaceSeaClaim: Sendable, Hashable {
    public let pick: OceanPick
    /// The sea's slug under the project's branch prefix, or nil when that prefix would make it an
    /// invalid ref, in which case the branch falls back to the mechanical slug of the prompt.
    public let branch: String?

    public init(pick: OceanPick, branch: String?) {
        self.pick = pick
        self.branch = branch
    }

    /// Claims a sea when `OceanCatalog.shouldClaim` says this workspace should have one.
    ///
    /// Nil when it should not, when there is no store, or when the claim fails. A failed claim is
    /// not worth failing the create over: the workspace keeps the name git would have given it.
    public static func claim(
        in store: Store?,
        repositoryPath: String,
        userSuppliedName: String?,
        userSuppliedBranch: String?,
        isChatWorkspace: Bool,
        wantsAutomaticName: Bool,
        hasTask: Bool
    ) async -> WorkspaceSeaClaim? {
        guard OceanCatalog.shouldClaim(
            userSuppliedName: userSuppliedName,
            userSuppliedBranch: userSuppliedBranch,
            isChatWorkspace: isChatWorkspace,
            wantsAutomaticName: wantsAutomaticName,
            hasTask: hasTask
        ), let pick = try? await store?.claimOcean() else { return nil }
        // Detached because the load reads and parses every settings file the project answers to,
        // and the local caller is on the main actor, on the frame dismissing the create window.
        let prefix = await Task.detached(priority: .userInitiated) {
            SettingsLoader.load(repo: repositoryPath).branchPrefix
        }.value
        return WorkspaceSeaClaim(pick: pick, branch: WorkspaceNaming.prefixedBranch(pick.ocean.slug, prefix: prefix))
    }
}
