import UIKit
import BloomClient

/// Notes use native editing and the existing server note operation. An unsaved device draft
/// survives a network failure or closing its pane, and writes remain serial.
final class WorkspaceNotesController: UIViewController, UITextViewDelegate {
    private let model: MobileConnection
    private let workspaceID: WorkspaceID
    private let origin: String
    private let editor = UITextView()
    private let status = UILabel()
    private var saved = ""
    private var loading: Task<Void, Never>?
    private var saving: Task<Void, Never>?
    private var debounce: Task<Void, Never>?
    private var key: String { "workspace.note.draft." + origin + "." + workspaceID.rawValue }
    var characters: Int { editor.text.count }

    init(model: MobileConnection, workspaceID: WorkspaceID) {
        self.model = model; self.workspaceID = workspaceID; origin = model.address
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("Use init(model:workspaceID:)") }
    deinit { loading?.cancel(); debounce?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        editor.delegate = self
        editor.isEditable = false
        editor.font = .preferredFont(forTextStyle: .body)
        editor.adjustsFontForContentSizeCategory = true
        editor.backgroundColor = BloomTheme.background
        editor.textContainerInset = UIEdgeInsets(top: 20, left: 16, bottom: 20, right: 16)
        editor.accessibilityLabel = "Workspace notes"
        status.font = .preferredFont(forTextStyle: .footnote)
        status.textColor = .secondaryLabel
        status.text = "Loading notes…"
        let save = UIBarButtonItem(systemItem: .save, primaryAction: UIAction { [weak self] _ in self?.saveNow() })
        let toolbar = UIToolbar()
        toolbar.items = [UIBarButtonItem(customView: status), .flexibleSpace(), save]
        let stack = UIStackView(arrangedSubviews: [toolbar, editor]); stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor), stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor), stack.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 48)
        ])
        loading = Task { [weak self] in
            guard let self else { return }
            do {
                guard model.address == origin, let service = model.service else { throw ConnectionFailure("Reconnect to load workspace notes.") }
                let result = try await service.client.request(.call("workspace", ["workspaceID": .string(workspaceID.rawValue), "action": .object(["notes": .object([:])])]))
                guard !Task.isCancelled, model.address == origin else { return }
                saved = result["text"]?["_0"]?.stringValue ?? ""
                editor.text = UserDefaults.standard.string(forKey: key) ?? saved
                editor.isEditable = true
                status.text = editor.text == saved ? "Saved" : "Draft saved on this device"
            } catch {
                editor.text = UserDefaults.standard.string(forKey: key) ?? ""
                editor.isEditable = true
                status.text = "Couldn’t load notes"
                show(error)
            }
        }
    }

    func textViewDidChange(_ textView: UITextView) {
        UserDefaults.standard.set(editor.text, forKey: key)
        status.text = "Draft saved on this device"
        debounce?.cancel()
        debounce = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(800)) } catch { return }
            self?.saveNow()
        }
    }

    private func saveNow() {
        guard saving == nil, editor.text != saved else { return }
        guard model.address == origin, let service = model.service else { status.text = "Reconnect to save notes"; return }
        let text = editor.text ?? ""
        guard text.utf8.count <= 1_048_576 else { status.text = "Notes exceed 1 MB"; return }
        status.text = "Saving…"
        saving = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await service.client.request(.call("workspace", ["workspaceID": .string(workspaceID.rawValue), "action": .object(["saveNotes": .object(["_0": .string(text)])])]))
                guard model.address == origin else { saving = nil; return }
                saved = text
                saving = nil
                if editor.text == text { UserDefaults.standard.removeObject(forKey: key); status.text = "Saved" } else { saveNow() }
            } catch { saving = nil; status.text = "Draft saved on this device"; show(error) }
        }
    }
}
