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
    private var buffer = TranscriptBuffer()
    private var poll: Task<Void, Never>?
    private var isSending = false
    private var hasPendingSubmission = false

    private let uncertainSend = "The last send has not been confirmed. Reconnect to this server and check the conversation before retrying. Retry uses the same message ID."

    init(model: MobileConnection, session: RemoteSession) {
        self.model = model; self.session = session
        origin = model.address
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("Use init(model:session:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = session.title
        view.backgroundColor = .systemBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Stop", primaryAction: UIAction { [weak self] _ in self?.stop() })
        table.dataSource = self
        table.separatorStyle = .none
        table.keyboardDismissMode = .interactive
        table.estimatedRowHeight = 90
        composer.font = .preferredFont(forTextStyle: .body)
        composer.adjustsFontForContentSizeCategory = true
        composer.backgroundColor = .secondarySystemBackground
        composer.layer.cornerRadius = 10
        composer.accessibilityLabel = "Message"
        composer.isScrollEnabled = true
        composer.delegate = self
        send.setTitle("Send", for: .normal)
        send.addAction(UIAction { [weak self] _ in self?.submit() }, for: .touchUpInside)
        status.font = .preferredFont(forTextStyle: .footnote)
        status.textColor = .secondaryLabel
        status.numberOfLines = 0
        review.setTitle("Review waiting request", for: .normal)
        review.isHidden = true
        review.addAction(UIAction { [weak self] _ in self?.reviewRequest() }, for: .touchUpInside)
        let compose = UIStackView(arrangedSubviews: [composer, send])
        compose.spacing = 12; compose.alignment = .bottom
        let stack = UIStackView(arrangedSubviews: [table, status, review, compose])
        stack.axis = .vertical; stack.spacing = 8; stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -8),
            composer.heightAnchor.constraint(equalToConstant: 104),
            send.widthAnchor.constraint(greaterThanOrEqualToConstant: 52),
            send.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
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
        guard model.address == origin, let service = model.service else {
            status.text = hasPendingSubmission ? uncertainSend : "Disconnected. Reconnect to this server to see progress."
            return
        }
        do {
            let transcript = try await service.transcript(sessionID: session.id, after: buffer.sequence)
            guard !Task.isCancelled else { return }
            let previousMessages = buffer.messages
            let previousStreamingText = buffer.streamingText
            buffer.apply(transcript)
            let wasAtBottom = table.contentOffset.y + table.bounds.height >= table.contentSize.height - 100
            if previousMessages != buffer.messages || previousStreamingText != buffer.streamingText {
                table.reloadData()
            }
            if wasAtBottom, table.numberOfRows(inSection: 0) > 0 {
                table.scrollToRow(at: IndexPath(row: table.numberOfRows(inSection: 0) - 1, section: 0), at: .bottom, animated: false)
            }
            updateStatus()
            review.isHidden = buffer.pendingQuestions.isEmpty
            navigationItem.rightBarButtonItem?.isEnabled = buffer.isBusy || !buffer.pendingQuestions.isEmpty
        } catch {
            if !Task.isCancelled { status.text = hasPendingSubmission ? uncertainSend : error.localizedDescription }
        }
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
                self.send.setTitle("Retry", for: .normal)
                self.show(ConnectionFailure(self.uncertainSend + "\n\n" + error.localizedDescription))
            }
        }
    }

    private func stop() {
        guard model.address == origin, let service = model.service else { return }
        Task { do { _ = try await service.client.request(.stop(sessionID: session.id)); await self.refresh() } catch { self.show(error) } }
    }

    func textViewDidChange(_ textView: UITextView) {
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
            send.setTitle(draft.submission == nil ? "Send" : "Retry", for: .normal)
            updateStatus()
        } catch { status.text = "Draft could not be restored: " + error.localizedDescription }
    }

    private func updateStatus() {
        if isSending { status.text = "Sending to the server" } else if hasPendingSubmission {
            status.text = uncertainSend
        } else if !buffer.pendingQuestions.isEmpty { status.text = "The agent is waiting for your answer." } else {
            status.text = buffer.queueError ?? (buffer.isBusy ? "Working on the server" : "Ready")
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
        present(UINavigationController(rootViewController: controller), animated: true)
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        buffer.messages.count + (buffer.streamingText.isEmpty ? 0 : 1)
    }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        if indexPath.row < buffer.messages.count {
            let message = buffer.messages[indexPath.row]
            content.text = message.kind == "user" ? "You" : message.kind.capitalized
            content.secondaryText = message.text
        } else { content.text = "Bloom"; content.secondaryText = buffer.streamingText }
        content.textProperties.font = .preferredFont(forTextStyle: .caption1)
        content.secondaryTextProperties.font = .preferredFont(forTextStyle: .body)
        content.secondaryTextProperties.numberOfLines = 0
        cell.contentConfiguration = content
        cell.selectionStyle = .none
        return cell
    }
}
