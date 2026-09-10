import UIKit
import BloomClient

/// UIKit owns editing and focus; the shared session owns persisted drafts and write ordering.
final class WorkspaceNotesController: UIViewController, UITextViewDelegate {
    private static let drafts = WorkspaceNoteDraftStore(file: URL.applicationSupportDirectory.appendingPathComponent("Notes/drafts.json"))
    private let model: MobileConnection
    private let workspaceID: WorkspaceID
    private let origin: String
    private let editor = UITextView()
    private let status = UILabel()
    private var session: WorkspaceNoteSession?
    private var observer: UUID?
    private var loading: Task<Void, Never>?
    private lazy var save = UIBarButtonItem(systemItem: .save, primaryAction: UIAction { [weak self] _ in self?.saveNow() })
    private lazy var retry = UIBarButtonItem(systemItem: .refresh, primaryAction: UIAction { [weak self] _ in self?.loadNotes() })
    private var legacyKey: String { "workspace.note.draft." + origin + "." + workspaceID.rawValue }
    var characters: Int { editor.text.count }

    init(model: MobileConnection, workspaceID: WorkspaceID) {
        self.model = model; self.workspaceID = workspaceID; origin = model.address
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("Use init(model:workspaceID:)") }
    deinit { loading?.cancel() }

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
        do {
            let session = try Self.drafts.session(scope: try RemoteOrigin.canonical(origin), workspaceID: workspaceID)
            self.session = session
            if let legacy = UserDefaults.standard.string(forKey: legacyKey) {
                session.importLegacyDraft(legacy)
                if session.draftError == nil { UserDefaults.standard.removeObject(forKey: legacyKey) }
            }
            update()
        } catch { status.text = "Saved notes could not be opened" }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        observer = session?.observe { [weak self] in self?.update() }
        loadNotes()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        loading?.cancel(); loading = nil
        if let observer { session?.removeObserver(observer) }; observer = nil
        saveNow()
    }

    private func loadNotes() {
        guard let session else { return }
        loading?.cancel()
        let model = model, origin = origin, workspaceID = workspaceID
        loading = Task {
            await session.load {
                guard model.address == origin, let service = model.service else { throw ConnectionFailure("Reconnect to load workspace notes.") }
                let text = try await service.notes(workspaceID: workspaceID)
                guard model.address == origin else { throw CancellationError() }
                return text
            }
        }
    }

    private var write: WorkspaceNoteSession.Write {
        let model = model, origin = origin, workspaceID = workspaceID
        return { text in
            guard model.address == origin, let service = model.service else { throw ConnectionFailure("Reconnect to save notes. Your draft is saved on this device.") }
            try await service.saveNotes(text, workspaceID: workspaceID)
        }
    }

    func textViewDidChange(_ textView: UITextView) { session?.edit(editor.text, using: write) }
    private func saveNow() { session?.save(using: write) }

    private func update() {
        guard let session else { return }
        if editor.text != session.text { editor.text = session.text }
        editor.isEditable = session.canEdit
        save.isEnabled = session.canEdit && session.hasChanges && !session.isSaving
        retry.isEnabled = !session.isLoading && !session.isSaving
        if let error = session.draftError { status.text = error
        } else if session.isSaving { status.text = "Saving…"
        } else if session.saveError != nil { status.text = "Draft saved on this device. Retry saving."
        } else if session.hasChanges { status.text = "Draft saved on this device"
        } else if session.loadError != nil { status.text = "Couldn’t load notes. Retry when connected."
        } else if session.isLoading { status.text = "Loading notes…"
        } else { status.text = "Saved" }
        status.sizeToFit()
    }
}
