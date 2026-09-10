import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import BloomClient

/// A lease belongs to exactly one client and workspace. MCP callers never choose its client,
/// and attaching a second device cannot take over the first device's active UI.
public actor ServerUIBroker {
    public static let actionNames: Set<String> = [
        "pane_open", "pane_split", "pane_close", "pane_rename", "pane_list", "workspace_tabs", "workspace_tab_select",
        "browser_read", "browser_reload", "browser_go", "browser_screenshot", "browser_scroll", "browser_text",
        "terminal_start", "terminal_read", "terminal_write", "terminal_send_key", "media_show",
    ]
    private struct Attachment {
        let clientID: UUID
        let registrationID: UUID
        var lease: RemoteUILease
        let actions: Set<String>
        var expiry: Task<Void, Never>?
        var receipts: [UUID: Data] = [:]
        var receiptOrder: [UUID] = []
    }
    private struct Pending {
        let leaseID: UUID
        let request: RemoteUIRequest
        let reply: CheckedContinuation<RemoteUIResult, Never>
        let timer: Task<Void, Never>
        var claimed = false
    }
    private var attachments: [WorkspaceID: Attachment] = [:]
    private var pending: [UUID: Pending] = [:]
    private let now: @Sendable () -> Date
    private let leaseDuration: TimeInterval
    private let requestTimeout: Duration
    private var closed = false

    public init(leaseDuration: TimeInterval = 30, requestTimeout: Duration = .seconds(20), now: @escaping @Sendable () -> Date = Date.init) {
        self.leaseDuration = max(1, min(120, leaseDuration)); self.requestTimeout = requestTimeout; self.now = now
    }

    public func handle(_ operation: RemoteUIBridgeOperation, registrationID: UUID) async throws -> RemoteUIBridgeResult {
        sweep()
        guard !closed else { throw ServerFailure("The UI bridge is shutting down.") }
        switch operation {
        case .attach(let workspaceID, let clientID, let actions):
            guard actions.count <= Self.actionNames.count, Set(actions).isSubset(of: Self.actionNames) else {
                throw ServerFailure("This client requested unsupported UI actions. Update Bloom and reconnect.")
            }
            if let current = attachments[workspaceID] {
                guard current.clientID == clientID, current.registrationID == registrationID, current.actions == Set(actions) else {
                    throw ServerFailure("Another client is attached to this workspace's UI. Detach it or wait for its lease to expire.")
                }
                return .attached(current.lease)
            }
            let lease = RemoteUILease(id: UUID(), token: UUID().uuidString + UUID().uuidString, workspaceID: workspaceID,
                                      expiresAtMilliseconds: milliseconds(now().addingTimeInterval(leaseDuration)))
            attachments[workspaceID] = Attachment(clientID: clientID, registrationID: registrationID, lease: lease, actions: Set(actions))
            scheduleExpiry(workspaceID)
            return .attached(lease)
        case .poll(let id, let token, let wait):
            let workspaceID = try validate(id, token: token)
            let lease = renew(workspaceID)
            let deadline = ContinuousClock.now.advanced(by: wait ? .seconds(10) : .zero)
            while true {
                _ = try validate(id, token: token)
                let requests = pending.values.filter { $0.leaseID == id }.map(\.request).sorted { $0.expiresAtMilliseconds < $1.expiresAtMilliseconds }
                if !requests.isEmpty || ContinuousClock.now >= deadline { return .requests(.init(lease: lease, requests: requests)) }
                try await Task.sleep(for: .milliseconds(100))
                sweep()
            }
        case .claim(let id, let token, let requestID):
            _ = try validate(id, token: token)
            guard let call = pending[requestID], call.leaseID == id else { return .claimed(false) }
            pending[requestID]?.claimed = true
            return .claimed(true)
        case .respond(let id, let token, let requestID, let result):
            let workspaceID = try validate(id, token: token)
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let encoded = try encoder.encode(result)
            guard result.png.map({ $0.count <= BridgeToolImage.maximumBytes }) ?? true,
                  encoded.count <= 8 * 1_024 * 1_024 else {
                throw ServerFailure("The UI result is too large. Return less text or a smaller image.")
            }
            let digest = Data(SHA256.hash(data: encoded))
            if let previous = attachments[workspaceID]?.receipts[requestID] {
                guard previous == digest else { throw ServerFailure("A UI request cannot be answered twice with different results.") }
                return .accepted
            }
            guard let call = pending[requestID], call.leaseID == id, call.claimed else { throw ServerFailure("This UI request expired, was not claimed, or belongs to a different client.") }
            finish(requestID, result: result)
            attachments[workspaceID]?.receipts[requestID] = digest
            attachments[workspaceID]?.receiptOrder.append(requestID)
            if let oldest = attachments[workspaceID]?.receiptOrder.first, (attachments[workspaceID]?.receiptOrder.count ?? 0) > 128 {
                attachments[workspaceID]?.receiptOrder.removeFirst(); attachments[workspaceID]?.receipts[oldest] = nil
            }
            return .accepted
        case .detach(let id, let token):
            let workspaceID = try validate(id, token: token)
            revoke(workspaceID, reason: "The workspace UI disconnected before completing this action.")
            return .accepted
        }
    }

    public func perform(_ action: RemoteUIAction, workspaceID: WorkspaceID) async -> RemoteUIResult {
        sweep()
        guard !closed, let attachment = attachments[workspaceID] else {
            return .refusal("No client is attached to this workspace's UI. Open this workspace in Bloom and enable agent UI access, then retry.")
        }
        guard attachment.actions.contains(action.name) else { return .refusal("The attached client does not support \(action.name). Use a client that supports this action.") }
        guard action.arguments.objectValue != nil, (try? JSONEncoder().encode(action).count) ?? Int.max <= 65_536 else {
            return .refusal("The UI action contains too much data or invalid arguments.")
        }
        guard pending.values.filter({ $0.leaseID == attachment.lease.id }).count < 16 else { return .refusal("Too many UI actions are pending. Wait for them to finish before trying again.") }
        let id = UUID()
        let timeout = max(0, Double(requestTimeout.components.seconds) + Double(requestTimeout.components.attoseconds) / 1e18)
        let request = RemoteUIRequest(id: id, workspaceID: workspaceID, action: action,
                                      expiresAtMilliseconds: milliseconds(now().addingTimeInterval(timeout)))
        return await withTaskCancellationHandler {
            if Task.isCancelled { return .refusal("The UI action was cancelled.") }
            return await withCheckedContinuation { reply in
                let timer = Task { [weak self] in
                    do { try await Task.sleep(for: self?.requestTimeout ?? .zero) } catch { return }
                    await self?.finish(id, result: .refusal("The attached client did not complete this UI action in time. Check the workspace before retrying."))
                }
                pending[id] = Pending(leaseID: attachment.lease.id, request: request, reply: reply, timer: timer)
            }
        } onCancel: {
            Task { await self.finish(id, result: .refusal("The UI action was cancelled.")) }
        }
    }

    public func close(workspaceID: WorkspaceID) {
        revoke(workspaceID, reason: "This workspace was closed before completing the UI action.")
    }

    public func shutdown() {
        closed = true
        for workspaceID in Array(attachments.keys) { revoke(workspaceID, reason: "The server shut down before the UI action completed.") }
    }

    private func validate(_ id: UUID, token: String) throws -> WorkspaceID {
        guard let attachment = attachments.values.first(where: { $0.lease.id == id && $0.lease.token == token }) else {
            throw ServerFailure("This workspace UI lease expired or was revoked. Attach again.")
        }
        return attachment.lease.workspaceID
    }
    private func renew(_ workspaceID: WorkspaceID) -> RemoteUILease {
        let previous = attachments[workspaceID]!.lease
        let lease = RemoteUILease(id: previous.id, token: previous.token, workspaceID: workspaceID,
                                  expiresAtMilliseconds: milliseconds(now().addingTimeInterval(leaseDuration)))
        attachments[workspaceID]?.lease = lease
        scheduleExpiry(workspaceID)
        return lease
    }
    private func scheduleExpiry(_ workspaceID: WorkspaceID) {
        attachments[workspaceID]?.expiry?.cancel()
        let duration = leaseDuration
        attachments[workspaceID]?.expiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(duration)) } catch { return }
            await self?.sweep()
        }
    }
    private func sweep() {
        let stamp = milliseconds(now())
        for workspaceID in attachments.keys.filter({ attachments[$0]!.lease.expiresAtMilliseconds <= stamp }) {
            revoke(workspaceID, reason: "The workspace UI lease expired. Reopen the workspace before retrying.")
        }
        for id in pending.keys.filter({ pending[$0]!.request.expiresAtMilliseconds <= stamp }) {
            finish(id, result: .refusal("This UI action expired. Check the workspace before retrying."))
        }
    }
    private func revoke(_ workspaceID: WorkspaceID, reason: String) {
        guard let attachment = attachments.removeValue(forKey: workspaceID) else { return }
        attachment.expiry?.cancel()
        for id in pending.keys.filter({ pending[$0]!.leaseID == attachment.lease.id }) { finish(id, result: .refusal(reason)) }
    }
    private func finish(_ id: UUID, result: RemoteUIResult) {
        guard let call = pending.removeValue(forKey: id) else { return }
        call.timer.cancel(); call.reply.resume(returning: result)
    }
    private func milliseconds(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1_000) }
}
