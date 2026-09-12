import Foundation
import Testing
@testable import BloomClient

@MainActor
struct RemoteUICancellationTests {
    @Test func aCancelledRequestAlreadyInTheBatchNeverExecutes() async {
        let host = CancellationUIHost(labels: ["first", "cancelled"])
        let gate = UIActionGate()
        var performed: [String] = []
        let client = RemoteUIClientSession(workspaceID: host.workspace, actions: ["pane_open"]) { action in
            let label = action.arguments["label"]?.stringValue ?? ""
            performed.append(label)
            if label == "first" { await gate.wait() }
            return .init(text: label)
        }
        client.start(using: RemoteWorkspaceService(client: host))
        await gate.waitForEntry()
        await host.cancel("cancelled")
        await gate.open()
        await host.waitForClaim("cancelled")
        client.stop()
        #expect(performed == ["first"])
    }

    @Test func cancellationOfAnInflightHandlerDoesNotWaitForItsCallback() async {
        let host = CancellationUIHost(labels: ["first", "next"])
        let gate = UIActionGate()
        var performed: [String] = []
        let client = RemoteUIClientSession(workspaceID: host.workspace, actions: ["pane_open"]) { action in
            let label = action.arguments["label"]?.stringValue ?? ""
            performed.append(label)
            if label == "first" { await gate.wait() }
            return .init(text: label)
        }
        client.start(using: RemoteWorkspaceService(client: host))
        await gate.waitForEntry()
        await host.cancel("first")
        await host.waitForResult("next")
        #expect(await host.results["first"] == nil)
        #expect(performed == ["first", "next"])
        // Release the intentionally uncooperative test callback after proving it did not hold
        // the client. Its late return cannot replace the cancellation or send another result.
        await gate.open()
        client.stop()
    }

    @Test func uncertainCancellationStatusCannotReplayAnAlreadyStartedAction() async {
        let host = CancellationUIHost(labels: ["retry"])
        let gate = UIActionGate()
        var performed = 0
        let client = RemoteUIClientSession(workspaceID: host.workspace, actions: ["pane_open"]) { _ in
            performed += 1
            await gate.wait()
            return .init(text: "late success")
        }
        client.start(using: RemoteWorkspaceService(client: host))
        await gate.waitForEntry()
        await host.loseNextClaim("retry")
        await host.waitForResult("retry")
        #expect(performed == 1)
        #expect(await host.results["retry"]?.isError == true)
        await gate.open()
        client.stop()
    }

    @Test func deadlineReturnsBeforeAnUncooperativeCallbackCompletes() async {
        let host = CancellationUIHost(labels: ["deadline"], lifetime: 500)
        let gate = UIActionGate()
        let client = RemoteUIClientSession(workspaceID: host.workspace, actions: ["pane_open"]) { _ in
            await gate.wait()
            return .init(text: "late success")
        }
        client.start(using: RemoteWorkspaceService(client: host))
        await gate.waitForEntry()
        await host.waitForResult("deadline")
        #expect(await host.results["deadline"]?.isError == true)
        #expect(await host.results["deadline"]?.text.contains("timed out") == true)
        await gate.open()
        client.stop()
    }
}

private actor CancellationUIHost: RemoteRequesting {
    nonisolated let workspace = WorkspaceID("cancellation-workspace")
    private let leaseID = UUID()
    private let labels: [String]
    private let ids: [String: UUID]
    private let lifetime: Int64
    private var delivered = false
    private var cancelled: Set<String> = []
    private var claims: Set<String> = []
    private var loseClaims: Set<String> = []
    private var claimWaits: [String: CheckedContinuation<Void, Never>] = [:]
    private var resultWaits: [String: CheckedContinuation<Void, Never>] = [:]
    private(set) var results: [String: RemoteUIResult] = [:]

    init(labels: [String], lifetime: Int64 = 60_000) {
        self.labels = labels; self.lifetime = lifetime
        ids = Dictionary(uniqueKeysWithValues: labels.map { ($0, UUID()) })
    }

    func cancel(_ label: String) { cancelled.insert(label) }
    func loseNextClaim(_ label: String) { loseClaims.insert(label) }
    func waitForClaim(_ label: String) async {
        if claims.contains(label) { return }
        await withCheckedContinuation { claimWaits[label] = $0 }
    }
    func waitForResult(_ label: String) async {
        if results[label] != nil { return }
        await withCheckedContinuation { resultWaits[label] = $0 }
    }

    func request(_ command: RemoteCommand) async throws -> JSONValue {
        let argument = try #require(command.operation["uiBridge"]?["_0"])
        let operation = try JSONDecoder().decode(RemoteUIBridgeOperation.self, from: JSONEncoder().encode(argument))
        let lease = RemoteUILease(id: leaseID, token: "fixture", workspaceID: workspace, expiresAtMilliseconds: Int64.max)
        let result: RemoteUIBridgeResult
        switch operation {
        case .attach: result = .attached(lease)
        case .poll:
            let requests = delivered ? [] : labels.map { label in
                RemoteUIRequest(id: ids[label]!, workspaceID: workspace,
                                action: .init(name: "pane_open", arguments: .object(["label": .string(label)])),
                                expiresAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000) + lifetime)
            }
            delivered = true
            result = .requests(.init(lease: lease, requests: requests))
        case .claim(_, _, let requestID):
            let label = try #require(ids.first { $0.value == requestID }?.key)
            claims.insert(label); claimWaits.removeValue(forKey: label)?.resume()
            if loseClaims.remove(label) != nil {
                delivered = false
                throw ConnectionFailure("Lost cancellation status reply")
            }
            result = .claimed(!cancelled.contains(label))
        case .respond(_, _, let requestID, let answer):
            let label = try #require(ids.first { $0.value == requestID }?.key)
            guard !cancelled.contains(label) else { throw ConnectionRefusal("The request was cancelled") }
            results[label] = answer; resultWaits.removeValue(forKey: label)?.resume()
            result = .accepted
        case .detach: result = .accepted
        }
        let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(result))
        return .object(["uiBridge": .object(["_0": encoded])])
    }
}

private actor UIActionGate {
    private var entered = false
    private var opened = false
    private var entry: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true; entry?.resume(); entry = nil
        guard !opened else { return }
        await withCheckedContinuation { release = $0 }
    }
    func waitForEntry() async {
        guard !entered else { return }
        await withCheckedContinuation { entry = $0 }
    }
    func open() { opened = true; release?.resume(); release = nil }
}
