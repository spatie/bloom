import Foundation
import Observation
import BloomCore

/// This sheet owns the import task and only keeps account names and safe outcomes in UI state.
/// Selection is explicit; opening the sheet never exports or sends a credential.
@MainActor @Observable
final class ServerCredentialImportModel {
    typealias Candidate = ServerCredentialImport.Candidate
    struct Result {
        let succeeded: Bool
        let verified: Bool
        let message: String
        let recovery: String?
    }

    let connection: ServerSetupConnection
    private(set) var candidates: [Candidate] = []
    private(set) var notices: [String] = []
    private(set) var selected: Set<Candidate> = []
    private(set) var results: [Candidate: Result] = [:]
    private(set) var isDiscovering = false
    private(set) var isImporting = false
    private(set) var isStopping = false
    private(set) var currentAccount: String?
    private(set) var hasDiscovered = false
    private var task: Task<Void, Never>?
    private let discoverAccounts: @Sendable () async throws -> ServerCredentialImport.Discovery
    private let importAccount: @Sendable (Candidate, ServerSetupConnection) async throws -> ServerCredentialImport.Outcome

    init(connection: ServerSetupConnection,
         discover: @escaping @Sendable () async throws -> ServerCredentialImport.Discovery = { try await ServerCredentialImport.discover() },
         importAccount: @escaping @Sendable (Candidate, ServerSetupConnection) async throws -> ServerCredentialImport.Outcome = {
             try await ServerCredentialImport.importCredential($0, to: $1)
         }) {
        self.connection = connection
        self.discoverAccounts = discover
        self.importAccount = importAccount
    }

    var isBusy: Bool { isDiscovering || isImporting }
    var canImport: Bool { !isBusy && !selected.isEmpty }
    var hasResults: Bool { !results.isEmpty }
    var report: String {
        var lines = ["Bloom account import", "Server: \(connection.host)"]
        for candidate in candidates {
            guard let result = results[candidate] else { continue }
            lines.append("\(candidate.displayName) (\(candidate.detail)): \(result.message)")
            if let recovery = result.recovery { lines.append(recovery) }
        }
        return lines.joined(separator: "\n\n")
    }

    func select(_ candidate: Candidate, enabled: Bool) {
        guard !isBusy, candidates.contains(candidate), results[candidate]?.succeeded != true else { return }
        if enabled {
            // GitHub import installs a new credential store and preserves any existing one.
            // Select one account so a second choice cannot fail after the first was installed.
            if candidate.provider == .github { selected = selected.filter { $0.provider != .github } }
            selected.insert(candidate)
        } else { selected.remove(candidate) }
    }

    func discover() async {
        guard !isBusy, !hasDiscovered else { return }
        isDiscovering = true
        defer { isDiscovering = false }
        do {
            let discovery = try await discoverAccounts()
            try Task.checkCancellation()
            candidates = discovery.candidates
            notices = discovery.notices
            hasDiscovered = true
        } catch {
            guard !Task.isCancelled else { return }
            notices = [Self.safeFailure(error)]
            hasDiscovered = true
        }
    }

    func startImport() {
        guard canImport else { return }
        let chosen = candidates.filter { selected.contains($0) }
        guard !chosen.isEmpty else { return }
        isImporting = true
        isStopping = false
        task = Task { @MainActor in
            defer {
                self.isImporting = false
                self.isStopping = false
                self.currentAccount = nil
                self.task = nil
            }
            for candidate in chosen {
                guard !Task.isCancelled else { break }
                self.currentAccount = candidate.displayName
                do {
                    let outcome = try await self.importAccount(candidate, self.connection)
                    self.results[candidate] = Result(succeeded: true, verified: outcome.verified,
                                                    message: outcome.message, recovery: outcome.removalGuidance)
                    self.selected.remove(candidate)
                } catch {
                    if Task.isCancelled || error is CancellationError {
                        self.results[candidate] = Result(succeeded: false, verified: false,
                            message: "Import stopped. Credentials may already have reached the server.",
                            recovery: "Close this sheet to refresh server status before trying again.")
                        break
                    }
                    self.results[candidate] = Result(succeeded: false, verified: false,
                        message: Self.safeFailure(error), recovery: nil)
                }
            }
        }
    }

    func stop() {
        guard isImporting else { return }
        isStopping = true
        task?.cancel()
    }

    func cancel() { task?.cancel() }

    private static func safeFailure(_ error: Error) -> String {
        guard let failure = error as? ServerCredentialImport.Failure else {
            return "The account could not be imported. Check the server connection or use Sign In instead."
        }
        return [failure.errorDescription, failure.recoverySuggestion].compactMap { $0 }.joined(separator: " ")
    }
}
