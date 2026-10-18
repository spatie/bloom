import AppKit
import Observation
import BloomCore

/// Mailpit's mailbox, for the whole app: the connection, the list, the search and the selection.
/// One connection feeds the app-wide Mail destination.
///
/// What changes the list is `MailboxList`, and what the loop decides at each step (what the
/// connection is and how long to wait) is `MailboxLink`, both in the core with their
/// tests. This is the part neither can be: the requests, the socket, the timers.
///
/// The loop that starts the inbox and keeps the websocket open is one task, `loop`. While the
/// server starts it probes each second; once connected, a dropped socket is retried with a
/// backoff. A changed SMTP port or switch in Settings cancels the loop and starts again.
@MainActor
@Observable
final class Mailbox {
    static let shared = Mailbox()

    private(set) var link: MailboxLink
    private(set) var list = MailboxList()
    /// Whether the list has been read at all since the connection came up, which is the difference
    /// between "no mail" and "not asked yet".
    private(set) var hasReadList = false
    private(set) var isLoadingPage = false
    let address = MailpitSettings.bundledAddress(forBundleIdentifier: Bundle.main.bundleIdentifier)
    private(set) var smtpPort = MailpitSettings.bundledPorts(forBundleIdentifier: Bundle.main.bundleIdentifier).smtp
    private(set) var bundledError: String?
    private(set) var bundledFailure: BundledMailServer.Failure?
    private(set) var client: MailpitClient?
    /// The row selected in Mail's list. One for the app, like the list it is a row of.
    private(set) var selection: MailpitMessageID?
    /// Moved by every message Mailpit reports leaving the mailbox, whoever removed it. The reader
    /// watches this and asks again, so a message deleted from Mailpit's own UI does not stay on
    /// screen looking as if it were still there.
    ///
    /// Moved by the websocket's frames only, never by a delete Bloom asked for as well: the frame
    /// for that delete follows a moment later, and moving it twice made the reader fetch twice.
    private(set) var removals = 0
    /// Something the reader asked for that did not happen, said once under the search field.
    var notice: PaneNoticeContent?

    /// The search field. Debounced into a new first page: see `scheduleSearch`.
    var query = "" {
        didSet {
            guard MailboxList.normalised(query) != MailboxList.normalised(oldValue) else { return }
            scheduleSearch()
        }
    }

    var connection: MailboxConnection { link.connection }

    /// The bridge may send only through this app's connected server, never another process that
    /// happens to occupy the configured SMTP port while our inbox cannot start.
    var mailSendPort: Int? {
        guard link.presence.isEnabled, connection == .live,
              bundledServer.isServing(smtpPort: smtpPort) else { return nil }
        return smtpPort
    }

    /// Bridge readers use only this app's live bundled inbox, not another service on its API port.
    var mailReadClient: MailpitClient? {
        guard mailSendPort != nil else { return nil }
        return client
    }

    @ObservationIgnored private var started = false
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var search: Task<Void, Never>?
    @ObservationIgnored private var settingsChange: Task<Void, Never>?
    @ObservationIgnored private let bundledServer = BundledMailServer()

    private init() {
        link = MailboxLink(isEnabled: Self.storedEnabled)
    }

    // MARK: - Starting

    /// Called once, from `AppModel.bootstrap`.
    func start() {
        guard !started else { return }
        started = true
        // The bundled server may have stopped unexpectedly. Coming to the front prompts another
        // look, rather than waiting for the next background probe.
        // swiftlint:disable:next discarded_notification_center_observer
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { Mailbox.shared.lookAgainIfDown() }
        }
        // Settings > Incoming mails writes the defaults, and this is the one place that hears them,
        // rather than a pair of `onChange` handlers in the view that every other place editing
        // them would have to repeat.
        // swiftlint:disable:next discarded_notification_center_observer
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: UserDefaults.standard, queue: .main
        ) { _ in
            MainActor.assumeIsolated { Mailbox.shared.settingsChanged() }
        }
        // Closing the pipe lets the supervisor stop its server on a clean quit. The same EOF is
        // delivered by the system if Bloom crashes.
        // swiftlint:disable:next discarded_notification_center_observer
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { Mailbox.shared.bundledServer.stop() }
        }
        // Read again rather than trusting `init`: the sidebar can build this model before
        // bootstrap starts it, and Settings may have moved in between.
        link.reconfigure(isEnabled: Self.storedEnabled)
        restart()
    }

    /// Settings moved. Debounced so a port edit and a switch change made together cause one
    /// restart rather than two.
    ///
    /// Compared before anything is scheduled, because the notification behind this fires for every
    /// default the app writes, not only these two. And compared again after the wait: a port typed
    /// back to what it was, or a switch flipped back inside it, is no change.
    private func settingsChanged() {
        guard Self.storedEnabled != link.presence.isEnabled
                || Self.storedSMTPPort != smtpPort else {
            settingsChange?.cancel()
            settingsChange = nil
            return
        }
        settingsChange?.cancel()
        settingsChange = Task {
            try? await Task.sleep(for: .milliseconds(600))
            let isEnabled = Self.storedEnabled
            guard !Task.isCancelled,
                  isEnabled != link.presence.isEnabled
                    || Self.storedSMTPPort != smtpPort else { return }
            link.reconfigure(isEnabled: isEnabled)
            restart()
        }
    }

    /// The Try Again in the inspector.
    func retry() {
        restart()
    }

    private func lookAgainIfDown() {
        guard link.looksAgainOnActivation else { return }
        restart()
    }

    private func restart() {
        loop?.cancel()
        let previousPort = smtpPort
        smtpPort = Self.storedSMTPPort
        if !link.presence.isEnabled || smtpPort != previousPort { bundledServer.stop() }
        bundledError = nil
        bundledFailure = nil
        let client = MailpitClient(base: URL(string: address)!)
        // Off means off: with no client the reader stops fetching too.
        self.client = link.presence.isEnabled ? client : nil
        link.startLooking()
        guard self.client != nil else {
            link.stopLooking()
            forgetMailbox()
            return
        }
        loop = Task { await run(client) }
    }

    private func forgetMailbox() {
        list = MailboxList()
        hasReadList = false
        selection = nil
    }

    // MARK: - The loop

    /// Looks, listens while Mailpit answers, waits, and looks again. Every decision between those
    /// steps is `MailboxLink`'s.
    private func run(_ client: MailpitClient) async {
        while !Task.isCancelled {
            let defaults = MailpitSettings.bundledPorts(forBundleIdentifier: Bundle.main.bundleIdentifier)
            guard MailpitSettings.isValidSMTPPort(smtpPort, forBundleIdentifier: Bundle.main.bundleIdentifier) else {
                bundledError = "Choose an SMTP port from 1024 to 65535, other than \(defaults.api)."
                bundledFailure = .invalidSMTPPort(smtpPort)
                _ = link.probed(.failure(.unreachable))
                return
            }
            do {
                try bundledServer.start(ports: .init(smtp: smtpPort, api: defaults.api))
            } catch BundledMailServer.Failure.restarting {
                try? await Task.sleep(for: .milliseconds(100))
                continue
            } catch {
                bundledFailure = error as? BundledMailServer.Failure
                bundledError = error.localizedDescription
                _ = link.probed(.failure(.unreachable))
                try? await Task.sleep(for: .seconds(2))
                continue
            }
            bundledError = nil
            bundledFailure = nil
            let answer = await client.info()
            // **Cancelled while the request was out means a restart has already begun**, for a new
            // address or with the switch off. Without this the old loop landed its answer on the
            // new state: it marked a server that had never answered as answered and set the
            // connection beside it.
            guard !Task.isCancelled else { return }
            if case .failure = answer, !bundledServer.isRunning {
                let ports = MailpitSettings.Ports(smtp: smtpPort, api: defaults.api)
                bundledFailure = BundledMailServer.portConflict(for: ports)
                bundledError = bundledFailure?.localizedDescription ?? "The inbox stopped while starting. Try again."
            }
            let pause: Duration
            switch link.probed(answer) {
            case .listen:
                let dropped = await listen(client)
                guard !Task.isCancelled else { return }
                pause = link.dropped(dropped)
            case .wait(let wait):
                // The bundled process may still be opening its listeners on the first probe.
                // It gets another look promptly after startup or a crash.
                pause = min(wait, .seconds(1))
            }
            do {
                try await Task.sleep(for: pause)
            } catch {
                // Cancelled, which is a restart or the switch going off. The new loop, if there is
                // one, has already been started by whoever cancelled this.
                return
            }
        }
    }

    /// Opens the websocket, reads the first page once it is open, and follows the frames until the
    /// socket drops or the task is cancelled.
    ///
    /// The page is read **after** the socket is up rather than before, so nothing that arrives in
    /// between is lost: a message delivered while the page is in flight is either on the page, or
    /// in a frame the socket is holding, and `MailboxList` takes it once whichever way it comes.
    ///
    /// - Returns: why it stopped following, for the loop to say while it waits to try again.
    private func listen(_ client: MailpitClient) async -> MailpitFailure {
        let socket = Self.events.webSocketTask(with: client.eventsURL)
        socket.resume()
        defer { socket.cancel(with: .goingAway, reason: nil) }

        // A list that could not be read is not a live one, however open the socket is. Going
        // `.live` regardless left the pane on "Reading the mailbox" for good, with nothing retrying.
        if let failure = await reloadFirstPage(from: client) { return failure }
        guard !Task.isCancelled else { return .unreachable }
        link.listening()

        return await withTaskCancellationHandler {
            while !Task.isCancelled {
                let frame: URLSessionWebSocketTask.Message
                do {
                    frame = try await socket.receive()
                } catch {
                    // The socket dropped: Mailpit stopped, or the network under it went. The loop
                    // above says so and tries again.
                    return .unreachable
                }
                let event: MailpitEvent? = switch frame {
                case .string(let text): MailpitEvent.parse(text)
                case .data(let data): MailpitEvent.parse(data)
                @unknown default: nil
                }
                if let event { await apply(event, from: client) }
            }
            return .unreachable
        } onCancel: {
            socket.cancel(with: .goingAway, reason: nil)
        }
    }

    private func apply(_ event: MailpitEvent, from client: MailpitClient) async {
        switch event {
        case .delete, .truncate, .prune: removals += 1
        default: break
        }
        if list.apply(event) == .reload { await reloadFirstPage(from: client) }
    }

    /// The socket's own session rather than the shared one. A websocket task is held to
    /// `timeoutIntervalForRequest` between frames, the shared session's is sixty seconds, and
    /// Mailpit pings every fifty-four (`pingPeriod` in its `websockets/client.go`): six seconds of
    /// slack between an idle mailbox and a reconnect that reloads the list. Ten minutes is a cap
    /// on a socket that has gone silent without closing, not a measurement; a Mailpit that stops
    /// closes its sockets, and that is noticed at once.
    private static let events: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 600
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    // MARK: - Pages

    private func scheduleSearch() {
        search?.cancel()
        search = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let client else { return }
            // Said only over a live list. A disconnected one already has its band saying why, and
            // a notice per search typed into it would be the same sentence again.
            if let failure = await reloadFirstPage(from: client), connection == .live {
                notice = PaneNoticeContent(tone: .failure, title: "Could not search incoming mails", message: failure.message)
            }
        }
    }

    /// Reads the first page for the search in the field.
    ///
    /// The page is dropped when it no longer answers anything: the search changed while it was out
    /// (the newer search's own page is on its way), or the client did, because Settings pointed
    /// Bloom at another Mailpit and this is the old one's mail.
    ///
    /// - Returns: the failure, or nil for a page adopted or deliberately dropped.
    @discardableResult
    private func reloadFirstPage(from client: MailpitClient) async -> MailpitFailure? {
        let asked = query
        let result = await client.page(query: asked, start: 0)
        guard isCurrent(client),
              MailboxList.normalised(asked) == MailboxList.normalised(query) else { return nil }
        switch result {
        case .success(let page):
            list.adopt(page, query: asked)
            hasReadList = true
            if let selection, !list.contains(selection) { self.selection = nil }
            return nil
        case .failure(let failure):
            // The connection is the loop's to change: a first page that fails inside `listen` is
            // returned to it as the reason the socket is dropped.
            return failure
        }
    }

    /// The next page, when the last row scrolls into view.
    func loadMore() {
        guard let client, !isLoadingPage, list.hasMore else { return }
        isLoadingPage = true
        let asked = list.query
        let start = list.nextStart
        Task {
            defer { isLoadingPage = false }
            guard case .success(let page) = await client.page(query: asked, start: start),
                  isCurrent(client) else { return }
            list.adopt(page, query: asked)
        }
    }

    // MARK: - Reading and removing

    /// Moves the selection, and marks the message read the moment it is selected rather than when
    /// its body arrives, which is what Mail does with the arrow keys too.
    func select(_ id: MailpitMessageID?) {
        selection = id
        guard let id, let row = list.summary(id), !row.isRead else { return }
        list.markRead([id])
        guard let client else { return }
        Task { _ = await client.markRead([id]) }
    }

    func message(_ id: MailpitMessageID) async -> Result<MailpitMessage, MailpitFailure> {
        guard let client else { return .failure(.unreachable) }
        return await client.message(id)
    }

    func source(of id: MailpitMessageID) async -> Result<String, MailpitFailure> {
        guard let client else { return .failure(.unreachable) }
        return await client.source(of: id)
    }

    func htmlURL(of id: MailpitMessageID) -> URL? {
        client?.htmlURL(of: id)
    }

    /// Takes the row out at once and asks Mailpit to follow. If Mailpit refuses, the list is read
    /// again rather than left showing a gap where a message still is.
    ///
    /// The request is not cancelled by a restart, so its answer is checked against the client
    /// before anything is said: a delete that failed against the old address after Settings moved
    /// on is not news about the new one, and reloading from the old client would put its mail back.
    func delete(_ id: MailpitMessageID) {
        guard let client else { return }
        list.remove([id])
        Task {
            guard case .failure(let failure) = await client.delete([id]), isCurrent(client) else { return }
            notice = PaneNoticeContent(tone: .failure, title: "Could not delete the message", message: failure.message)
            await reloadFirstPage(from: client)
        }
    }

    /// Deleting the message being read selects its next neighbour in the app-wide inbox.
    func deleteAndSelectNext(_ id: MailpitMessageID) {
        let next = selection == id ? list.successor(afterRemoving: id) : selection
        delete(id)
        if selection == id { select(next) }
    }

    /// The same as `delete`, for the whole mailbox.
    func deleteAll() {
        guard let client else { return }
        list.removeAll()
        selection = nil
        Task {
            guard case .failure(let failure) = await client.deleteAll(), isCurrent(client) else { return }
            notice = PaneNoticeContent(tone: .failure, title: "Could not delete incoming mails", message: failure.message)
            await reloadFirstPage(from: client)
        }
    }

    /// Whether `client` is still the one Settings points at.
    private func isCurrent(_ client: MailpitClient) -> Bool {
        client.base == self.client?.base
    }

    // MARK: - Attachments

    /// Fetches an attachment into this launch's scratch folder, for Quick Look to open. Nil, with
    /// `notice` saying why, when it could not be fetched or written.
    func preview(_ attachment: MailpitAttachment, of id: MailpitMessageID) async -> URL? {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "Bloom Mail", directoryHint: .isDirectory)
            .appending(path: id.rawValue, directoryHint: .isDirectory)
        return await save(attachment, of: id, into: folder, keepingExisting: false)
    }

    /// Fetches an attachment into Downloads, beside any copy already there rather than over it.
    func saveToDownloads(_ attachment: MailpitAttachment, of id: MailpitMessageID) async -> URL? {
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            notice = PaneNoticeContent(tone: .failure, title: "Could not save the attachment", message: "Bloom could not find the Downloads folder.")
            return nil
        }
        return await save(attachment, of: id, into: downloads, keepingExisting: true)
    }

    private func save(
        _ attachment: MailpitAttachment, of id: MailpitMessageID, into folder: URL, keepingExisting: Bool
    ) async -> URL? {
        guard let client else { return nil }
        let data: Data
        switch await client.attachment(attachment.part, of: id) {
        case .success(let bytes):
            data = bytes
        case .failure(let failure):
            notice = PaneNoticeContent(tone: .failure, title: "Could not fetch \(attachment.savedName)", message: failure.message)
            return nil
        }
        let files = FileManager.default
        let name = keepingExisting
            ? attachment.savedName { files.fileExists(atPath: folder.appending(path: $0).path) }
            : attachment.savedName
        let url = folder.appending(path: name)
        do {
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            notice = PaneNoticeContent(tone: .failure, title: "Could not save \(name)", message: error.localizedDescription)
            return nil
        }
    }

    // MARK: - Settings

    /// A port problem belongs beside the field, including while it is ahead of the debounced restart.
    func portIssue(isEnabled: Bool, port: Int) -> String? {
        let apiPort = MailpitSettings.bundledPorts(forBundleIdentifier: Bundle.main.bundleIdentifier).api
        if !(1024...65535).contains(port) { return "Choose an SMTP port from 1024 to 65535." }
        if port == apiPort { return "Port \(port) is reserved for Bloom's inbox. Choose another SMTP port." }
        guard isEnabled, port == smtpPort, case .smtpPortInUse = bundledFailure else { return nil }
        return bundledError
    }

    /// General inbox state stays with the switch. SMTP port problems appear beside that field.
    func statusLine(isEnabled: Bool, port: Int) -> String? {
        if !isEnabled { return "Off. Bloom will start the inbox when incoming mails are switched on." }
        if portIssue(isEnabled: isEnabled, port: port) != nil { return nil }
        if port != smtpPort { return "Switching to SMTP port \(port)." }
        if let bundledError { return bundledError }
        return connection == .live ? "Ready to receive incoming mails." : "Starting the inbox."
    }

    private static var storedEnabled: Bool {
        MailpitSettings.isEnabled(in: .standard)
    }

    private static var storedSMTPPort: Int {
        UserDefaults.standard.object(forKey: MailpitSettings.smtpPortKey) as? Int
            ?? MailpitSettings.bundledPorts(forBundleIdentifier: Bundle.main.bundleIdentifier).smtp
    }
}
