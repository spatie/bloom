import UIKit
import WebKit

/// Preview login belongs to its own browser origin. Agent-control bearer tokens never enter WebKit.
final class PreviewController: UIViewController, WKNavigationDelegate, WKUIDelegate {
    var onClose: (() -> Void)? {
        didSet { if isViewLoaded { updateToolbar() } }
    }

    private let url: URL
    private let browser = WKWebView(frame: .zero)
    private let toolbar = UIToolbar()
    private let address = UILabel()
    private let activity = UIActivityIndicatorView(style: .medium)
    private let errorView = UIView()
    private let errorDetail = BloomTheme.label("", style: .subheadline, secondary: true)
    private var isLoading = false
    private var retryURL: URL?
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

    init(url: URL) {
        self.url = url
        super.init(nibName: nil, bundle: nil)
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
        loadInitialPage()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // A custom toolbar item has no flexible width. Reserve room for native history controls.
        address.frame.size = CGSize(width: max(80, toolbar.bounds.width - (onClose == nil ? 176 : 220)), height: 36)
    }

    private func configureToolbar() {
        let appearance = UIToolbarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = BloomTheme.panel
        appearance.shadowColor = BloomTheme.border
        toolbar.standardAppearance = appearance
        toolbar.scrollEdgeAppearance = appearance
        toolbar.tintColor = .secondaryLabel
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
        address.textColor = .secondaryLabel
        address.textAlignment = .center
        address.lineBreakMode = .byTruncatingMiddle
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
        symbol.tintColor = BloomTheme.secondary
        symbol.contentMode = .scaleAspectFit
        let heading = BloomTheme.label("Preview couldn’t load", style: .headline)
        heading.textAlignment = .center
        errorDetail.textAlignment = .center
        let retry = UIButton(configuration: .tinted(), primaryAction: UIAction { [weak self] _ in self?.reload() })
        retry.configuration?.title = "Try again"
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

    private func loadInitialPage() {
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
        target.scheme?.lowercased() == "https" && target.host?.isEmpty == false && target.user == nil && target.password == nil
    }

    private func updateToolbar() {
        backItem.isEnabled = browser.canGoBack
        forwardItem.isEnabled = browser.canGoForward
        reloadItem.image = UIImage(systemName: isLoading ? "xmark" : "arrow.clockwise")
        reloadItem.accessibilityLabel = isLoading ? "Stop loading" : "Reload preview"
        let current = browser.url.flatMap { $0.scheme == "https" ? $0 : nil } ?? url
        address.text = current.host.map { host in
            let port = current.port.map { ":\($0)" } ?? ""
            return host + port + (current.path == "/" ? "" : current.path)
        }
        address.accessibilityValue = current.absoluteString
        address.accessibilityHint = browser.title
        var items = [backItem, forwardItem, UIBarButtonItem(systemItem: .flexibleSpace),
                     UIBarButtonItem(customView: address), UIBarButtonItem(systemItem: .flexibleSpace), reloadItem]
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
        finishLoading()
        errorDetail.text = message
        errorView.isHidden = false
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        errorView.isHidden = true
        retryURL = webView.url
        activity.startAnimating()
        updateToolbar()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
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
