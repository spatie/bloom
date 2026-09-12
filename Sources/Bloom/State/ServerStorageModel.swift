import Foundation
import Observation
import BloomCore
import BloomClient

/// Cleanup stays on the connection the reader reviewed, even if another server is selected.
@MainActor @Observable
final class ServerStorageModel {
    struct Review: Identifiable {
        let id = UUID()
        let generation: Int
        let serverName: String
        let targets: [ServerStorageCleanupTarget]
    }

    let server: ServerWindowModel
    var selected: Set<ServerStorageCleanupTarget> = [.buildCache]
    private(set) var report: ServerStorageReport?
    private(set) var lastCleanup: ServerStorageCleanupResult?
    private(set) var error: String?
    private(set) var unsupported = false
    private(set) var isLoading = false
    private(set) var isCleaning = false
    private(set) var cleaningServerName: String?
    private(set) var needsRefresh = false
    private var requestID = UUID()
    private var reportGeneration: Int?
    private var capabilityGeneration: Int?

    init(server: ServerWindowModel) { self.server = server }

    var canReview: Bool {
        server.isConnected && !server.isConnecting && !server.isPerformingCommand
            && !isLoading && !isCleaning && !needsRefresh && !unsupported && error == nil
            && reportGeneration == server.connectionGeneration && report?.dockerState == .ready && !selected.isEmpty
    }

    func refresh() async {
        let generation = server.connectionGeneration
        if reportGeneration != generation {
            report = nil; lastCleanup = nil; unsupported = false; selected = [.buildCache]; error = nil
        }
        guard !isCleaning else { return }
        let id = UUID()
        requestID = id
        guard server.isConnected, !server.isConnecting else {
            error = nil; isLoading = false
            return
        }
        isLoading = true; error = nil
        defer { if requestID == id { isLoading = false } }
        do {
            if capabilityGeneration != generation || unsupported {
                let capabilities = try await server.read(.diagnostics, timeout: .seconds(30))
                try Task.checkCancellation()
                guard requestID == id, generation == server.connectionGeneration else { return }
                guard case .diagnostics(let diagnostics) = capabilities, diagnostics.storageManagement == true else {
                    unsupported = true; report = nil
                    return
                }
                capabilityGeneration = generation
            }
            unsupported = false
            let result = try await server.read(.storage, timeout: .seconds(30))
            try Task.checkCancellation()
            guard requestID == id, generation == server.connectionGeneration else { return }
            guard case .storage(let value) = result else { throw ServerFailure("The server did not return its storage usage.") }
            report = value; reportGeneration = generation; needsRefresh = false
        } catch is CancellationError {
            // Closing settings or switching servers cancels only the read, never a confirmed cleanup.
        } catch {
            guard requestID == id, generation == server.connectionGeneration else { return }
            self.error = error.localizedDescription
        }
    }

    func prepareReview() async -> Review? {
        guard canReview else { return nil }
        let generation = server.connectionGeneration
        await refresh()
        guard generation == server.connectionGeneration, canReview else { return nil }
        return Review(generation: generation, serverName: server.displayName,
                      targets: ServerStorageCleanupTarget.allCases.filter { selected.contains($0) })
    }

    func clean(_ review: Review) async {
        guard canReview, review.generation == server.connectionGeneration else {
            error = "The server connection changed. Refresh storage and review cleanup again."
            return
        }
        isCleaning = true; cleaningServerName = review.serverName; error = nil; lastCleanup = nil
        defer { isCleaning = false; cleaningServerName = nil }
        let response = await server.perform(.cleanupStorage(targets: review.targets), timeout: .seconds(360))
        guard review.generation == server.connectionGeneration else {
            report = nil; reportGeneration = nil; needsRefresh = true
            error = "Cleanup was started on \(review.serverName). Reconnect to that server to check its result."
            return
        }
        guard let response, case .storageCleanup(let result) = response else {
            needsRefresh = true
            error = server.error ?? "Cleanup was not confirmed. Refresh storage before trying again."
            return
        }
        lastCleanup = result
        if let value = result.report {
            report = value; reportGeneration = review.generation
        } else {
            needsRefresh = true
        }
    }

    var diagnosticReport: String {
        var lines = ["Bloom Server storage", "Server: " + server.displayName]
        if let report {
            lines.append("Checked: " + report.checkedAt.ISO8601Format())
            if let total = report.totalBytes { lines.append("Total bytes: \(total)") }
            if let free = report.freeBytes { lines.append("Free bytes: \(free)") }
            if let message = report.dockerMessage { lines.append(message) }
            lines += report.usage.map { "\($0.kind): \($0.sizeLabel)" }
            lines += report.notes
        }
        for outcome in lastCleanup?.outcomes ?? [] { lines.append(outcome.target.title + ": " + outcome.message) }
        if let error { lines.append(error) }
        return ServerSetupDiagnostics.sanitise(lines.joined(separator: "\n"))
    }
}
