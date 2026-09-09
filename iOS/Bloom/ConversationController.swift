import UIKit
import BloomClient

final class ConversationController: UIViewController, UITableViewDataSource {
    private let model: MobileConnection
    private let session: RemoteSession
    private let table = UITableView(frame: .zero, style: .plain)
    private let composer = UITextView()
    private let send = UIButton(type: .system)
    private let status = UILabel()
    private var buffer = TranscriptBuffer()
    private var poll: Task<Void, Never>?
    private var pending: RemoteCommand?
    private var isSending = false

    init(model: MobileConnection, session: RemoteSession) {
        self.model = model; self.session = session
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
        send.setTitle("Send", for: .normal)
        send.addAction(UIAction { [weak self] _ in self?.submit() }, for: .touchUpInside)
        status.font = .preferredFont(forTextStyle: .footnote)
        status.textColor = .secondaryLabel
        status.numberOfLines = 0
        let compose = UIStackView(arrangedSubviews: [composer, send])
        compose.spacing = 12; compose.alignment = .bottom
        let stack = UIStackView(arrangedSubviews: [table, status, compose])
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
        guard let service = model.service else { status.text = "Disconnected. Reconnect to see progress."; return }
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
            if !buffer.pendingQuestions.isEmpty {
                status.text = "An approval or question is waiting. Open this conversation in Bloom on Mac to answer, or stop the turn here."
            } else { status.text = buffer.queueError ?? (buffer.isBusy ? "Working on the server" : "Ready") }
            navigationItem.rightBarButtonItem?.isEnabled = buffer.isBusy || !buffer.pendingQuestions.isEmpty
        } catch {
            if !Task.isCancelled { status.text = error.localizedDescription }
        }
    }

    private func submit() {
        guard !isSending, let service = model.service else { return }
        let text = composer.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard pending != nil || !text.isEmpty else { return }
        let command = pending ?? .send(sessionID: session.id, text: composer.text)
        pending = command
        isSending = true
        send.isEnabled = false; composer.isEditable = false
        Task {
            defer { self.isSending = false; self.send.isEnabled = true }
            do {
                _ = try await service.client.request(command)
                self.pending = nil
                self.composer.text = ""
                self.composer.undoManager?.removeAllActions()
                self.composer.isEditable = true
                self.send.setTitle("Send", for: .normal)
                await self.refresh()
            } catch {
                if error is ConnectionRefusal { self.pending = nil; self.composer.isEditable = true }
                self.send.setTitle(self.pending == nil ? "Send" : "Retry", for: .normal)
                self.show(error)
            }
        }
    }

    private func stop() {
        guard let service = model.service else { return }
        Task { do { _ = try await service.client.request(.stop(sessionID: session.id)); await self.refresh() } catch { self.show(error) } }
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
