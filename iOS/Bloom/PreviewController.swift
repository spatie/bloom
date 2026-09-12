import UIKit
import WebKit
import BloomClient

/// Preview login belongs to its own browser origin. Agent-control bearer tokens never enter WebKit.
final class PreviewController: UIViewController, WKNavigationDelegate, WKUIDelegate, UITextFieldDelegate {
    var onClose: (() -> Void)? {
        didSet { if isViewLoaded { updateToolbar() } }
    }

    private(set) var hasLoadedPage = false
    private(set) var lastPageFailure: String?
    var loadedPageTitle: String { browser.title ?? "" }

    private let url: URL
    private let browser: WKWebView
    private var navigationObservations: [NSKeyValueObservation] = []
    private var previewLease: MobilePreviewLease?
    private var preparing: Task<Void, Never>?
    private var ruleListIdentifier: String?
    private let toolbar = UIToolbar()
    private let address = UITextField()
    var onNavigate: (@MainActor (String) async throws -> Void)?
    private var navigationTask: Task<Void, Never>?
    private let activity = UIActivityIndicatorView(style: .medium)
    private let errorView = UIView()
    private let errorDetail = BloomTheme.label("", style: .subheadline, secondary: true)
    private var isLoading = false
    private var retryURL: URL?
    private var reconnectAddress: String?
    #if DEBUG
    private var previewHTML: String?
    #endif

    private lazy var backItem = UIBarButtonItem(image: UIImage(systemName: "chevron.left"),
                                                primaryAction: UIAction { [weak self] _ in self?.browser.goBack() })
    private lazy var forwardItem = UIBarButtonItem(image: UIImage(systemName: "chevron.right"),
                                                   primaryAction: UIAction { [weak self] _ in self?.browser.goForward() })
    private lazy var reloadItem = UIBarButtonItem(image: UIImage(systemName: "arrow.clockwise"),
                                                  primaryAction: UIAction { [weak self] _ in self?.reload() })
    private lazy var closeItem = UIBarButtonItem(systemItem: .close,
                                                 primaryAction: UIAction { [weak self] _ in self?.onClose?() })

    convenience init() { self.init(url: URL(string: "about:blank")!) }

    init(url: URL) {
        self.url = url
        browser = WKWebView(frame: .zero)
        super.init(nibName: nil, bundle: nil)
    }

    init(preview: MobilePreviewLease) {
        url = preview.url
        previewLease = preview
        reconnectAddress = preview.sourceURL.absoluteString
        let configuration = WKWebViewConfiguration()
        // An ephemeral local port must never inherit another workspace's browser cookies.
        if preview.isTunnel { configuration.websiteDataStore = .nonPersistent() }
        browser = WKWebView(frame: .zero, configuration: configuration)
        super.init(nibName: nil, bundle: nil)
        preview.onRevoked = { [weak self] in
            self?.preparing?.cancel()
            self?.navigationTask?.cancel()
            self?.browser.stopLoading()
            self?.browser.loadHTMLString("", baseURL: nil)
            self?.showFailure("This preview connection has closed. Reconnect to the server, then reload the preview.")
        }
    }

    deinit {
        navigationTask?.cancel()
        preparing?.cancel()
        let lease = previewLease
        let identifier = ruleListIdentifier
        Task { @MainActor in
            lease?.close()
            if let identifier { try? await WKContentRuleListStore.default().removeContentRuleList(forIdentifier: identifier) }
        }
    }

    var currentAddress: String {
        if previewLease?.isClosed == true { return reconnectAddress ?? previewLease?.sourceURL.absoluteString ?? url.absoluteString }
        return previewLease?.reportedURL(browser.url ?? url).absoluteString ?? (browser.url ?? url).absoluteString
    }
    var pageIsLoading: Bool { isLoading }
    var pageCanGoBack: Bool { browser.canGoBack }
    var pageCanGoForward: Bool { browser.canGoForward }

    func reloadPage() { reload() }

    func pageText() async throws -> String {
        try requirePage()
        let result = try await evaluate(.visibleText)
        guard let text = result.stringValue else { throw ConnectionFailure("The browser did not return readable page text.") }
        let trimmed = BrowserPageText.trim(text)
        return trimmed.text + (trimmed.cut ? "\n[Page text truncated at \(BrowserPageText.limit) characters.]" : "")
    }

    func scrollPage(_ movement: BrowserScroll) async throws -> String {
        try requirePage()
        let result = try await evaluate(.scroll(movement))
        guard let values = result.arrayValue, values.count == 3 else { throw ConnectionFailure("The page did not report its scroll position.") }
        let numbers = values.map { value -> Int in
            if case .integer(let number) = value { return number }
            if case .number(let number) = value, number.isFinite, abs(number) < 100_000_000 { return Int(number) }
            return 0
        }
        return movement.report(offset: numbers[0], height: numbers[1], viewport: numbers[2])
    }

    func pageSnapshot() async throws -> Data {
        try requirePage()
        guard browser.bounds.width > 1, browser.bounds.height > 1 else { throw ConnectionFailure("Select this browser tab before taking its first screenshot.") }
        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = NSNumber(value: min(1280, browser.bounds.width))
        return try await CancellableCallback<Data>.run { completion in
            browser.takeSnapshot(with: configuration) { snapshot, error in
                if let error { completion(.failure(error)); return }
                guard let snapshot, let data = snapshot.pngData(), data.count <= 8_388_608 else {
                    completion(.failure(ConnectionFailure("The browser screenshot is too large or unavailable. Resize the pane and try again.")))
                    return
                }
                completion(.success(data))
            }
        }
    }

    private func requirePage() throws {
        if let lastPageFailure { throw ConnectionFailure(lastPageFailure) }
        guard previewLease?.isClosed != true, hasLoadedPage else { throw ConnectionFailure("Wait for this browser page to finish loading, then try again.") }
    }

    private func evaluate(_ script: BrowserPageScript) async throws -> JSONValue {
        try await CancellableCallback<JSONValue>.run { completion in
            browser.evaluateJavaScript(script.source) { value, error in
                if let error { completion(.failure(error)); return }
                do {
                    let data = try JSONSerialization.data(withJSONObject: value ?? NSNull(), options: .fragmentsAllowed)
                    completion(.success(try JSONDecoder().decode(JSONValue.self, from: data)))
                } catch { completion(.failure(error)) }
            }
        }
    }

    func closePreview() {
        navigationObservations.removeAll()
        navigationTask?.cancel()
        preparing?.cancel()
        removeRuleList()
        browser.stopLoading()
        previewLease?.onRevoked = nil
        previewLease?.close()
    }

    #if DEBUG
    convenience init(previewHTML: String, baseURL: URL) {
        self.init(url: baseURL)
        self.previewHTML = previewHTML
    }
    #endif

    required init?(coder: NSCoder) { fatalError("Use init(url:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BloomTheme.background
        title = "Preview"
        configureToolbar()
        configureBrowser()
        configureErrorView()
        prepareBrowser()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // A custom toolbar item has no flexible width. Reserve room for native history controls.
        let controls = 2 + (browser.canGoForward ? 1 : 0) + (onClose == nil ? 0 : 1)
        address.frame.size = CGSize(width: max(80, toolbar.bounds.width - CGFloat(controls * 44 + 24)), height: 44)
    }

    func textFieldDidBeginEditing(_ textField: UITextField) {
        textField.text = currentAddress == "about:blank" ? "" : currentAddress
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        let text = textField.text ?? ""
        textField.resignFirstResponder()
        navigate(to: text)
        return true
    }

    private func navigate(to address: String) {
        guard let onNavigate else {
            showFailure("Close this preview and open it again from your workspace.")
            return
        }
        navigationTask?.cancel()
        navigationTask = Task { [weak self] in
            do { try await onNavigate(address) } catch {
                guard !Task.isCancelled else { return }
                self?.showFailure(error.localizedDescription)
            }
        }
    }

    private func configureToolbar() {
        let appearance = UIToolbarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = BloomTheme.panel
        appearance.shadowColor = BloomTheme.border
        toolbar.standardAppearance = appearance
        toolbar.scrollEdgeAppearance = appearance
        toolbar.tintColor = BloomTheme.accent
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toolbar)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 48)
        ])
        address.font = .preferredFont(forTextStyle: .footnote)
        address.adjustsFontForContentSizeCategory = true
        address.textColor = .label
        address.textAlignment = .center
        address.delegate = self
        address.keyboardType = .URL
        address.returnKeyType = .go
        address.autocapitalizationType = .none
        address.autocorrectionType = .no
        address.placeholder = "Website address"
        address.borderStyle = .none
        address.backgroundColor = BloomTheme.background
        address.layer.cornerRadius = 12
        address.clipsToBounds = true
        address.clearButtonMode = .whileEditing
        address.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 1))
        address.leftViewMode = .always
        address.accessibilityLabel = "Preview address"
        address.accessibilityIdentifier = "preview-address"
        backItem.accessibilityLabel = "Go back"
        forwardItem.accessibilityLabel = "Go forward"
        closeItem.accessibilityLabel = "Close preview"
        updateToolbar()
    }

    private func configureBrowser() {
        browser.navigationDelegate = self
        browser.uiDelegate = self
        // Inertia and other single-page apps change URL/history without navigation callbacks.
        // Observations are retained only by this controller and capture it weakly.
        navigationObservations = [
            browser.observe(\.url, options: [.initial, .new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refreshNavigation() }
            },
            browser.observe(\.title, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refreshNavigation() }
            },
            browser.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refreshNavigation() }
            },
            browser.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refreshNavigation() }
            },
            browser.observe(\.isLoading, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refreshNavigation() }
            },
        ]
        browser.allowsBackForwardNavigationGestures = true
        browser.isOpaque = false
        browser.backgroundColor = BloomTheme.background
        browser.accessibilityIdentifier = "workspace-preview"
        browser.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(browser)
        NSLayoutConstraint.activate([
            browser.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            browser.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            browser.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            browser.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        activity.hidesWhenStopped = true
        activity.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(activity)
        NSLayoutConstraint.activate([
            activity.centerXAnchor.constraint(equalTo: browser.centerXAnchor),
            activity.centerYAnchor.constraint(equalTo: browser.centerYAnchor)
        ])
    }

    private func configureErrorView() {
        errorView.backgroundColor = BloomTheme.background
        errorView.isHidden = true
        errorView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(errorView)
        let symbol = UIImageView(image: UIImage(systemName: "globe.badge.chevron.backward"))
        symbol.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 30, weight: .light)
        symbol.tintColor = BloomTheme.accent
        symbol.contentMode = .scaleAspectFit
        let heading = BloomTheme.label("Preview couldn’t load", style: .headline)
        heading.textAlignment = .center
        errorDetail.textAlignment = .center
        let retry = UIButton(configuration: .tinted(), primaryAction: UIAction { [weak self] _ in self?.reload() })
        retry.configuration?.title = "Try Again"
        retry.configuration?.cornerStyle = .capsule
        retry.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        retry.tintColor = BloomTheme.accent
        let stack = UIStackView(arrangedSubviews: [symbol, heading, errorDetail, retry])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        errorView.addSubview(stack)
        NSLayoutConstraint.activate([
            errorView.topAnchor.constraint(equalTo: browser.topAnchor),
            errorView.leadingAnchor.constraint(equalTo: browser.leadingAnchor),
            errorView.trailingAnchor.constraint(equalTo: browser.trailingAnchor),
            errorView.bottomAnchor.constraint(equalTo: browser.bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: errorView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: errorView.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: errorView.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: errorView.trailingAnchor, constant: -28),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 340),
            symbol.heightAnchor.constraint(equalToConstant: 40)
        ])
    }

    private func prepareBrowser() {
        if previewLease?.isClosed == true {
            if let reconnectAddress, onNavigate != nil { navigate(to: reconnectAddress) } else {
                showFailure("This preview connection has closed. Reconnect to the server, then reopen the preview.")
            }
            return
        }
        guard let previewLease, previewLease.isTunnel, let port = previewLease.url.port else {
            loadInitialPage()
            return
        }
        // Navigation delegates do not inspect fetches, images or other subresources. The rule list
        // keeps the local-network ATS exception scoped to this lease for those requests too.
        let rules = """
        [
          {"trigger":{"url-filter":"^http://"},"action":{"type":"block"}},
          {"trigger":{"url-filter":"^http://127[.]0[.]0[.]1:\(port)/"},"action":{"type":"ignore-previous-rules"}}
        ]
        """
        let identifier = "bloom-preview-\(previewLease.id.uuidString)"
        preparing = Task { [weak self] in
            do {
                let rules = try await WKContentRuleListStore.default().compileContentRuleList(
                    forIdentifier: identifier, encodedContentRuleList: rules
                )
                guard !Task.isCancelled, !previewLease.isClosed, let self else {
                    try? await WKContentRuleListStore.default().removeContentRuleList(forIdentifier: identifier)
                    return
                }
                guard let rules else { throw ConnectionFailure("The preview security rules were unavailable.") }
                ruleListIdentifier = identifier
                browser.configuration.userContentController.add(rules)
                loadInitialPage()
            } catch {
                try? await WKContentRuleListStore.default().removeContentRuleList(forIdentifier: identifier)
                guard !Task.isCancelled else { return }
                NSLog("Bloom preview rule error: %@", error.localizedDescription)
                self?.showFailure("Could not secure this preview. Close it and try again.")
            }
        }
    }

    private func removeRuleList() {
        guard let identifier = ruleListIdentifier else { return }
        ruleListIdentifier = nil
        Task { try? await WKContentRuleListStore.default().removeContentRuleList(forIdentifier: identifier) }
    }

    private func loadInitialPage() {
        if url.absoluteString == "about:blank" {
            updateToolbar()
            return
        }
        #if DEBUG
        if let previewHTML {
            browser.loadHTMLString(previewHTML, baseURL: url)
            return
        }
        #endif
        guard allows(url) else {
            showFailure("Open a secure HTTPS preview address.")
            return
        }
        browser.load(URLRequest(url: url))
    }

    private func reload() {
        if previewLease?.isClosed == true {
            navigate(to: reconnectAddress ?? previewLease?.sourceURL.absoluteString ?? url.absoluteString)
            return
        }
        if isLoading {
            browser.stopLoading()
            finishLoading()
            return
        }
        errorView.isHidden = true
        if let retryURL, allows(retryURL) {
            browser.load(URLRequest(url: retryURL))
        } else if browser.url != nil {
            browser.reload()
        } else {
            loadInitialPage()
        }
    }

    private func allows(_ target: URL) -> Bool {
        guard previewLease?.isClosed != true, target.user == nil, target.password == nil else { return false }
        return (target.scheme?.lowercased() == "https" && target.host?.isEmpty == false)
            || previewLease?.allowsHTTP(target) == true
    }

    private func refreshNavigation() {
        guard previewLease?.isClosed != true else {
            finishLoading()
            return
        }
        isLoading = browser.isLoading
        if isLoading { activity.startAnimating() } else { activity.stopAnimating() }
        if let lease = previewLease, !lease.isClosed, let actual = browser.url, allows(actual) {
            reconnectAddress = lease.reportedURL(actual).absoluteString
        }
        updateToolbar()
    }

    private func updateToolbar() {
        backItem.isEnabled = browser.canGoBack
        forwardItem.isEnabled = browser.canGoForward
        reloadItem.image = UIImage(systemName: isLoading ? "xmark" : "arrow.clockwise")
        reloadItem.accessibilityLabel = isLoading ? "Stop loading" : "Reload preview"
        let actual = browser.url.flatMap { allows($0) ? $0 : nil } ?? url
        let current = previewLease?.reportedURL(actual) ?? actual
        if !address.isFirstResponder { address.text = current.host.map { host in
            let port = current.port.map { ":\($0)" } ?? ""
            return host + port + (current.path == "/" ? "" : current.path)
        } }
        address.accessibilityValue = current.absoluteString
        address.accessibilityHint = browser.title
        var items = [backItem]
        if browser.canGoForward { items.append(forwardItem) }
        items += [UIBarButtonItem(systemItem: .flexibleSpace), UIBarButtonItem(customView: address),
                  UIBarButtonItem(systemItem: .flexibleSpace), reloadItem]
        if onClose != nil { items.append(closeItem) }
        toolbar.setItems(items, animated: false)
        view.setNeedsLayout()
    }

    private func finishLoading() {
        isLoading = false
        activity.stopAnimating()
        updateToolbar()
    }

    private func showFailure(_ message: String) {
        lastPageFailure = message
        hasLoadedPage = false
        finishLoading()
        errorDetail.text = message
        errorView.isHidden = false
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard previewLease?.isClosed != true else { return }
        isLoading = true
        hasLoadedPage = false
        lastPageFailure = nil
        errorView.isHidden = true
        retryURL = webView.url
        activity.startAnimating()
        updateToolbar()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard previewLease?.isClosed != true else { return }
        if let previewLease, !previewLease.isClosed { reconnectAddress = currentAddress }
        hasLoadedPage = true
        lastPageFailure = nil
        retryURL = nil
        finishLoading()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handle(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handle(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        showFailure("The page stopped responding. Reload it to continue.")
    }

    private func handle(_ error: Error) {
        guard previewLease?.isClosed != true else { return }
        if (error as NSError).code == NSURLErrorCancelled { return }
        showFailure(error.localizedDescription)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let target = navigationAction.request.url else { decisionHandler(.cancel); return }
        decisionHandler(allows(target) || target.absoluteString == "about:blank" ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let target = navigationAction.request.url, allows(target) {
            browser.load(navigationAction.request)
        }
        return nil
    }
}
