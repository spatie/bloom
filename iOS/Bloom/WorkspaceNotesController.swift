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
    private var saved: String?
    private var loading: Task<Void, Never>?
    private var saving: Task<Void, Never>?
    private var debounce: Task<Void, Never>?
    private lazy var save = UIBarButtonItem(systemItem: .save, primaryAction: UIAction { [weak self] _ in self?.saveNow() })
    private lazy var retry = UIBarButtonItem(systemItem: .refresh, primaryAction: UIAction { [weak self] _ in self?.loadNotes() })
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
        save.isEnabled = false
        retry.accessibilityLabel = "Reload workspace notes"
        let toolbar = UIToolbar()
        toolbar.items = [UIBarButtonItem(customView: status), .flexibleSpace(), retry, save]
        let stack = UIStackView(arrangedSubviews: [toolbar, editor]); stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor), stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor), stack.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 48)
        ])
        loadNotes()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if saved == nil && loading == nil { loadNotes() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        loading?.cancel(); loading = nil
        debounce?.cancel()
        saveNow()
    }

    private func loadNotes() {
        guard saving == nil else { return }
        loading?.cancel()
        debounce?.cancel()
        saved = nil
        editor.isEditable = false
        save.isEnabled = false
        retry.isEnabled = false
        editor.text = UserDefaults.standard.string(forKey: key) ?? ""
        status.text = "Loading notes…"
        loading = Task { [weak self] in
            guard let self else { return }
            do {
                guard model.address == origin, let service = model.service else { throw ConnectionFailure("Reconnect to load workspace notes.") }
                let text = try await service.notes(workspaceID: workspaceID)
                guard !Task.isCancelled else { return }
                guard model.address == origin, model.service != nil else { throw ConnectionFailure("Reconnect to load workspace notes.") }
                saved = text
                editor.text = UserDefaults.standard.string(forKey: key) ?? text
                editor.isEditable = true
                save.isEnabled = true
                status.text = WorkspaceNote.needsSave(stored: saved, typed: editor.text) ? "Draft saved on this device" : "Saved"
            } catch {
                guard !Task.isCancelled else { return }
                // Keep any device draft visible but read-only. A failed read is not an empty note.
                status.text = "Couldn’t load notes"
                if model.canSend, viewIfLoaded?.window != nil { show(error) }
            }
            loading = nil
            retry.isEnabled = true
        }
    }

    func textViewDidChange(_ textView: UITextView) {
        guard saved != nil else { return }
        UserDefaults.standard.set(editor.text, forKey: key)
        status.text = "Draft saved on this device"
        debounce?.cancel()
        debounce = Task { [weak self] in
            do { try await Task.sleep(for: WorkspaceNote.autosaveDelay) } catch { return }
            self?.saveNow()
        }
    }

    private func saveNow() {
        guard saving == nil, WorkspaceNote.needsSave(stored: saved, typed: editor.text) else { return }
        guard model.address == origin, let service = model.service else { status.text = "Reconnect to save notes"; return }
        let text = editor.text ?? ""
        guard text.utf8.count <= 1_048_576 else { status.text = "Notes exceed 1 MB"; return }
        status.text = "Saving…"
        saving = Task { [weak self] in
            guard let self else { return }
            do {
                try await service.saveNotes(text, workspaceID: workspaceID)
                guard model.address == origin else { saving = nil; return }
                saved = text
                saving = nil
                if editor.text == text { UserDefaults.standard.removeObject(forKey: key); status.text = "Saved" } else { saveNow() }
            } catch { saving = nil; status.text = "Draft saved on this device"; if model.canSend, viewIfLoaded?.window != nil { show(error) } }
        }
    }
}
