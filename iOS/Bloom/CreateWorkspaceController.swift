import UIKit
import BloomClient

/// Native creation form over the execution host's existing creation contract and planners.
final class CreateWorkspaceController: UITableViewController, UITextViewDelegate {
    private enum Row { case project, name, mode, prompt, source, base, options, setup, discard }
    private let model: MobileConnection
    private let origin: String
    private var project: RemoteProject
    private let name = UITextField()
    private let prompt = UITextView()
    private var mode = WorkspaceStartMode.chat
    private var context: RemoteWorkspaceContext?
    private var controls: ComposerControls?
    private var baseBranch: String?
    private var checkout: WorkspaceCheckout?
    private var runsSetup = true
    private var pending: RemoteCommand?
    private var isSubmitting = false
    private var loading: Task<Void, Never>?
    private var generation = 0
    var onCreated: ((RemoteWorkspaceCreated, WorkspaceStartMode) -> Void)?
    private var scope: String { "workspace:\(project.id.rawValue)" }
    private var rows: [Row] {
        [.project, .name, .mode] + (mode.runsAnAgent ? [.prompt] : []) + [.source]
            + (checkout == nil ? [.base] : []) + (mode.runsAnAgent ? [.options] : [])
            + (context?.hasSetupScript == true ? [.setup] : []) + (pending == nil ? [] : [.discard])
    }

    init(model: MobileConnection, project: RemoteProject) {
        self.model = model; self.project = project; origin = model.address
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError("Use init(model:project:)") }
    override func viewDidLoad() {
        super.viewDidLoad(); title = "New workspace"
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Create", primaryAction: UIAction { [weak self] _ in self?.create() })
        name.placeholder = "Workspace name"; name.font = .preferredFont(forTextStyle: .body)
        name.adjustsFontForContentSizeCategory = true; name.accessibilityLabel = "Workspace name"
        name.addAction(UIAction { [weak self] _ in self?.updateButton() }, for: .editingChanged)
        prompt.font = .preferredFont(forTextStyle: .body); prompt.adjustsFontForContentSizeCategory = true
        prompt.backgroundColor = .clear; prompt.accessibilityLabel = "Optional first prompt"; prompt.delegate = self
        prompt.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        tableView.rowHeight = UITableView.automaticDimension; tableView.keyboardDismissMode = .interactive
        restorePending(); loadContext()
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if !isSubmitting, isBeingDismissed || navigationController?.isBeingDismissed == true { loading?.cancel() }
    }
    func textViewDidChange(_ textView: UITextView) { updateButton() }
    private func updateButton() {
        navigationItem.rightBarButtonItem?.title = pending == nil ? "Create" : "Retry creation"
        navigationItem.rightBarButtonItem?.isEnabled = !isSubmitting && (pending != nil || (context != nil && (!(name.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (mode.runsAnAgent && !prompt.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))))
        navigationItem.leftBarButtonItem?.isEnabled = !isSubmitting
        name.isEnabled = pending == nil && !isSubmitting; prompt.isEditable = name.isEnabled
        isModalInPresentation = isSubmitting; navigationController?.isModalInPresentation = isSubmitting
    }
    private func restorePending() {
        do {
            pending = try CreationRecovery.store.pending(origin: origin, scope: scope)
            if let value = pending?.operation["create"]?["_0"] {
                let request = try JSONDecoder().decode(RemoteCreationRequest.self, from: JSONEncoder().encode(value))
                name.text = request.name; prompt.text = request.prompt ?? ""; mode = request.mode ?? .chat
                controls = request.controls; baseBranch = request.baseBranch; checkout = request.checkout
                runsSetup = request.runSetupScript != false
            }
        } catch { show(error) }
        updateButton()
    }
    private func loadContext() {
        guard model.address == origin, let service = model.service else { return }
        loading?.cancel(); generation += 1
        let generation = generation, project = project
        loading = Task { [weak self] in
            do {
                let context = try await service.workspaceContext(projectID: project.id)
                guard let self, !Task.isCancelled, generation == self.generation else { return }
                self.context = context
                if self.pending == nil { self.controls = context.composer.controls; self.baseBranch = project.defaultBranch ?? context.branches.first }
                self.tableView.reloadData(); self.updateButton()
            } catch { if !Task.isCancelled { self?.show(error, retry: { [weak self] in self?.loadContext() }) } }
        }
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows.count }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        pending != nil ? "Creation has not been confirmed. Retry sends the exact saved request, even after restarting the app."
            : "Leave the first prompt empty to create a workspace without starting an agent turn. Setup runs on the server."
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        switch rows[indexPath.row] {
        case .project: content.text = "Project"; content.secondaryText = project.name; cell.accessoryType = .disclosureIndicator
        case .name: embed(name, in: cell, height: 44); return cell
        case .prompt: embed(prompt, in: cell, height: 140); return cell
        case .mode:
            content.text = "Open with"
            let picker = UISegmentedControl(items: WorkspaceStartMode.allCases.map(\.label))
            picker.selectedSegmentIndex = WorkspaceStartMode.allCases.firstIndex(of: mode) ?? 0
            picker.isEnabled = pending == nil && !isSubmitting
            picker.addAction(UIAction { [weak self, weak picker] _ in
                guard let self, let index = picker?.selectedSegmentIndex, WorkspaceStartMode.allCases.indices.contains(index) else { return }
                self.mode = WorkspaceStartMode.allCases[index]; self.tableView.reloadData(); self.updateButton()
            }, for: .valueChanged)
            cell.accessoryView = picker
        case .source: content.text = "Start from"; content.secondaryText = checkoutLabel; cell.accessoryType = .disclosureIndicator
        case .base: content.text = "Base branch"; content.secondaryText = baseBranch ?? "Loading"; cell.accessoryType = .disclosureIndicator
        case .options: content.text = "Agent options"; content.secondaryText = controls.map { ModelLabel.readable($0.model) } ?? "Loading"; cell.accessoryType = .disclosureIndicator
        case .setup:
            content.text = "Run setup script"
            let toggle = UISwitch(); toggle.isOn = runsSetup; toggle.isEnabled = pending == nil && !isSubmitting
            toggle.addAction(UIAction { [weak self, weak toggle] _ in self?.runsSetup = toggle?.isOn == true }, for: .valueChanged)
            cell.accessoryView = toggle
        case .discard: content.text = "Forget saved retry"; content.textProperties.color = .systemRed
        }
        content.secondaryTextProperties.numberOfLines = 2
        cell.contentConfiguration = content
        return cell
    }
    private func embed(_ control: UIView, in cell: UITableViewCell, height: CGFloat) {
        control.removeFromSuperview(); control.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(control)
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
            control.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
            control.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 4),
            control.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -4),
            control.heightAnchor.constraint(greaterThanOrEqualToConstant: height),
        ])
    }
    private var checkoutLabel: String {
        switch checkout {
        case .none: "New branch"
        case .branch(let branch): branch.name
        case .pullRequest(let request): "#\(request.number) \(request.title)"
        }
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let row = rows[indexPath.row]
        if row == .discard { discard(); return }
        guard pending == nil, !isSubmitting else { return }
        switch row {
        case .project:
            navigationController?.pushViewController(CreationProjectPickerController(model: model) { [weak self] project in
                guard let self else { return }
                self.project = project; self.context = nil; self.checkout = nil; self.name.text = ""; self.prompt.text = ""
                self.restorePending(); self.tableView.reloadData(); self.loadContext()
            }, animated: true)
        case .source:
            guard model.address == origin, let service = model.service else { return }
            navigationController?.pushViewController(WorkspaceCheckoutPickerController(service: service, project: project) { [weak self] checkout in
                guard let self else { return }
                self.checkout = checkout
                if (self.name.text ?? "").isEmpty {
                    switch checkout {
                    case .pullRequest(let request): self.name.text = "#\(request.number) \(request.title)"
                    case .branch(let branch): self.name.text = branch.name
                    case .none: break
                    }
                }
                self.tableView.reloadData(); self.updateButton()
            }, animated: true)
        case .base:
            let options = context?.branches.map { ComposerOption(id: $0, label: $0) } ?? []
            navigationController?.pushViewController(ComposerChoiceController(title: "Base branch", sections: [("", options)], selected: baseBranch ?? "") { [weak self] branch in
                self?.baseBranch = branch; self?.tableView.reloadData()
            }, animated: true)
        case .options:
            guard var state = context?.composer, let controls else { return }
            state.controls = controls
            let options = ComposerOptionsController(state: state) { [weak self] value in self?.controls = value; self?.tableView.reloadData() }
            present(BloomTheme.navigation(options), animated: true)
        default: break
        }
    }
    private func discard() {
        guard !isSubmitting else { return }
        let alert = UIAlertController(title: "Forget this retry?", message: "The server may already have created this workspace. Check your workspaces first. Forgetting the retry does not remove anything from the server.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Keep retry", style: .cancel))
        alert.addAction(UIAlertAction(title: "Forget retry", style: .destructive) { [weak self] _ in
            guard let self else { return }
            do { try CreationRecovery.store.discard(origin: origin, scope: scope); pending = nil; tableView.reloadData(); updateButton() } catch { show(error) }
        })
        present(alert, animated: true)
    }
    private func create() {
        guard !isSubmitting, model.address == origin, let service = model.service else { return }
        do {
            if pending == nil {
                guard let context, let controls else { return }
                let request = try RemoteCreationRequest.planned(project: project, name: name.text ?? "", prompt: prompt.text,
                    mode: mode, context: context, controls: controls, baseBranch: baseBranch, checkout: checkout, runSetupScript: runsSetup)
                pending = try CreationRecovery.store.prepare(service.creationCommand(request), origin: origin, scope: scope)
            }
            guard let command = pending else { return }
            isSubmitting = true; updateButton(); tableView.isUserInteractionEnabled = false
            Task { [self] in
                defer { isSubmitting = false; tableView.isUserInteractionEnabled = true; updateButton() }
                do {
                    let created = try RemoteWorkspaceCreated.decode(await service.client.request(command))
                    if created.setupSucceeded == false, let session = created.session,
                       let firstPrompt = command.operation["create"]?["_0"]?["prompt"]?.stringValue, !firstPrompt.isEmpty {
                        try MobileConnection.drafts.save(text: firstPrompt, origin: origin, sessionID: session.id)
                    }
                    try CreationRecovery.store.acknowledge(command, origin: origin, scope: scope)
                    pending = nil
                    try? await model.refresh()
                    dismiss(animated: true) { self.onCreated?(created, self.mode) }
                } catch { tableView.reloadData(); show(error) }
            }
        } catch { show(error) }
    }
}
