#if DEBUG
import UIKit
import BloomClient

/// Runs the production workspace controllers against deterministic protocol replies for visual checks.
@MainActor
enum WorkspacePreviewFixture {
    static func install(in window: UIWindow, mode: String) throws {
        let catalogueValue: [String: Any] = [
            "repositories": [["id": repoID, "name": "there-there.app", "path": "/projects/there-there.app", "hidden": false],
                             ["id": "44444444-4444-4444-8444-444444444444", "name": "bloom", "path": "/projects/bloom", "hidden": false]],
            "workspaces": [["id": workspaceID, "repoID": repoID, "name": "Quick replies", "branch": "feature/quick-replies", "setupState": "succeeded", "setupLog": "", "port": 3190],
                           ["id": "55555555-5555-4555-8555-555555555555", "repoID": repoID, "name": "Polish the inbox", "branch": "feature/inbox", "setupState": "succeeded", "setupLog": "", "port": 3191]],
            "sessions": [session],
        ]
        let catalogue = try JSONDecoder().decode(RemoteCatalogue.self, from: JSONSerialization.data(withJSONObject: catalogueValue))
        let transcript = try JSONDecoder().decode(RemoteTranscript.self, from: JSONSerialization.data(withJSONObject: transcriptValue))
        let client = WorkspacePreviewRequestClient(catalogue: try value(catalogueValue), transcript: try value(transcriptValue), files: try value(changedFiles), patches: patches, source: source)
        let connection = MobileConnection(previewCatalogue: catalogue, client: client)
        let split = BloomSplitController(model: connection)
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = split
        split.loadViewIfNeeded()
        (split.viewController(for: .primary) as? UINavigationController)?.topViewController?.loadViewIfNeeded()
        let desk = WorkspaceDeskController(connection: connection, workspace: catalogue.workspaces[0])
        desk.fixtureTranscript = transcript
        desk.fixturePreviewHTML = browserHTML
        split.setViewController(BloomTheme.navigation(desk), for: .secondary)
        split.show(.secondary)
        desk.configurePreview(mode: mode)
        // Render the real UIKit hierarchy at a 13-inch iPad's landscape size without opening Simulator.app.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if !ProcessInfo.processInfo.arguments.contains("--native-size") {
                window.bounds = CGRect(x: 0, y: 0, width: 1376, height: 1032)
            }
            split.view.frame = window.bounds
            window.layoutIfNeeded()
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                window.layoutIfNeeded()
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                do {
                    try image.pngData()?.write(to: URL.documentsDirectory.appendingPathComponent("bloom-ipad-\(mode).png"))
                } catch { NSLog("Workspace preview capture: %@", error.localizedDescription) }
            }
        }
    }

    private static func value(_ object: Any) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private static let repoID = "33333333-3333-4333-8333-333333333333"
    private static let workspaceID = "22222222-2222-4222-8222-222222222222"
    private static var session: [String: Any] {
        ["id": "11111111-1111-4111-8111-111111111111", "workspaceID": workspaceID,
         "title": "A faster way to reply", "model": "GPT-5.4", "agentKind": "codex", "state": "idle"]
    }
    private static var transcriptValue: [String: Any] {
        get throws {
            let messages: [[String: Any]] = [
                ["id": 1, "seq": 1, "kind": "user", "payload": try JSONSerialization.data(withJSONObject: ["text": "Add quick replies to the inbox. Keep the conversation in view and make it feel effortless."]).base64EncodedString()],
                ["id": 2, "seq": 2, "kind": "assistantText", "payload": try JSONSerialization.data(withJSONObject: ["text": "The quick reply is ready to try.\n\n### What changed\n\n- An inline composer keeps the ticket in view.\n- Drafts stay with each conversation.\n- **⌘ Return** sends your reply.\n\nThe reply action reuses the existing ticket permissions and notification flow.\n\n```php\n$reply = $ticket->reply(\n    message: $data->message,\n    author: $user,\n);\n```\n\n### Checked\n\n- [x] Reply appears in the conversation\n- [x] Draft clears after a successful send\n- [x] Empty replies are rejected\n\nOpen the preview to try it, or review the changed files alongside this conversation."]).base64EncodedString()],
            ]
            return ["session": session, "messages": messages, "pendingQuestions": [], "isBusy": false, "streamingText": "", "queueError": NSNull()]
        }
    }
    private static var changedFiles: [[String: Any]] {
        patches.keys.sorted().map { path in
            let diff = DiffParser.parse(patches[path] ?? "").first
            return ["path": path, "change": diff?.isNew == true ? "A" : "M", "additions": diff?.additions ?? 0,
                    "deletions": diff?.deletions ?? 0, "isBinary": false, "hasIncompleteStats": false]
        }
    }
    private static let patches: [String: String] = [
        "app/Actions/ReplyToTicket.php": """
        diff --git a/app/Actions/ReplyToTicket.php b/app/Actions/ReplyToTicket.php
        --- a/app/Actions/ReplyToTicket.php
        +++ b/app/Actions/ReplyToTicket.php
        @@ -18,8 +18,14 @@ public function execute(Ticket $ticket, ReplyData $data): Reply
             {
        -        $reply = new Reply();
        -        $reply->message = $data->message;
        -        $ticket->replies()->save($reply);
        +        Gate::authorize('reply', $ticket);
        +
        +        $reply = $ticket->reply(
        +            message: $data->message,
        +            author: auth()->user(),
        +        );
        +
        +        $ticket->markAsRead();
        +        ReplyCreated::dispatch($reply);
        \u{20}
                 return $reply;
             }
        """,
        "resources/js/components/QuickReply.tsx": """
        diff --git a/resources/js/components/QuickReply.tsx b/resources/js/components/QuickReply.tsx
        new file mode 100644
        --- /dev/null
        +++ b/resources/js/components/QuickReply.tsx
        @@ -0,0 +1,12 @@
        +import { useForm } from '@inertiajs/react';
        +import { Button } from '@/components/Button';
        +
        +export function QuickReply({ ticket }: Props) {
        +    const form = useForm({ message: '' });
        +
        +    function send() {
        +        form.post(route('replies.store', ticket), {
        +            preserveScroll: true,
        +            onSuccess: () => form.reset(),
        +        });
        +    }
        """,
        "resources/js/pages/Ticket.tsx": """
        diff --git a/resources/js/pages/Ticket.tsx b/resources/js/pages/Ticket.tsx
        --- a/resources/js/pages/Ticket.tsx
        +++ b/resources/js/pages/Ticket.tsx
        @@ -64,4 +64,5 @@ export default function Ticket({ ticket }: Props) {
                 <Conversation messages={ticket.messages} />
        -        <ReplyModal ticket={ticket} />
        +        <QuickReply ticket={ticket} />
             </TicketLayout>
         }
        """,
        "tests/Feature/ReplyToTicketTest.php": """
        diff --git a/tests/Feature/ReplyToTicketTest.php b/tests/Feature/ReplyToTicketTest.php
        --- a/tests/Feature/ReplyToTicketTest.php
        +++ b/tests/Feature/ReplyToTicketTest.php
        @@ -32,3 +32,9 @@
         it('creates a reply', function () {
        +    $this->actingAs($user)
        +        ->post(route('replies.store', $ticket), [
        +            'message' => 'Thanks, that worked!',
        +        ])
        +        ->assertRedirect();
        +
             expect($ticket->replies)->toHaveCount(1);
         });
        """,
    ]
    private static let source = """
    <?php

    namespace App\\Actions;

    use App\\Data\\ReplyData;
    use App\\Events\\ReplyCreated;
    use App\\Models\\Reply;
    use App\\Models\\Ticket;
    use Illuminate\\Support\\Facades\\Gate;

    class ReplyToTicket
    {
        public function execute(Ticket $ticket, ReplyData $data): Reply
        {
            Gate::authorize('reply', $ticket);

            $reply = $ticket->reply(
                message: $data->message,
                author: auth()->user(),
            );

            $ticket->markAsRead();
            ReplyCreated::dispatch($reply);

            return $reply;
        }
    }
    """
    private static let browserHTML = """
    <!doctype html><html lang="en"><meta name="viewport" content="width=device-width, initial-scale=1"><style>
    *{box-sizing:border-box}body{margin:0;background:#fff;color:#303436;font:14px -apple-system,BlinkMacSystemFont,sans-serif}header{padding:22px 24px;border-bottom:1px solid #e7ebea;display:flex;align-items:center;justify-content:space-between}.brand{font-size:20px;font-weight:750;letter-spacing:-.7px;color:#263d32}.avatar{border-radius:50%;background:#e9eee9;color:#516656;padding:8px;font-size:12px}.sub{font-size:12px;color:#87918c}.crumb{padding:18px 24px;background:#f9faf9;border-bottom:1px solid #eef0ee;color:#7b867f;font-size:12px}main{padding:26px 24px}h1{font-size:23px;letter-spacing:-.6px;line-height:1.3;margin:12px 0}p{line-height:1.7;color:#626b65}.badge{display:inline-block;background:#e8f3eb;color:#337544;padding:5px 9px;border-radius:6px;font-size:11px;font-weight:650}.line{display:flex;gap:10px;align-items:center;margin:26px 0 12px}.person{font-weight:650;font-size:13px}.time{margin-left:auto;color:#969f99;font-size:11px}.message{border:1px solid #e4e9e5;border-radius:10px;padding:16px 18px;margin:12px 0 26px;background:#fff}.message p{margin:0 0 12px}.message p:last-child{margin:0}.reply{border:1px solid #b6cbbd;border-radius:10px;overflow:hidden;box-shadow:0 0 0 3px #f3f7f4}.replylabel{padding:12px 16px;background:#f9fbf9;font-size:12px;color:#677a6d;border-bottom:1px solid #e5ece7}textarea{display:block;width:100%;border:0;resize:none;min-height:120px;font:14px -apple-system;padding:16px;outline:none;color:#36493d}.footer{padding:12px 14px;display:flex;align-items:center;justify-content:space-between;font-size:11px;color:#88948c}button{border:0;border-radius:6px;background:#426b50;color:white;font-weight:600;padding:10px 16px}.context{margin-top:24px;border-top:1px solid #e9ede9;padding-top:18px;color:#8a948d;font-size:12px;line-height:2}
    </style><header><div class="brand">there there<span style="color:#92b29b">.</span></div><div class="avatar">FM</div></header><div class="crumb">Inbox &nbsp; / &nbsp; #1042</div><main><span class="badge">OPEN</span><h1>A question about our subscription</h1><div class="sub">Customer support &nbsp; · &nbsp; Assigned to you</div><div class="line"><div class="avatar">AL</div><div class="person">Alex Laurent</div><div class="time">12 minutes ago</div></div><div class="message"><p>Hi there,</p><p>We're growing our team next month. Can we add a few seats to our current plan?</p><p>Thanks!<br>Alex</p></div><div class="reply"><div class="replylabel">Reply to Alex</div><textarea>Hi Alex, absolutely! You can add seats in your team settings. Happy to help you get everything set up.</textarea><div class="footer"><span>⌘ Return to send</span><button onclick="this.textContent='Reply sent';this.disabled=true">Send reply</button></div></div><div class="context">Ticket #1042 &nbsp; · &nbsp; Created today<br>alex@example.com</div></main></html>
    """
}

private struct WorkspacePreviewRequestClient: RemoteRequesting {
    let catalogue: JSONValue
    let transcript: JSONValue
    let files: JSONValue
    let patches: [String: String]
    let source: String

    func request(_ command: RemoteCommand) async throws -> JSONValue {
        if command.operation["catalogue"] != nil { return .object(["catalogue": .object(["_0": catalogue])]) }
        if command.operation["transcript"] != nil { return .object(["transcript": .object(["_0": transcript])]) }
        if let arguments = command.operation["reviewSnapshot"] {
            let payload: JSONValue = .object(["revision": .string("preview-1"), "files": arguments["knownRevision"]?.stringValue == "preview-1" ? .null : files])
            return .object(["reviewSnapshot": .object(["_0": payload])])
        }
        if let arguments = command.operation["reviewPatch"], let path = arguments["path"]?.stringValue {
            return .object(["reviewPatch": .object(["_0": .object(["revision": .string("preview-1"), "patch": .string(patches[path] ?? "")])])])
        }
        if command.operation["workspace"] != nil {
            let paths = patches.keys.sorted() + ["app/Models/Ticket.php", "app/Models/Reply.php", "config/app.php", "routes/web.php", "composer.json", "package.json", "README.md"]
            return .object(["files": .object(["_0": .array(paths.map(JSONValue.string))])])
        }
        if let arguments = command.operation["file"], let path = arguments["path"]?.stringValue {
            return .object(["file": .object(["_0": .object(["path": .string(path), "text": .string(source), "revision": .string("preview-1")])])])
        }
        throw ConnectionFailure("This sample workspace does not send commands to a server.")
    }
}
#endif
