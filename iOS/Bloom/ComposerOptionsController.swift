import UIKit
import BloomClient

/// Native form chrome over the same controls and model decisions used by the Mac composer.
final class ComposerOptionsController: UITableViewController {
    private enum Row: CaseIterable { case model, effort, permissions, context, fast, style, discard }
    private let store: RemoteComposerStore?
    private var creationState: RemoteComposerState?
    private var onSelected: ((ComposerControls) -> Void)?
    private let onApplied: (RemoteSession?) -> Void
    private var controls: ComposerControls?
    private var work: Task<Void, Never>?
    private var state: RemoteComposerState? { store?.state ?? creationState }
    private var hasPendingSave: Bool { store?.hasPendingSave ?? false }
    private var isApplying: Bool { store?.isApplying ?? false }
    private var sections: [(title: String, rows: [Row])] {
        guard let controls else { return [] }
        let preferences: [Row] = (controls.offersContextWindow ? [.context] : [])
            + (controls.offersFastMode ? [.fast] : []) + (controls.offersOutputStyle ? [.style] : [])
        let efforts = state?.choices.efforts(for: controls.agentKind, model: controls.model) ?? []
        let agentRows: [Row] = [.model] + (efforts.isEmpty ? [] : [.effort])
        return [("Agent", agentRows), ("Access", [.permissions])]
            + (preferences.isEmpty ? [] : [("Preferences", preferences)])
            + (hasPendingSave ? [("Unconfirmed changes", [.discard])] : [])
    }

    init(store: RemoteComposerStore, onApplied: @escaping (RemoteSession?) -> Void) {
        self.store = store; self.onApplied = onApplied
        super.init(style: .insetGrouped)
        preferredContentSize = CGSize(width: 420, height: 520)
    }
    init(state: RemoteComposerState, onSelected: @escaping (ComposerControls) -> Void) {
        store = nil; creationState = state; self.onSelected = onSelected; onApplied = { _ in }
        super.init(style: .insetGrouped)
        preferredContentSize = CGSize(width: 420, height: 520)
    }
    required init?(coder: NSCoder) { fatalError("Use init(store:onApplied:)") }
    deinit { work?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Agent Options"
        view.tintColor = BloomTheme.accent
        tableView.backgroundColor = .systemGroupedBackground
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 54
        tableView.cellLayoutMarginsFollowReadableWidth = true
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
                try await store?.load()
                guard !Task.isCancelled else { return }
                controls = store?.pendingControls ?? state?.controls
            } catch { if Task.isCancelled { return } }
            refreshUI()
        }
    }

    private func refreshUI() {
        navigationItem.rightBarButtonItem?.title = hasPendingSave ? "Retry save" : (store == nil ? "Use options" : "Apply")
        navigationItem.rightBarButtonItem?.isEnabled = controls != nil && (hasPendingSave || controls != state?.controls) && !isApplying
        navigationItem.leftBarButtonItem?.isEnabled = !isApplying
        isModalInPresentation = isApplying
        tableView.isUserInteractionEnabled = !isApplying
        tableView.reloadData()
        tableView.layoutIfNeeded()
        preferredContentSize = CGSize(width: 420, height: min(620, max(380, tableView.contentSize.height + 60)))
        navigationController?.preferredContentSize = preferredContentSize
        if controls == nil {
            var empty = store?.error == nil ? UIContentUnavailableConfiguration.loading() : .empty()
            empty.text = store?.error == nil ? "Loading agent options" : "Options unavailable"
            empty.secondaryText = store?.error
            if store?.error != nil {
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

    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].rows.count }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { sections[section].title }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard let controls, section == sections.count - 1 else { return nil }
        if hasPendingSave {
            return "Your last changes haven’t been confirmed. Retry safely before making more changes."
        }
        if controls.agentKind != state?.controls.agentKind {
            return "Changing agents starts a new conversation in this workspace. Your current conversation stays available."
        }
        return "Applies to your next message."
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        guard let controls else { return cell }
        var content = cell.defaultContentConfiguration()
        content.textProperties.font = .preferredFont(forTextStyle: .body)
        content.textProperties.numberOfLines = 0
        content.secondaryTextProperties.font = .preferredFont(forTextStyle: .subheadline)
        content.secondaryTextProperties.numberOfLines = 0
        if traitCollection.preferredContentSizeCategory.isAccessibilityCategory { content.prefersSideBySideTextAndSecondaryText = false }
        cell.accessoryType = .disclosureIndicator
        switch sections[indexPath.section].rows[indexPath.row] {
        case .model: content.text = "Model"; content.secondaryText = ModelLabel.readable(controls.model)
        case .effort:
            content.text = "Reasoning"
            content.secondaryText = state?.choices.efforts(for: controls.agentKind, model: controls.model).first { $0.id == controls.effort }?.label ?? controls.effort.capitalized
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
            toggle.onTintColor = BloomTheme.accent
            toggle.isEnabled = !hasPendingSave
            toggle.accessibilityLabel = "Prefer faster replies"
            toggle.addAction(UIAction { [weak self, weak toggle] _ in
                self?.controls?.isFastMode = toggle?.isOn == true
                self?.refreshUI()
            }, for: .valueChanged)
            cell.accessoryView = toggle
            cell.selectionStyle = .none
        }
        if hasPendingSave {
            cell.accessoryType = .none
            cell.selectionStyle = .none
            if sections[indexPath.section].rows[indexPath.row] != .discard { content.textProperties.color = .secondaryLabel }
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if sections[indexPath.section].rows[indexPath.row] == .discard { confirmDiscard(); return }
        guard !hasPendingSave, let controls, let state = state else { return }
        let row = sections[indexPath.section].rows[indexPath.row]
        let title: String
        let choiceSections: [(String, [ComposerOption])]
        let selected: String
        switch row {
        case .model:
            title = "Model"; selected = controls.model
            choiceSections = state.choices.sections(includingCurrent: controls.model, on: controls.agentKind).map { ($0.kind.label, $0.options) }
        case .effort:
            title = "Reasoning"; selected = controls.effort
            choiceSections = [("", state.choices.efforts(for: controls.agentKind, model: controls.model))]
        case .permissions:
            title = "Permissions"; selected = controls.permissionMode.rawValue
            choiceSections = [("", controls.permissionModeChoices.map { ComposerOption(id: $0.mode.rawValue, label: $0.label, detail: $0.summary) })]
        case .context:
            title = "Context window"; selected = String(controls.codexContextWindow)
            choiceSections = [("", CodexContextWindow.options(including: controls.codexContextWindow).map { ComposerOption(id: String($0), label: CodexContextWindow.label(for: $0)) })]
        case .style:
            title = "Output style"; selected = controls.outputStyle
            choiceSections = [("", state.styles.map { ComposerOption(id: $0.name, label: $0.name == OutputStyle.defaultName ? "Default" : $0.name, detail: $0.detail) })]
        case .fast, .discard: return
        }
        let picker = ComposerChoiceController(title: title, sections: choiceSections, selected: selected) { [weak self] value in
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
            guard let self, let store = self.store else { return }
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
        guard let controls, !isApplying else { return }
        if let onSelected { dismiss(animated: true) { onSelected(controls) }; return }
        guard let store else { return }
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
