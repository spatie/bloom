import UIKit
import WebKit

/// Preview login belongs to its own browser origin. Agent-control bearer tokens never enter WebKit.
final class PreviewController: UIViewController, WKNavigationDelegate {
    private let url: URL
    private let browser = WKWebView(frame: .zero)
    init(url: URL) { self.url = url; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("Use init(url:)") }

    override func loadView() { view = browser }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = url.host
        browser.navigationDelegate = self
        browser.allowsBackForwardNavigationGestures = true
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .refresh, primaryAction: UIAction { [weak self] _ in self?.browser.reload() })
        browser.load(URLRequest(url: url))
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { show(error) }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let scheme = navigationAction.request.url?.scheme
        decisionHandler(scheme == "https" || scheme == "about" ? .allow : .cancel)
    }
}
