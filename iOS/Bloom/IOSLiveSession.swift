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
                guard let workspace = model.catalogue?.workspaces.first(where: { $0.id.rawValue == configuration.workspaceID }),
                      let session = model.catalogue?.sessions.first(where: { $0.id.rawValue == configuration.sessionID && $0.workspaceID == workspace.id }) else {
                    throw ConnectionFailure("The requested real workspace or conversation is not on this server.")
                }
                let split = BloomSplitController(model: model)
                window.overrideUserInterfaceStyle = .light
                window.rootViewController = split
                split.loadViewIfNeeded()
                (split.viewController(for: .primary) as? UINavigationController)?.topViewController?.loadViewIfNeeded()
                let desk = WorkspaceDeskController(connection: model, workspace: workspace)
                desk.preferredSessionID = session.id
                split.setViewController(BloomTheme.navigation(desk), for: .secondary)
                split.show(.secondary)
                window.bounds = CGRect(x: 0, y: 0, width: 1376, height: 1032)
                split.view.frame = window.bounds
                window.layoutIfNeeded()
                try status("Opening the real Laravel preview over SSH", workspace: workspace.id.rawValue, session: session.id.rawValue)
                try await desk.openLivePreview(address: configuration.previewAddress)
                for _ in 0..<90 {
                    try Task.checkCancellation()
                    if let failure = desk.livePreviewFailure { throw ConnectionFailure(failure) }
                    if desk.livePreviewReady && desk.liveMessageCount > 0 {
                        try await Task.sleep(for: .seconds(2))
                        window.layoutIfNeeded()
                        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                        }
                        try image.pngData()?.write(to: URL.documentsDirectory.appendingPathComponent("bloom-ipad-live.png"))
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
