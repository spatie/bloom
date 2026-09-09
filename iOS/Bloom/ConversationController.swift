import UIKit
import BloomClient

final class ConversationController: UIViewController, UITableViewDataSource, UITextViewDelegate {
    private let model: MobileConnection
    private let session: RemoteSession
    private let table = UITableView(frame: .zero, style: .plain)
    private let composer = UITextView()
    private let send = UIButton(type: .system)
    private let status = UILabel()
    private let review = UIButton(type: .system)
    private let origin: String
    private let placeholder = BloomTheme.label("Message your agent", secondary: true)
    private var composerHeight: NSLayoutConstraint?
    #if DEBUG
    private var fixture: RemoteTranscript?
    #endif
    private var buffer = TranscriptBuffer()
    private var poll: Task<Void, Never>?
    private var isRefreshing = false
    private var needsRefresh = false
    private var isSending = false
    private var hasPendingSubmission = false

    private let uncertainSend = "The last send has not been confirmed. Reconnect to this server and check the conversation before retrying. Retry uses the same message ID."

    init(model: MobileConnection, session: RemoteSession) {
        self.model = model; self.session = session
        origin = model.address
        super.init(nibName: nil, bundle: nil)
    }
    #if DEBUG
    init(model: MobileConnection, session: RemoteSession, preview: RemoteTranscript) {
        self.model = model; self.session = session; self.fixture = preview
        origin = model.address
        super.init(nibName: nil, bundle: nil)
    }

    #endif
    required init?(coder: NSCoder) { fatalError("Use init(model:session:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = session.title
        view.backgroundColor = BloomTheme.background
        view.tintColor = BloomTheme.accent
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.prompt = session.model
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "stop.circle"), style: .plain, target: nil, action: nil)
        navigationItem.rightBarButtonItem?.accessibilityLabel = "Stop agent"
        navigationItem.rightBarButtonItem?.primaryAction = UIAction { [weak self] _ in self?.stop() }
        table.dataSource = self
        table.register(TranscriptCell.self, forCellReuseIdentifier: "message")
        table.backgroundColor = .clear
        table.separatorStyle = .none
        table.keyboardDismissMode = .interactive
        table.estimatedRowHeight = 120
        table.contentInset = UIEdgeInsets(top: 8, left: 0, bottom: 12, right: 0)
        composer.font = .preferredFont(forTextStyle: .body)
        composer.adjustsFontForContentSizeCategory = true
        composer.backgroundColor = .clear
        composer.textContainerInset = UIEdgeInsets(top: 14, left: 10, bottom: 14, right: 10)
        composer.accessibilityLabel = "Message"
        composer.delegate = self
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        composer.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.topAnchor.constraint(equalTo: composer.topAnchor, constant: 14),
            placeholder.leadingAnchor.constraint(equalTo: composer.leadingAnchor, constant: 15),
            placeholder.widthAnchor.constraint(equalTo: composer.widthAnchor, constant: -30),
        ])
        var sendConfiguration = UIButton.Configuration.filled()
        sendConfiguration.image = UIImage(systemName: "arrow.up", withConfiguration: UIImage.SymbolConfiguration(weight: .semibold))
        sendConfiguration.baseBackgroundColor = BloomTheme.colour(PaletteInk.accentFill)
        sendConfiguration.baseForegroundColor = .white
        sendConfiguration.cornerStyle = .capsule
        send.configuration = sendConfiguration
        send.accessibilityLabel = "Send message"
        send.addAction(UIAction { [weak self] _ in self?.submit() }, for: .touchUpInside)
        status.font = .preferredFont(forTextStyle: .footnote)
        status.adjustsFontForContentSizeCategory = true
        status.textColor = BloomTheme.secondary
        status.numberOfLines = 0
        var reviewConfiguration = UIButton.Configuration.tinted()
        reviewConfiguration.title = "Review request"
        reviewConfiguration.image = UIImage(systemName: "hand.raised")
        reviewConfiguration.imagePadding = 8
        review.configuration = reviewConfiguration
        review.isHidden = true
        review.addAction(UIAction { [weak self] _ in self?.reviewRequest() }, for: .touchUpInside)
        let footer = UIStackView(arrangedSubviews: [status, send])
        footer.spacing = 12; footer.alignment = .center
        let compose = UIStackView(arrangedSubviews: [composer, footer])
        compose.axis = .vertical; compose.spacing = 2
        compose.isLayoutMarginsRelativeArrangement = true
        compose.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 6, bottom: 10, trailing: 10)
        compose.backgroundColor = BloomTheme.panel
        compose.layer.cornerRadius = 22
        compose.layer.cornerCurve = .continuous
        let stack = UIStackView(arrangedSubviews: [table, review, compose])
        stack.axis = .vertical; stack.spacing = 8; stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        let width = stack.widthAnchor.constraint(equalTo: view.safeAreaLayoutGuide.widthAnchor, constant: -32)
        width.priority = UILayoutPriority(999)
        composerHeight = composer.heightAnchor.constraint(equalToConstant: 62)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 780), width,
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -8),
            composerHeight!, send.widthAnchor.constraint(equalToConstant: 44),
            send.heightAnchor.constraint(equalToConstant: 44),
        ])
        #if DEBUG
        if let fixture { buffer.apply(fixture); updateStatus() }
        #endif
        updateComposer()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateComposer()
    }

    private func updateComposer() {
        placeholder.isHidden = !composer.text.isEmpty
        let text = composer.text.isEmpty ? " " : composer.text + (composer.text.hasSuffix("\n") ? " " : "")
        let font = composer.font ?? .preferredFont(forTextStyle: .body)
        let measured = (text as NSString).boundingRect(
            with: CGSize(width: max(100, composer.bounds.width - 30), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font], context: nil)
        let height = ceil(measured.height) + 28
        let maximum = min(220, max(110, view.bounds.height * 0.28))
        let hintHeight = placeholder.isHidden ? 0 : placeholder.sizeThatFits(CGSize(width: max(100, composer.bounds.width - 30), height: .greatestFiniteMagnitude)).height + 28
        composerHeight?.constant = min(maximum, max(62, height, hintHeight))
        composer.isScrollEnabled = height > maximum
        send.isEnabled = model.service != nil && model.address == origin && !isSending && (hasPendingSubmission || !composer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        send.configuration?.image = UIImage(systemName: hasPendingSubmission ? "arrow.clockwise" : "arrow.up")
        send.accessibilityLabel = hasPendingSubmission ? "Retry message" : "Send message"
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        #if DEBUG
        if fixture != nil { return }
        #endif
        restoreDraft()
        poll?.cancel()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.model.isActive { await self.refresh() }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); poll?.cancel(); poll = nil }

    private func refresh() async {
        if isRefreshing { needsRefresh = true; return }
        isRefreshing = true
        defer { isRefreshing = false }
        repeat {
            needsRefresh = false
            await refreshTranscript()
        } while needsRefresh && !Task.isCancelled
    }

    private func refreshTranscript() async {
        guard model.address == origin, let service = model.service else {
            status.text = hasPendingSubmission ? uncertainSend : "Disconnected. Reconnect to this server to see progress."
            return
        }
        do {
            let transcript = try await service.transcript(sessionID: session.id, after: buffer.sequence)
            guard !Task.isCancelled else { return }
            applyTranscript(transcript)
        } catch {
            if !Task.isCancelled { status.text = hasPendingSubmission ? uncertainSend : error.localizedDescription }
        }
    }

    private func applyTranscript(_ transcript: RemoteTranscript) {
        let previousMessages = buffer.messages
        let previousStreamingText = buffer.streamingText
        buffer.apply(transcript)
        let wasAtBottom = table.contentOffset.y + table.bounds.height >= table.contentSize.height - 100
        if previousMessages != buffer.messages || previousStreamingText != buffer.streamingText {
            updateRows(previousMessages: previousMessages, previousStreamingText: previousStreamingText)
        }
        if wasAtBottom, table.numberOfRows(inSection: 0) > 0 {
            table.scrollToRow(at: IndexPath(row: table.numberOfRows(inSection: 0) - 1, section: 0), at: .bottom, animated: false)
        }
        updateStatus()
        review.isHidden = buffer.pendingQuestions.isEmpty
        navigationItem.rightBarButtonItem?.isEnabled = buffer.isBusy || !buffer.pendingQuestions.isEmpty
    }

    #if DEBUG
    var liveMessageCount: Int { buffer.messages.count }

    /// Exercises the production snapshot and table-update path without requesting a server.
    func exerciseTranscriptUpdates(_ snapshots: [RemoteTranscript]) throws {
        let resultURL = URL.documentsDirectory.appendingPathComponent("bloom-transcript-updates-passed.txt")
        try? FileManager.default.removeItem(at: resultURL)
        table.layoutIfNeeded()
        let firstPath = IndexPath(row: 0, section: 0)
        guard let firstCell = table.cellForRow(at: firstPath) else {
            throw ConnectionFailure("Transcript fixture did not realise its first cell.")
        }
        for (index, snapshot) in snapshots.enumerated() {
            applyTranscript(snapshot)
            table.layoutIfNeeded()
            let expected = snapshot.messages.count + (snapshot.streamingText.isEmpty ? 0 : 1)
            guard table.numberOfRows(inSection: 0) == expected,
                  buffer.messages == snapshot.messages,
                  buffer.streamingText == snapshot.streamingText,
                  table.cellForRow(at: firstPath) === firstCell else {
                throw ConnectionFailure("Transcript update fixture failed at step \(index + 1).")
            }
        }
        try "Passed \(snapshots.count) transcript updates; first cell retained.\n".write(
            to: resultURL, atomically: true, encoding: .utf8
        )
    }
    #endif

    private func updateRows(previousMessages: [RemoteMessage], previousStreamingText: String) {
        let oldIDs = previousMessages.map { String($0.id) } + (previousStreamingText.isEmpty ? [] : ["stream"])
        let newIDs = buffer.messages.map { String($0.id) } + (buffer.streamingText.isEmpty ? [] : ["stream"])
        let change = TranscriptEntryChange.between(oldIDs, newIDs)
        let plan = TranscriptTableUpdate.plan(change: change, environmentMoved: false)
        UIView.performWithoutAnimation {
            switch plan {
            case .reload:
                // A streamed answer gaining its permanent ID replaces only that row.
                // The standard diff also handles reordering without discarding retained cells.
                let difference = newIDs.difference(from: oldIDs)
                table.performBatchUpdates {
                    for operation in difference {
                        switch operation {
                        case .remove(let offset, _, _):
                            table.deleteRows(at: [IndexPath(row: offset, section: 0)], with: .none)
                        case .insert(let offset, _, _):
                            table.insertRows(at: [IndexPath(row: offset, section: 0)], with: .none)
                        }
                    }
                }
            case .rows(.grew(let head, let tail)):
                table.performBatchUpdates {
                    table.insertRows(at: (Array(head) + Array(tail)).map { IndexPath(row: $0, section: 0) }, with: .none)
                }
            case .rows(.shrank(let head, let tail)):
                table.performBatchUpdates {
                    table.deleteRows(at: (Array(head) + Array(tail)).map { IndexPath(row: $0, section: 0) }, with: .none)
                }
            case .nothing, .rows(.same), .rows(.rebuilt):
                break
            }
            // Retain unchanged hosting cells so streaming does not reset their selection or folds.
            let previous = Dictionary(uniqueKeysWithValues: previousMessages.map { ($0.id, $0) })
            var changed = buffer.messages.enumerated().compactMap { index, message -> IndexPath? in
                guard let old = previous[message.id], old != message else { return nil }
                return IndexPath(row: index, section: 0)
            }
            if !previousStreamingText.isEmpty, !buffer.streamingText.isEmpty, previousStreamingText != buffer.streamingText {
                changed.append(IndexPath(row: buffer.messages.count, section: 0))
            }
            if !changed.isEmpty { table.reconfigureRows(at: changed) }
            table.layoutIfNeeded()
        }
    }

    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(title: "Send message", action: #selector(sendFromKeyboard), input: "\r", modifierFlags: .command)]
    }

    @objc private func sendFromKeyboard() {
        if send.isEnabled { submit() }
    }

    private func submit() {
        guard !isSending, model.address == origin, let service = model.service else { return }
        do {
            let existing = try MobileConnection.drafts.draft(origin: origin, sessionID: session.id)
            if existing.submission == nil {
                try MobileConnection.drafts.save(text: composer.text, origin: origin, sessionID: session.id)
            }
            _ = try MobileConnection.drafts.prepare(origin: origin, sessionID: session.id)
        } catch { show(error); return }
        restoreDraft()
        isSending = true
        send.isEnabled = false; composer.isEditable = false
        Task {
            defer { self.isSending = false; self.send.isEnabled = true; self.updateStatus() }
            do {
                try await MobileConnection.drafts.submit(using: service.client, origin: self.origin, sessionID: self.session.id)
                self.restoreDraft()
                self.composer.undoManager?.removeAllActions()
                await self.refresh()
            } catch {
                self.updateComposer()
                self.show(ConnectionFailure(self.uncertainSend + "\n\n" + error.localizedDescription))
            }
        }
    }

    private func stop() {
        guard model.address == origin, let service = model.service else { return }
        Task { do { _ = try await service.client.request(.stop(sessionID: session.id)); await self.refresh() } catch { self.show(error) } }
    }

    func textViewDidChange(_ textView: UITextView) {
        updateComposer()
        do { try MobileConnection.drafts.save(text: composer.text, origin: origin, sessionID: session.id) } catch {
            status.text = "Draft could not be saved: " + error.localizedDescription
        }
    }

    private func restoreDraft() {
        do {
            let draft = try MobileConnection.drafts.draft(origin: origin, sessionID: session.id)
            hasPendingSubmission = draft.submission != nil
            composer.text = draft.submission?.operation["send"]?["text"]?.stringValue ?? draft.text
            composer.isEditable = draft.submission == nil
            updateComposer()
            updateStatus()
        } catch { status.text = "Draft could not be restored: " + error.localizedDescription }
    }

    private func updateStatus() {
        updateComposer()
        send.configuration?.showsActivityIndicator = isSending
        if buffer.messages.isEmpty && buffer.streamingText.isEmpty {
            var empty = UIContentUnavailableConfiguration.empty()
            empty.image = UIImage(systemName: "bubble.left.and.text.bubble.right")
            empty.text = "Start a conversation"
            empty.secondaryText = "Describe what you'd like to build. Your agent works on the server, even when you're away."
            table.backgroundView = UIContentUnavailableView(configuration: empty)
        } else { table.backgroundView = nil }

        if isSending { status.text = "Sending to the server" } else if hasPendingSubmission {
            status.text = uncertainSend
        } else if !buffer.pendingQuestions.isEmpty { status.text = "The agent is waiting for your answer." } else {
            status.text = buffer.queueError ?? (buffer.isBusy ? "Working on the server" : "Ready when you are")
        }
    }

    private func reviewRequest() {
        guard model.address == origin, let service = model.service,
              let data = buffer.pendingQuestions.first else { return }
        guard let request = RemoteApproval(data: data) else {
            show(ConnectionFailure("This request is not supported on iPhone or iPad yet. Answer it in Bloom on Mac, or stop the turn."))
            return
        }
        let controller = ApprovalController(request: request, sessionID: session.id, service: service) { [weak self] in
            await self?.refresh()
        }
        present(BloomTheme.navigation(controller), animated: true)
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        buffer.messages.count + (buffer.streamingText.isEmpty ? 0 : 1)
    }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: "message", for: indexPath) as? TranscriptCell else { return UITableViewCell() }
        if indexPath.row < buffer.messages.count {
            let message = buffer.messages[indexPath.row]
            cell.configure(kind: message.kind, text: message.text, identity: String(message.id))
        } else { cell.configure(kind: "assistant", text: buffer.streamingText, identity: "stream", isStreaming: true) }
        return cell
    }
}
