import Foundation

public struct RemoteWorkspaceContext: Codable, Sendable {
    public var branches: [String]
    public var branchPrefix: String?
    public var hasSetupScript: Bool
    public var composer: RemoteComposerState
    public var files: [String]
    public init(branches: [String], branchPrefix: String?, hasSetupScript: Bool, composer: RemoteComposerState, files: [String]) {
        self.branches = branches; self.branchPrefix = branchPrefix; self.hasSetupScript = hasSetupScript
        self.composer = composer; self.files = files
    }

}

public struct ServerInitialAttachment: Codable, Sendable, Equatable {
    public var sourcePath: String
    public var name: String
    public var data: Data

    public init(sourcePath: String, name: String, data: Data) {
        self.sourcePath = sourcePath; self.name = name; self.data = data
    }
}
