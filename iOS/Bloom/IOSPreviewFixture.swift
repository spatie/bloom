#if DEBUG
import UIKit
import BloomClient

/// Explicit, network-free launch fixtures for checking the real UIKit screens on disposable
/// simulators. Release builds contain neither these examples nor the launch-argument hook.
@MainActor
enum IOSPreviewFixture {
    static func install(in window: UIWindow) {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--bloom-ui-preview"), arguments.indices.contains(index + 1) else { return }
        do {
            let catalogue = try JSONDecoder().decode(RemoteCatalogue.self, from: Data(catalogueJSON.utf8))
            let model = MobileConnection(previewCatalogue: catalogue)
            let split = BloomSplitController(model: model)
            window.rootViewController = split
            split.loadViewIfNeeded()
            (split.viewController(for: .primary) as? UINavigationController)?.topViewController?.loadViewIfNeeded()
            if arguments[index + 1] == "conversation" {
                let session = catalogue.sessions[0]
                let messages: [[String: Any]] = [
                    ["id": 1, "seq": 1, "kind": "user", "payload": try JSONSerialization.data(withJSONObject: ["text": "Add a quick reply to the inbox. It should feel effortless, and keep the conversation in view."]).base64EncodedString()],
                    ["id": 2, "seq": 2, "kind": "assistantText", "payload": try JSONSerialization.data(withJSONObject: ["text": "I'll add an inline composer to the ticket view and keep the focus on your conversation.\n\n**Here's the approach**\n\n1. Reuse the existing reply action.\n2. Keep drafts as you move between tickets.\n3. Add a keyboard shortcut for sending.\n\nThe reply action now accepts the draft directly:\n\n```php\n$ticket->reply(\n    message: $draft->body,\n    author: $user,\n);\n```\n\nThe focused tests are passing. I'm checking the empty and error states next."]).base64EncodedString()],
                ]
                let sessionData = try JSONSerialization.jsonObject(with: Data(sessionJSON.utf8))
                let data = try JSONSerialization.data(withJSONObject: ["session": sessionData, "messages": messages, "pendingQuestions": [], "isBusy": true, "streamingText": "", "queueError": NSNull()])
                let transcript = try JSONDecoder().decode(RemoteTranscript.self, from: data)
                split.setViewController(BloomTheme.navigation(ConversationController(model: model, session: session, preview: transcript)), for: .secondary)
                split.show(.secondary)
                if arguments.contains("--render-landscape") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        window.bounds = CGRect(x: 0, y: 0, width: 1210, height: 834)
                        split.view.frame = window.bounds
                        window.layoutIfNeeded()
                        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                        }
                        do { try image.pngData()?.write(to: URL.documentsDirectory.appendingPathComponent("bloom-landscape.png")) } catch {
                            NSLog("Bloom preview snapshot: %@", error.localizedDescription)
                        }
                    }
                }
            }
        } catch { assertionFailure("Invalid UI preview: \(error)") }
    }

    private static let sessionJSON = #"{"id":"11111111-1111-4111-8111-111111111111","workspaceID":"22222222-2222-4222-8222-222222222222","title":"A faster way to reply","model":"GPT-5.4","agentKind":"codex","state":"running"}"#
    private static var catalogueJSON: String {
        #"{"repositories":[{"id":"33333333-3333-4333-8333-333333333333","name":"there-there.app","path":"/projects/there-there.app","hidden":false},{"id":"44444444-4444-4444-8444-444444444444","name":"bloom","path":"/projects/bloom","hidden":false}],"workspaces":[{"id":"22222222-2222-4222-8222-222222222222","repoID":"33333333-3333-4333-8333-333333333333","name":"A faster way to reply","branch":"feature/quick-reply","setupState":"succeeded","setupLog":"","port":3190},{"id":"55555555-5555-4555-8555-555555555555","repoID":"33333333-3333-4333-8333-333333333333","name":"Polish the inbox","branch":"feature/inbox","setupState":"succeeded","setupLog":"","port":3191},{"id":"66666666-6666-4666-8666-666666666666","repoID":"44444444-4444-4444-8444-444444444444","name":"Work from anywhere","branch":"feature/mobile","setupState":"succeeded","setupLog":"","port":3192}],"sessions":["# + sessionJSON + "]}"
    }
}

struct PreviewRequestClient: RemoteRequesting {
    func request(_ command: RemoteCommand) async throws -> JSONValue {
        throw ConnectionFailure("This visual preview does not connect to a server.")
    }
}
#endif
