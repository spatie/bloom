#if DEBUG
import UIKit
import BloomClient
import BloomSSH

/// An opt-in integration driver for the real app and server. It never fabricates catalogue,
/// transcript, review or browser content. The setup file contains public connection data only.
@MainActor
enum IOSLiveSession {
    private struct Configuration: Decodable {
        let ssh: SSHConfiguration
        let fingerprint: String
        let workspaceID: String
        let sessionID: String
        let previewAddress: String
    }

    static func install(in window: UIWindow, model: MobileConnection) -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--bloom-live-export-key") || arguments.contains("--bloom-live-session") else { return false }
        if arguments.contains("--bloom-live-export-key") {
            do {
                let publicKey = try SSHIdentity.publicKey(SSHCredentials.identity())
                try (publicKey + " bloom-ipad-live-validation\n").write(
                    to: URL.documentsDirectory.appendingPathComponent("bloom-live-device.pub"), atomically: true, encoding: .utf8)
                try status("Public key exported")
            } catch { record(error, window: window) }
            return true
        }
        Task {
            do {
                try status("Connecting to the real server")
                let configuration = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: URL.documentsDirectory.appendingPathComponent("bloom-live-connection.json")))
                guard configuration.fingerprint.hasPrefix("SHA256:"), configuration.fingerprint.count > 40 else {
                    throw ConnectionFailure("Supply the server fingerprint verified through the existing trusted SSH connection.")
                }
                // This pin is provided by the test operator through an already trusted SSH path.
                // It is not learned or accepted from the connection being tested.
                try SSHCredentials.trust(configuration.fingerprint, host: configuration.ssh.hostIdentity)
                try await model.connect(ssh: configuration.ssh)
                guard let workspace = model.catalogue?.workspaces.first(where: { $0.id.rawValue == configuration.workspaceID }) else {
                    throw ConnectionFailure("The requested real workspace is not on this server.")
                }
                let agentTest = arguments.contains("--bloom-live-agent")
                let session: RemoteSession
                if agentTest {
                    session = try await createAgentSession(workspace: workspace, model: model)
                } else {
                    guard let existing = model.catalogue?.sessions.first(where: { $0.id.rawValue == configuration.sessionID && $0.workspaceID == workspace.id }) else {
                        throw ConnectionFailure("The requested real conversation is not on this server.")
                    }
                    session = existing
                }
                let split = BloomSplitController(model: model)
                window.overrideUserInterfaceStyle = .light
                window.rootViewController = split
                split.loadViewIfNeeded()
                (split.viewController(for: .primary) as? UINavigationController)?.topViewController?.loadViewIfNeeded()
                let desk = split.openWorkspace(workspace, preferredSessionID: session.id)
                let phone = arguments.contains("--bloom-live-phone")
                if !phone { window.bounds = CGRect(x: 0, y: 0, width: 1376, height: 1032) }
                split.view.frame = window.bounds
                window.layoutIfNeeded()
                try status("Opening the real Laravel preview over SSH", workspace: workspace.id.rawValue, session: session.id.rawValue)
                if phone && !agentTest {
                    for _ in 0..<30 where desk.liveMessageCount == 0 {
                        try await Task.sleep(for: .seconds(1))
                    }
                }
                if arguments.contains("--bloom-live-terminal") {
                    let terminal = try await desk.verifyLiveTerminal()
                    try JSONSerialization.data(withJSONObject: terminal, options: [.prettyPrinted, .sortedKeys]).write(
                        to: URL.documentsDirectory.appendingPathComponent("bloom-live-terminal.json"), options: .atomic)
                }
                if agentTest {
                    for _ in 0..<30 where !desk.liveUIAttached {
                        if let failure = desk.liveUIFailure { throw ConnectionFailure(failure) }
                        try await Task.sleep(for: .seconds(1))
                    }
                    guard desk.liveUIAttached, let service = model.service else { throw ConnectionFailure("The iPad workspace did not attach its UI tools to the server.") }
                    let prompt = "Use only Bloom UI MCP tools for this verification. Call pane_open to open \(configuration.previewAddress) in a browser, then call browser_text on that browser and tell me the actual visible page heading. Stop after reporting it. Do not run shell commands, change files, or create other workspaces."
                    _ = try await service.client.request(.send(sessionID: session.id, text: prompt))
                    try status("Agent asked to open and read the real Laravel page", workspace: workspace.id.rawValue, session: session.id.rawValue)
                } else {
                    try await desk.openLivePreview(address: configuration.previewAddress)
                }
                for _ in 0..<180 {
                    try Task.checkCancellation()
                    if let failure = desk.livePreviewFailure { throw ConnectionFailure(failure) }
                    if agentTest, let failure = desk.liveUIFailure { throw ConnectionFailure(failure) }
                    if desk.livePreviewReady && desk.liveMessageCount > 0 && desk.liveFilesReady {
                        if agentTest, !(try await agentFinished(sessionID: session.id, model: model)) {
                            try await Task.sleep(for: .seconds(1))
                            continue
                        }
                        try await Task.sleep(for: .seconds(2))
                        let folderCount = try desk.verifyLiveTree()
                        try "Verified \(folderCount) real change folders: disclosure, filtering and restoration.\n".write(
                            to: URL.documentsDirectory.appendingPathComponent("bloom-live-tree-status.txt"), atomically: true, encoding: .utf8)
                        (split.viewController(for: .primary) as? UINavigationController)?.viewControllers.compactMap { $0 as? ProjectsController }.first?.selectWorkspace(workspace.id, reveal: true)
                        window.layoutIfNeeded()
                        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                        }
                        try image.pngData()?.write(to: URL.documentsDirectory.appendingPathComponent("bloom-ipad-live.png"))
                        if phone {
                            desk.focusLiveConversation()
                            try await Task.sleep(for: .seconds(1))
                            window.layoutIfNeeded()
                            let chatImage = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                            }
                            try chatImage.pngData()?.write(to: URL.documentsDirectory.appendingPathComponent("bloom-iphone-live-chat.png"))
                        }
                        if arguments.contains("--bloom-live-options") {
                            try await desk.showLiveOptions()
                            try await Task.sleep(for: .seconds(2))
                            window.layoutIfNeeded()
                            let optionsImage = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                            }
                            try optionsImage.pngData()?.write(to: URL.documentsDirectory.appendingPathComponent("bloom-ipad-live-options.png"))
                        }
                        if arguments.contains("--bloom-live-review") {
                            split.dismiss(animated: false)
                            desk.openReview(all: true)
                            for _ in 0..<45 {
                                if let failure = desk.liveReviewFailure { throw ConnectionFailure(failure) }
                                if desk.liveReviewReady { break }
                                try await Task.sleep(for: .seconds(1))
                            }
                            guard desk.liveReviewReady else { throw ConnectionFailure("Visible review patches did not load.") }
                            window.layoutIfNeeded()
                            let reviewImage = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                            }
                            try reviewImage.pngData()?.write(to: URL.documentsDirectory.appendingPathComponent("bloom-live-review.png"))
                        }
                        try status("Captured live server workspace", workspace: workspace.id.rawValue, session: session.id.rawValue,
                                   messages: desk.liveMessageCount, page: desk.livePreviewTitle)
                        return
                    }
                    try await Task.sleep(for: .seconds(1))
                }
                throw ConnectionFailure("Timed out waiting for both the live conversation and Laravel page to load.")
            } catch { record(error, window: window) }
        }
        return true
    }

    private static func agentFinished(sessionID: SessionID, model: MobileConnection) async throws -> Bool {
        guard let service = model.service else { throw ConnectionFailure("The server disconnected during agent verification.") }
        let transcript = try await service.transcript(sessionID: sessionID, after: 0)
        if let error = transcript.queueError { throw ConnectionFailure(error) }
        let tools = transcript.messages.filter { $0.kind == "toolUse" }.map { String(decoding: $0.payload, as: UTF8.self) }
        return !transcript.isBusy && tools.contains { $0.contains("pane_open") }
            && tools.contains { $0.contains("browser_text") }
            && transcript.messages.contains { $0.kind == "assistantText" && !$0.text.isEmpty }
    }

    private static func createAgentSession(workspace: RemoteWorkspace, model: MobileConnection) async throws -> RemoteSession {
        guard let service = model.service else { throw ConnectionFailure("The server disconnected before agent verification.") }
        let context = try await service.workspaceContext(projectID: workspace.repoID)
        guard context.composer.availableAgents?.contains(.codex) == true,
              let chosen = context.composer.models.first(where: { $0.isDefault && !$0.hidden }) ?? context.composer.models.first(where: { !$0.hidden }) else {
            throw ConnectionFailure("A signed-in Codex agent is required for this opt-in verification.")
        }
        let result = try await service.client.request(.call("workspace", ["workspaceID": .string(workspace.id.rawValue),
            "action": .object(["newSession": .object(["agent": .string(AgentKind.codex.rawValue), "model": .string(chosen.id),
                "effort": .string(chosen.resolvedEffort(preferring: "medium")), "permissionMode": .string(PermissionMode.autoReview.rawValue)])])]))
        guard let value = result["created"]?["session"] else { throw ConnectionFailure("The server did not create the agent verification conversation.") }
        let session = try JSONDecoder().decode(RemoteSession.self, from: JSONEncoder().encode(value))
        _ = try await service.client.request(.call("renameSession", ["sessionID": .string(session.id.rawValue), "title": .string("iPad MCP verification")]))
        let record = ["workspaceID": workspace.id.rawValue, "sessionID": session.id.rawValue]
        try JSONSerialization.data(withJSONObject: record).write(to: URL.documentsDirectory.appendingPathComponent("bloom-live-agent.json"), options: .atomic)
        try await model.refresh()
        return model.catalogue?.sessions.first { $0.id == session.id } ?? session
    }

    private static func status(_ phase: String, workspace: String = "", session: String = "", messages: Int = 0, page: String = "") throws {
        let value: [String: Any] = ["phase": phase, "workspaceID": workspace, "sessionID": session, "messages": messages, "pageTitle": page,
                                  "time": ISO8601DateFormatter().string(from: Date())]
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL.documentsDirectory.appendingPathComponent("bloom-live-status.json"), options: .atomic)
    }

    private static func record(_ error: Error, window: UIWindow) {
        do { try status("Failed: " + error.localizedDescription) } catch { NSLog("Live test status could not be written: %@", error.localizedDescription) }
        window.rootViewController?.show(error)
    }
}
#endif
