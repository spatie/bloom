import UIKit
import BloomClient

/// Native form chrome over the same controls and model decisions used by the Mac composer.
final class ComposerOptionsController: UITableViewController {
    private enum Row: CaseIterable { case model, effort, permissions, context, fast, style, discard }
    private let store: RemoteComposerStore
    private let onApplied: (RemoteSession?) -> Void
    private var controls: ComposerControls?
    private var work: Task<Void, Never>?
    private var rows: [Row] {
        guard let controls else { return [] }
        return [.model, .effort, .permissions] + (controls.offersContextWindow ? [.context] : [])
            + (controls.offersFastMode ? [.fast] : []) + (controls.offersOutputStyle ? [.style] : [])
            + (store.hasPendingSave ? [.discard] : [])
    }

    init(store: RemoteComposerStore, onApplied: @escaping (RemoteSession?) -> Void) {
        self.store = store; self.onApplied = onApplied
        super.init(style: .insetGrouped)
        preferredContentSize = CGSize(width: 420, height: 520)
    }
    required init?(coder: NSCoder) { fatalError("Use init(store:onApplied:)") }
    deinit { work?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Agent options"
        view.tintColor = BloomTheme.accent
        tableView.backgroundColor = .systemGroupedBackground
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 54
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
            self?.work?.cancel()
            self?.dismiss(animated: true)
        })
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Apply", primaryAction: UIAction { [weak self] _ in self?.apply() })
        refreshUI()
        load()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true { work?.cancel() }
    }

    private func load() {
        work = Task { [weak self] in
            guard let self else { return }
            do {
                try await store.load()
                guard !Task.isCancelled else { return }
                controls = store.pendingControls ?? store.state?.controls
            } catch { if Task.isCancelled { return } }
            refreshUI()
        }
    }

    private func refreshUI() {
        navigationItem.rightBarButtonItem?.title = store.hasPendingSave ? "Retry save" : "Apply"
        navigationItem.rightBarButtonItem?.isEnabled = controls != nil && (store.hasPendingSave || controls != store.state?.controls) && !store.isApplying
        navigationItem.leftBarButtonItem?.isEnabled = !store.isApplying
        isModalInPresentation = store.isApplying
        tableView.isUserInteractionEnabled = !store.isApplying
        tableView.reloadData()
        tableView.layoutIfNeeded()
        preferredContentSize = CGSize(width: 420, height: min(620, max(380, tableView.contentSize.height + 60)))
        navigationController?.preferredContentSize = preferredContentSize
        if controls == nil {
            var empty = store.error == nil ? UIContentUnavailableConfiguration.loading() : .empty()
            empty.text = store.error == nil ? "Loading agent options" : "Options unavailable"
            empty.secondaryText = store.error
            if store.error != nil {
                empty.button.title = "Try again"
                empty.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.load() }
            }
            tableView.backgroundView = UIContentUnavailableView(configuration: empty)
        } else {
            let background = UIView()
            background.backgroundColor = .systemGroupedBackground
            tableView.backgroundView = background
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows.count }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard let controls else { return nil }
        if store.hasPendingSave {
            return "The last save has not been confirmed. Retry uses the same request, including any conversation it created."
        }
        if controls.agentKind != store.state?.controls.agentKind {
            return "Changing agents starts a new conversation in this workspace. Your current conversation stays available."
        }
        return "These options are saved on the server and used for your next message."
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        guard let controls else { return cell }
        var content = cell.defaultContentConfiguration()
        content.textProperties.font = .preferredFont(forTextStyle: .body)
        content.secondaryTextProperties.font = .preferredFont(forTextStyle: .subheadline)
        content.secondaryTextProperties.numberOfLines = 2
        cell.accessoryType = .disclosureIndicator
        switch rows[indexPath.row] {
        case .model: content.text = "Model"; content.secondaryText = ModelLabel.readable(controls.model)
        case .effort:
            content.text = "Reasoning"
            content.secondaryText = store.state?.choices.efforts(for: controls.agentKind, model: controls.model).first { $0.id == controls.effort }?.label ?? controls.effort.capitalized
        case .permissions: content.text = "Permissions"; content.secondaryText = controls.permissionMode.label(on: controls.agentKind)
        case .context: content.text = "Context window"; content.secondaryText = CodexContextWindow.label(for: controls.codexContextWindow)
        case .style: content.text = "Output style"; content.secondaryText = controls.outputStyle == OutputStyle.defaultName ? "Default" : controls.outputStyle
        case .discard:
            content.text = "Forget pending save"
            content.textProperties.color = .systemRed
        case .fast:
            content.text = "Prefer faster replies"
            let toggle = UISwitch()
            toggle.isOn = controls.isFastMode
            toggle.isEnabled = !store.hasPendingSave
            toggle.accessibilityLabel = "Prefer faster replies"
            toggle.addAction(UIAction { [weak self, weak toggle] _ in
                self?.controls?.isFastMode = toggle?.isOn == true
                self?.refreshUI()
            }, for: .valueChanged)
            cell.accessoryView = toggle
            cell.selectionStyle = .none
        }
        if store.hasPendingSave {
            cell.accessoryType = .none
            cell.selectionStyle = .none
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if rows[indexPath.row] == .discard { confirmDiscard(); return }
        guard !store.hasPendingSave, let controls, let state = store.state else { return }
        let row = rows[indexPath.row]
        let title: String
        let sections: [(String, [ComposerOption])]
        let selected: String
        switch row {
        case .model:
            title = "Model"; selected = controls.model
            sections = state.choices.sections(includingCurrent: controls.model, on: controls.agentKind).map { ($0.kind.label, $0.options) }
        case .effort:
            title = "Reasoning"; selected = controls.effort
            sections = [("", state.choices.efforts(for: controls.agentKind, model: controls.model))]
        case .permissions:
            title = "Permissions"; selected = controls.permissionMode.rawValue
            sections = [("", controls.permissionModeChoices.map { ComposerOption(id: $0.mode.rawValue, label: $0.label, detail: $0.summary) })]
        case .context:
            title = "Context window"; selected = String(controls.codexContextWindow)
            sections = [("", CodexContextWindow.options(including: controls.codexContextWindow).map { ComposerOption(id: String($0), label: CodexContextWindow.label(for: $0)) })]
        case .style:
            title = "Output style"; selected = controls.outputStyle
            sections = [("", state.styles.map { ComposerOption(id: $0.name, label: $0.name == OutputStyle.defaultName ? "Default" : $0.name, detail: $0.detail) })]
        case .fast, .discard: return
        }
        let picker = ComposerChoiceController(title: title, sections: sections, selected: selected) { [weak self] value in
            guard let self, var next = self.controls else { return }
            switch row {
            case .model: next = state.choices.selecting(value, in: next)
            case .effort: next.effort = value
            case .permissions: if let mode = PermissionMode(rawValue: value) { next.permissionMode = mode }
            case .context: if let tokens = Int(value) { next.codexContextWindow = tokens }
            case .style: next.outputStyle = value
            case .fast, .discard: break
            }
            self.controls = next
            self.refreshUI()
        }
        navigationController?.pushViewController(picker, animated: true)
    }

    private func confirmDiscard() {
        let alert = UIAlertController(title: "Forget this retry?",
                                      message: "The server may already have saved these settings or created a conversation. Check your workspace before applying different settings. Forgetting the retry does not undo anything on the server.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Keep retry", style: .cancel))
        alert.addAction(UIAlertAction(title: "Forget retry", style: .destructive) { [weak self] _ in
            guard let self else { return }
            do {
                try store.discardPendingSave()
                controls = nil
                refreshUI()
                load()
            } catch { show(error) }
        })
        present(alert, animated: true)
    }

    private func apply() {
        guard let controls, !store.isApplying else { return }
        work = Task { [weak self] in
            guard let self else { return }
            // Lock navigation before the request suspends, including interactive sheet dismissal.
            isModalInPresentation = true
            navigationController?.isModalInPresentation = true
            navigationItem.leftBarButtonItem?.isEnabled = false
            navigationItem.rightBarButtonItem?.isEnabled = false
            tableView.isUserInteractionEnabled = false
            do {
                let fork = try await store.apply(controls)
                dismiss(animated: true) { self.onApplied(fork) }
            } catch {
                navigationController?.isModalInPresentation = false
                refreshUI()
                show(error)
            }
        }
    }
}
