import Foundation
import BloomCore

/// The app's half of `workspace_say`: putting a message in a chat, and taking one back out.
///
/// Every decision about who may write to whom, and what a message says when it arrives, is in the
/// core, in `WorkspaceSayTool` and `WorkspaceMessage`. What is here is what only the window can do:
/// pick the chat, drain its queue, and tell the sending chat when the owner cancels.
extension AppModel {
    /// Puts a message in a chat in its target workspace.
    ///
    /// The chat is the one that last wrote to the sender's workspace from there when this answers
    /// something, and the workspace's active chat otherwise. The delivery and its record are one
    /// store call, so a message is in a queue and visible to its sender, or neither.
    func deliverWorkspaceMessage(_ message: WorkspaceMessage) async -> WorkspaceMessageDeliveryOutcome {
        guard let store else { return .refused("Bloom's database is not open.") }
        guard let targetID = message.target.workspaceID,
              let workspace = workspaces.first(where: { $0.id == targetID })
        else {
            return .refused("The workspace '\(message.target.workspace)' is not open in Bloom any more.")
        }

        let model = model(for: workspace)
        guard let chat = await model.chatForWorkspaceMessage(preferring: message.replySessionID) else {
            return .refused("Bloom could not open a chat in '\(workspace.name)' to put it in.")
        }

        let queued: WorkspaceMessage
        do {
            queued = try await store.enqueueWorkspaceMessage(message, into: chat)
        } catch {
            return .refused("Bloom could not queue it: \(error.readableMessage)")
        }

        await model.drainWorkspaceMessage(into: chat)
        return .sent((try? await store.workspaceMessage(id: queued.id)) ?? queued)
    }

    /// Delete, pressed on the queued message in the chat it was sent to. The delivery is already
    /// gone and the store has marked the record; what is left is telling the sender.
    func noteDeliveryCancelled(_ deliveryID: DeliveryID) async {
        guard let store,
              let message = try? await store.workspaceMessage(deliveryID: deliveryID),
              message.state == .cancelled
        else { return }
        await tellSenderCancelled(message)
    }

    /// One row, for the bubble in the sending chat.
    func workspaceMessage(id: WorkspaceMessageID) async -> WorkspaceMessage? {
        try? await store?.workspaceMessage(id: id)
    }

    /// The link under a message: go to the workspace on the other end. Nothing, for one that has
    /// since been archived.
    func revealWorkspace(_ id: WorkspaceID?) {
        guard let id, workspaces.contains(where: { $0.id == id }) else { return }
        selection = .workspace(id)
    }

    private func tellSenderCancelled(_ message: WorkspaceMessage) async {
        guard let sourceID = message.source.workspaceID,
              let source = workspaces.first(where: { $0.id == sourceID })
        else { return }
        await model(for: source).tellWorkspaceMessageCancelled(message)
    }
}
