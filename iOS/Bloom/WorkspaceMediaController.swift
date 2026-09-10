import UIKit
import QuickLook
import BloomClient

/// Quick Look receives a downloaded file in this app's own cache, never a server filesystem URL.
final class WorkspaceMediaController: UIViewController, QLPreviewControllerDataSource {
    private let model: MobileConnection
    private let workspaceID: WorkspaceID
    private let path: String
    private let origin: String
    private let preview = QLPreviewController()
    private var file: URL?
    private var loading: Task<Void, Never>?
    private var failure: String?
    init(model: MobileConnection, workspaceID: WorkspaceID, path: String) {
        self.model = model; self.workspaceID = workspaceID; self.path = path; origin = model.address
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("Use init(model:workspaceID:path:)") }
    deinit { loading?.cancel(); if let file { try? FileManager.default.removeItem(at: file) } }

    func prepare() async throws {
        loadViewIfNeeded()
        await loading?.value
        guard file != nil else { throw ConnectionFailure(failure ?? "The file download was cancelled.") }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BloomTheme.background
        preview.dataSource = self
        addChild(preview)
        preview.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(preview.view)
        NSLayoutConstraint.activate([
            preview.view.topAnchor.constraint(equalTo: view.topAnchor), preview.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            preview.view.leadingAnchor.constraint(equalTo: view.leadingAnchor), preview.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        preview.didMove(toParent: self)
        loading = Task { [weak self] in
            guard let self else { return }
            do {
                guard model.address == origin, let service = model.service else { throw ConnectionFailure("Reconnect to download this file.") }
                let response = try await service.client.request(.call("workspace", ["workspaceID": .string(workspaceID.rawValue), "action": .object(["download": .object(["path": .string(path)])])]))
                guard !Task.isCancelled, model.address == origin,
                      let encoded = response["download"]?["_0"]?["data"]?.stringValue,
                      let data = Data(base64Encoded: encoded), data.count <= 8_388_608 else { throw ConnectionFailure("The server did not return this file within the download limit.") }
                let name = (path as NSString).lastPathComponent
                let local = URL.cachesDirectory.appendingPathComponent(UUID().uuidString + "-" + name)
                try data.write(to: local, options: .atomic)
                file = local
                preview.reloadData()
            } catch { failure = error.localizedDescription; if !Task.isCancelled { show(error) } }
        }
    }
    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { file == nil ? 0 : 1 }
    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem { (file ?? URL.cachesDirectory) as NSURL }
}
