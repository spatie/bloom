import UIKit
import BloomClient
import SwiftTerm

/// SwiftTerm is also the Mac terminal engine. UIKit keeps native selection, hardware keyboard,
/// text input and its existing terminal accessory; the server owns the shell across attachments.
final class WorkspaceTerminalController: UIViewController, @preconcurrency TerminalViewDelegate {
    typealias Open = @MainActor @Sendable () async throws -> any RemoteTerminalConnection
    let terminalName: String
    var onClose: (() -> Void)?
    var onTitleChanged: ((String) -> Void)?
    var onOpenURL: ((URL) -> Void)?
    private(set) var isConnected = false
    private let open: Open
    private let terminal = TerminalView(frame: .zero)
    private let toolbar = UIToolbar()
    private let status = UILabel()
    private var connection: (any RemoteTerminalConnection)?
    private var opening: Task<any RemoteTerminalConnection, Error>?
    private var reader: Task<Void, Never>?
    private var writer: Task<Void, Never>?
    private var inputs: [Data] = []
    private var inputBytes = 0
    private var generation = 0
    private var dimensions = (columns: 80, rows: 24)
    private var resizeTask: Task<Void, Never>?

    init(name: String, open: @escaping Open) {
        terminalName = name
        self.open = open
        super.init(nibName: nil, bundle: nil)
        title = "Terminal"
    }
    required init?(coder: NSCoder) { fatalError("Use init(name:open:)") }
    deinit {
        reader?.cancel(); writer?.cancel(); opening?.cancel(); resizeTask?.cancel()
        let connection = connection
        Task { await connection?.close() }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BloomTheme.background
        view.tintColor = BloomTheme.accent
        terminal.terminalDelegate = self
        terminal.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .monospacedSystemFont(ofSize: 13, weight: .regular))
        terminal.nativeForegroundColor = .label
        terminal.nativeBackgroundColor = BloomTheme.background
        terminal.accessibilityIdentifier = "workspace-terminal"
        terminal.translatesAutoresizingMaskIntoConstraints = false
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(terminal)
        view.addSubview(toolbar)
        let appearance = UIToolbarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = BloomTheme.panel
        appearance.shadowColor = BloomTheme.border
        toolbar.standardAppearance = appearance
        toolbar.scrollEdgeAppearance = appearance
        status.font = .preferredFont(forTextStyle: .footnote)
        status.textColor = .secondaryLabel
        status.text = "Connecting…"
        status.accessibilityIdentifier = "terminal-status"
        let interrupt = UIBarButtonItem(title: "Ctrl-C", primaryAction: UIAction { [weak self] _ in self?.enqueue(RemoteTerminalKey.controlC.data) })
        interrupt.accessibilityLabel = "Interrupt command"
        let reconnect = UIBarButtonItem(image: UIImage(systemName: "arrow.clockwise"), primaryAction: UIAction { [weak self] _ in self?.reconnect() })
        reconnect.accessibilityLabel = "Reconnect terminal"
        let keyboard = UIBarButtonItem(image: UIImage(systemName: "keyboard"), primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            if terminal.isFirstResponder { _ = terminal.resignFirstResponder() } else { _ = terminal.becomeFirstResponder() }
        })
        keyboard.accessibilityLabel = "Toggle terminal keyboard"
        let close = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in self?.disconnect(); self?.onClose?() })
        close.accessibilityLabel = "Close terminal tab"
        toolbar.items = [UIBarButtonItem(customView: status), UIBarButtonItem(systemItem: .flexibleSpace), interrupt, keyboard, reconnect, close]
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 48),
            terminal.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            terminal.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            terminal.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        attach()
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        disconnect()
    }

    func connect() async throws {
        loadViewIfNeeded()
        if connection != nil { return }
        let generation = generation
        let task: Task<any RemoteTerminalConnection, Error>
        if let opening { task = opening } else {
            let open = open
            task = Task { try await open() }
            opening = task
        }
        let remote: any RemoteTerminalConnection
        do { remote = try await task.value } catch {
            if generation == self.generation { opening = nil }
            throw error
        }
        guard generation == self.generation, !Task.isCancelled else { await remote.close(); throw CancellationError() }
        if connection != nil { return }
        opening = nil
        connection = remote
        isConnected = true
        setStatus("Connected")
        do { try await remote.resize(columns: dimensions.columns, rows: dimensions.rows) } catch {
            disconnect()
            throw error
        }
        reader = Task { [weak self] in
            do {
                while let data = try await remote.read() {
                    guard !Task.isCancelled, let self, generation == self.generation else { return }
                    terminal.feed(byteArray: Array(data)[...])
                }
                guard !Task.isCancelled, let self, generation == self.generation else { return }
                connection = nil
                isConnected = false
                setStatus("Session ended")
            } catch {
                guard !Task.isCancelled, let self, generation == self.generation else { return }
                disconnect()
                setStatus("Disconnected")
                show(error, retry: { [weak self] in self?.reconnect() })
            }
        }
    }

    func disconnect() {
        generation += 1
        reader?.cancel(); reader = nil
        writer?.cancel(); writer = nil
        resizeTask?.cancel(); resizeTask = nil
        opening?.cancel(); opening = nil
        inputs.removeAll(); inputBytes = 0
        let connection = connection
        self.connection = nil
        isConnected = false
        Task { await connection?.close() }
        if isViewLoaded { setStatus("Disconnected") }
    }

    /// Programmatic input uses the same stream as keyboard input and never invokes a local shell.
    func send(_ data: Data) async throws {
        try await connect()
        guard let connection else { throw ConnectionFailure("Reconnect the terminal before typing.") }
        for offset in stride(from: 0, to: data.count, by: 16_384) {
            try Task.checkCancellation()
            try await connection.send(Data(data[offset..<min(offset + 16_384, data.count)]))
        }
    }

    func sendKey(_ key: RemoteTerminalKey) async throws { try await send(key.data) }

    func resize(columns: Int, rows: Int) async throws {
        resizeTask?.cancel(); resizeTask = nil
        _ = try RemoteTerminalFrame.resize(columns: columns, rows: rows)
        dimensions = (columns, rows)
        let screen = terminal.getTerminal()
        if screen.cols != columns || screen.rows != rows { screen.resize(cols: columns, rows: rows) }
        try await connection?.resize(columns: columns, rows: rows)
    }

    func readText(maxLines: Int = 500) -> String {
        let text = String(decoding: terminal.getTerminal().getBufferAsData(), as: UTF8.self).replacingOccurrences(of: "\0", with: " ")
        return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(max(1, min(maxLines, 2_000))).joined(separator: "\n")
    }

    private func attach() {
        Task { [weak self] in
            do { try await self?.connect() } catch {
                guard !Task.isCancelled, !(error is CancellationError), let self, viewIfLoaded?.window != nil else { return }
                opening = nil
                setStatus("Couldn’t connect")
                show(error, retry: { [weak self] in self?.reconnect() })
            }
        }
    }
    private func reconnect() { disconnect(); setStatus("Connecting…"); attach() }
    private func setStatus(_ text: String) { status.text = text; status.sizeToFit() }

    private func enqueue(_ data: Data) {
        guard !data.isEmpty else { return }
        guard inputBytes + data.count <= 65_536 else {
            show(ConnectionFailure("The terminal input queue is full. Wait before pasting more text."))
            return
        }
        inputs.append(data); inputBytes += data.count
        guard writer == nil else { return }
        let generation = generation
        writer = Task { [weak self] in
            guard let self else { return }
            defer { if generation == self.generation { writer = nil } }
            do {
                while !inputs.isEmpty, !Task.isCancelled, generation == self.generation {
                    let data = inputs.removeFirst(); inputBytes -= data.count
                    try await send(data)
                }
            } catch {
                guard !Task.isCancelled, generation == self.generation else { return }
                inputs.removeAll(); inputBytes = 0
                show(error, retry: { [weak self] in self?.reconnect() })
            }
        }
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        let columns = min(500, max(2, newCols)), rows = min(300, max(2, newRows))
        guard columns != dimensions.columns || rows != dimensions.rows else { return }
        dimensions = (columns, rows)
        resizeTask?.cancel()
        resizeTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(60))
                self?.resizeTask = nil
                try await self?.resize(columns: columns, rows: rows)
            } catch { /* Resizing is best effort while a view is leaving or reconnecting. */ }
        }
    }
    func send(source: TerminalView, data: ArraySlice<UInt8>) { enqueue(Data(data)) }
    func setTerminalTitle(source: TerminalView, title: String) { onTitleChanged?(title) }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func bell(source: TerminalView) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), url.scheme == "https", url.user == nil, url.password == nil else { return }
        onOpenURL?(url)
    }
    func clipboardCopy(source: TerminalView, content: Data) {}
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
