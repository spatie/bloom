import UIKit
import BloomClient

final class ConversationController: UIViewController, UITableViewDataSource, UITextViewDelegate {
    private let model: MobileConnection
    private let session: RemoteSession
    var onOpenSession: ((RemoteSession) -> Void)?
    private let options = UIButton(type: .system)
    private var optionsStore: RemoteComposerStore?
    private var optionsTask: Task<Void, Never>?
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
    private var rows: [RemoteTranscriptRow] = []
    private var queuedRows: [RemoteQueuedPrompt] = []
    var transcriptMessageCount: Int { buffer.messages.count }
    private var poll: Task<Void, Never>?
    private var connectionObserver: UUID?
    private var pollingGeneration: Int?
    private var transcriptProblem: String?
    private var isRefreshing = false
    private var needsRefresh = false
    private var isSending = false
    private var hasPendingSubmission = false
    private var queueCancellationIDs: [DeliveryID: UUID] = [:]
    private var cancellingQueued: Set<DeliveryID> = []

    private let uncertainSend = "Message delivery is unconfirmed. Check the conversation, then choose Retry Message. Bloom reuses its original ID to avoid sending it twice."

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
        configureOptionsButton()
        let spacer = UIView()
        let footer = UIStackView(arrangedSubviews: [options, spacer, send])
        footer.spacing = 12; footer.alignment = .center
        let compose = UIStackView(arrangedSubviews: [composer, status, footer])
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
            composerHeight!, send.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            send.heightAnchor.constraint(equalToConstant: 44),
        ])
        #if DEBUG
        if let fixture {
            buffer.apply(fixture)
            rows = RemoteTranscriptProjection.rows(messages: buffer.messages)
            queuedRows = buffer.queuedPrompts
            table.reloadData()
            updateStatus()
        }
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
        send.isEnabled = model.canSend && model.address == origin && !isSending && (hasPendingSubmission || !composer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        send.configuration?.image = UIImage(systemName: hasPendingSubmission ? "arrow.clockwise" : "arrow.up")
        send.configuration?.title = hasPendingSubmission ? "Retry Message" : nil
        send.accessibilityLabel = hasPendingSubmission ? "Retry message" : "Send message"
        options.isHidden = hasPendingSubmission
        options.isEnabled = model.canSend && model.address == origin && !isSending && !hasPendingSubmission
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        #if DEBUG
        if fixture != nil { return }
        #endif
        restoreDraft()
        loadOptions()
        connectionObserver = model.observe { [weak self] in self?.connectionChanged() }
        connectionChanged()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        poll?.cancel(); poll = nil; pollingGeneration = nil
        if let connectionObserver { model.removeObserver(connectionObserver) }
        connectionObserver = nil
    }

    private func connectionChanged() {
        updateStatus()
        if !queuedRows.isEmpty { table.reloadSections(IndexSet(integer: 1), with: .none) }
        guard model.canSend, model.address == origin else {
            poll?.cancel(); poll = nil; pollingGeneration = nil
            return
        }
        guard pollingGeneration != model.generation else { return }
        pollingGeneration = model.generation
        transcriptProblem = nil
        loadOptions()
        poll?.cancel()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.model.canSend else { return }
                await self.refresh()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    private func configureOptionsButton() {
        var configuration = UIButton.Configuration.plain()
        configuration.title = ModelLabel.readable(session.model)
        configuration.image = UIImage(systemName: "slider.horizontal.3")
        configuration.imagePadding = 7
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var result = incoming
            result.font = .preferredFont(forTextStyle: .footnote)
            return result
        }
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 6, bottom: 10, trailing: 6)
        options.configuration = configuration
        options.accessibilityLabel = "Agent options"
        options.accessibilityValue = configuration.title
        options.accessibilityIdentifier = "composer-options"
        options.addAction(UIAction { [weak self] _ in self?.showOptions() }, for: .touchUpInside)
    }

    private func loadOptions() {
        guard optionsStore == nil, model.address == origin, let service = model.service else { return }
        let store = RemoteComposerStore(service: service, sessionID: session.id)
        optionsStore = store
        optionsTask = Task { [weak self] in
            try? await store.load()
            guard !Task.isCancelled else { return }
            self?.updateOptionsLabel()
        }
    }

    private func updateOptionsLabel() {
        let controls = optionsStore?.state?.controls
        let label = ModelLabel.readable(controls?.model ?? session.model)
        options.configuration?.title = label
        options.accessibilityValue = label
        navigationItem.prompt = label
    }

    private func showOptions() {
        loadOptions()
        guard let store = optionsStore, model.address == origin, let service = model.service else { return }
        do { try store.reconnect(using: service) } catch { show(error); return }
        let controller = ComposerOptionsController(store: store) { [weak self] fork in
            guard let self else { return }
            self.updateOptionsLabel()
            guard let fork else { return }
            if let onOpenSession = self.onOpenSession { onOpenSession(fork) } else {
                self.navigationController?.pushViewController(ConversationController(model: self.model, session: fork), animated: true)
            }
        }
        let navigation = BloomTheme.navigation(controller)
        navigation.preferredContentSize = controller.preferredContentSize
        if traitCollection.horizontalSizeClass == .compact {
            navigation.modalPresentationStyle = .pageSheet
            navigation.sheetPresentationController?.detents = traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? [.large()] : [.medium(), .large()]
            navigation.sheetPresentationController?.prefersGrabberVisible = true
        } else {
            navigation.modalPresentationStyle = .popover
            navigation.popoverPresentationController?.sourceView = options
            navigation.popoverPresentationController?.sourceRect = options.bounds
        }
        present(navigation, animated: true)
    }

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
        guard model.canSend, model.address == origin, let service = model.service else { updateStatus(); return }
        let generation = model.generation
        do {
            let transcript = try await service.transcript(sessionID: session.id, after: buffer.sequence)
            guard !Task.isCancelled, model.address == origin, model.generation == generation, model.canSend else { return }
            transcriptProblem = nil
            applyTranscript(transcript)
        } catch {
            if !Task.isCancelled {
                transcriptProblem = model.canSend ? error.localizedDescription : nil
                updateStatus()
            }
        }
    }

    private func applyTranscript(_ transcript: RemoteTranscript) {
        let previousRows = rows
        let previousQueue = queuedRows
        let previousStreamingText = buffer.streamingText
        buffer.apply(transcript)
        rows = RemoteTranscriptProjection.rows(messages: buffer.messages)
        let wasAtBottom = table.contentOffset.y + table.bounds.height >= table.contentSize.height - 100
        if previousRows != rows || previousStreamingText != buffer.streamingText {
            updateRows(previousRows: previousRows, previousStreamingText: previousStreamingText)
        }
        if previousQueue != buffer.queuedPrompts {
            queuedRows = buffer.queuedPrompts
            queueCancellationIDs = queueCancellationIDs.filter { id, _ in buffer.queuedPrompts.contains { $0.id == id } }
            UIView.performWithoutAnimation { table.reloadSections(IndexSet(integer: 1), with: .none) }
        }
        let lastSection = queuedRows.isEmpty ? 0 : 1
        if wasAtBottom, table.numberOfRows(inSection: lastSection) > 0 {
            table.scrollToRow(at: IndexPath(row: table.numberOfRows(inSection: lastSection) - 1, section: lastSection), at: .bottom, animated: false)
        }
        updateStatus()
        review.isHidden = buffer.pendingQuestions.isEmpty
        navigationItem.rightBarButtonItem?.isEnabled = model.canSend && (buffer.isBusy || !buffer.pendingQuestions.isEmpty)
    }

    #if DEBUG
    var liveMessageCount: Int { transcriptMessageCount }

    func showLiveOptions() async throws {
        loadOptions()
        for _ in 0..<30 {
            if optionsStore?.state != nil { showOptions(); return }
            if let error = optionsStore?.error { throw ConnectionFailure(error) }
            try await Task.sleep(for: .seconds(1))
        }
        throw ConnectionFailure("Composer settings did not load from the server.")
    }

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
            let expected = RemoteTranscriptProjection.rows(messages: snapshot.messages).count + (snapshot.streamingText.isEmpty ? 0 : 1)
            guard table.numberOfRows(inSection: 0) == expected,
                  table.numberOfRows(inSection: 1) == snapshot.queuedPrompts.count,
                  buffer.queuedPrompts == snapshot.queuedPrompts,
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

    private func updateRows(previousRows: [RemoteTranscriptRow], previousStreamingText: String) {
        let oldIDs = previousRows.map { String($0.id) } + (previousStreamingText.isEmpty ? [] : ["stream"])
        let newIDs = rows.map { String($0.id) } + (buffer.streamingText.isEmpty ? [] : ["stream"])
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
            let previous = Dictionary(uniqueKeysWithValues: previousRows.map { ($0.id, $0) })
            var changed = rows.enumerated().compactMap { index, message -> IndexPath? in
                guard let old = previous[message.id], old != message else { return nil }
                return IndexPath(row: index, section: 0)
            }
            if !previousStreamingText.isEmpty, !buffer.streamingText.isEmpty, previousStreamingText != buffer.streamingText {
                changed.append(IndexPath(row: rows.count, section: 0))
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
        guard !isSending, model.canSend, model.address == origin, let service = model.service else { return }
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
            defer { self.isSending = false; self.updateStatus() }
            do {
                try await MobileConnection.drafts.submit(using: service.client, origin: self.origin, sessionID: self.session.id)
                self.restoreDraft()
                self.composer.undoManager?.removeAllActions()
                await self.refresh()
            } catch {
                // The persisted pending command remains the only retry path. Never submit it
                // automatically when connectivity returns, and do not interrupt reading with alerts.
                self.restoreDraft()
                self.transcriptProblem = self.model.canSend ? error.localizedDescription : nil
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
        if rows.isEmpty && buffer.streamingText.isEmpty && buffer.queuedPrompts.isEmpty {
            var empty = UIContentUnavailableConfiguration.empty()
            empty.image = UIImage(systemName: "bubble.left.and.text.bubble.right")
            empty.text = "Start a conversation"
            empty.secondaryText = "Describe what you'd like to build. Your agent works on the server, even when you're away."
            table.backgroundView = UIContentUnavailableView(configuration: empty)
        } else { table.backgroundView = nil }

        navigationItem.rightBarButtonItem?.isEnabled = model.canSend && (buffer.isBusy || !buffer.pendingQuestions.isEmpty)
        review.isEnabled = model.canSend && model.address == origin
        if isSending { status.text = "Sending to the server" } else if hasPendingSubmission {
            status.text = model.canSend ? uncertainSend : "Message delivery is unconfirmed. It is saved on this device. Reconnect before choosing Retry Message."
        } else if model.address != origin {
            status.text = "Reconnect to this conversation's server. Your draft is saved on this device."
        } else if !model.canSend {
            status.text = model.recovery.title + ". You can keep writing; your draft stays on this device."
        } else if let transcriptProblem { status.text = transcriptProblem
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

    private func cancelQueued(_ prompt: RemoteQueuedPrompt) {
        guard !cancellingQueued.contains(prompt.id), model.address == origin, let service = model.service else { return }
        let commandID = queueCancellationIDs[prompt.id] ?? UUID()
        queueCancellationIDs[prompt.id] = commandID
        cancellingQueued.insert(prompt.id)
        table.reloadSections(IndexSet(integer: 1), with: .none)
        Task { [weak self] in
            guard let self else { return }
            defer {
                cancellingQueued.remove(prompt.id)
                table.reloadSections(IndexSet(integer: 1), with: .none)
            }
            do {
                try await service.cancelQueued(sessionID: session.id, deliveryID: prompt.id, commandID: commandID)
                await refresh()
            } catch {
                guard model.address == origin, viewIfLoaded?.window != nil else { return }
                show(error, retry: { [weak self] in self?.cancelQueued(prompt) })
            }
        }
    }

    func numberOfSections(in tableView: UITableView) -> Int { 2 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 1 ? queuedRows.count : rows.count + (buffer.streamingText.isEmpty ? 0 : 1)
    }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: "message", for: indexPath) as? TranscriptCell else { return UITableViewCell() }
        if indexPath.section == 1 {
            let prompt = queuedRows[indexPath.row]
            cell.configureQueued(prompt, isCancelling: cancellingQueued.contains(prompt.id),
                                 canCancel: model.address == origin && model.canSend) { [weak self] in self?.cancelQueued(prompt) }
        } else if indexPath.row < rows.count {
            cell.configure(row: rows[indexPath.row])
        } else { cell.configure(kind: "assistant", text: buffer.streamingText, identity: "stream", isStreaming: true) }
        return cell
    }
}
