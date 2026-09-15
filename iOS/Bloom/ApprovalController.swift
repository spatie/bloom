import UIKit
import BloomClient

/// Explicit, native controls. Polling never replaces a partially answered form.
final class ApprovalController: UIViewController {
    private let request: RemoteApproval
    private let sessionID: SessionID
    private let origin: String
    private let currentService: @MainActor () throws -> (origin: String, service: RemoteWorkspaceService)
    private let completed: () async -> Void
    private let stack = UIStackView()
    private var draft = AgentQuestionDraft()
    private var submission: RemoteApprovalSubmission?
    private var buttons: [UIButton] = []
    private var fields: [UITextField] = []
    private var optionButtons: [String: [UIButton]] = [:]
    private var answerFields: [String: UITextField] = [:]
    private var submitButton: UIButton?
    private var retryButton: UIButton?
    private var sending = false

    init(request: RemoteApproval, sessionID: SessionID, origin: String,
         service: @escaping @MainActor () throws -> (origin: String, service: RemoteWorkspaceService),
         completed: @escaping () async -> Void) {
        self.request = request; self.sessionID = sessionID; self.origin = origin
        self.currentService = service; self.completed = completed
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("Use init(request:sessionID:service:completed:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = request.questions.isEmpty ? "Review Request" : "Your Input"
        view.backgroundColor = BloomTheme.background
        view.tintColor = BloomTheme.accent
        preferredContentSize = CGSize(width: 580, height: 640)
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        let scroll = UIScrollView()
        scroll.keyboardDismissMode = .interactive
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        stack.axis = .vertical; stack.spacing = 16; stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        let readableWidth = stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -40)
        readableWidth.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            scroll.contentLayoutGuide.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            stack.centerXAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerXAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 620), readableWidth,
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -20),
        ])
        if request.questions.isEmpty {
            label(request.toolName, style: .headline)
            let context = UITextView()
            context.text = request.context; context.isEditable = false; context.isScrollEnabled = false
            context.backgroundColor = BloomTheme.panel
            context.layer.cornerRadius = 12
            context.layer.cornerCurve = .continuous
            context.accessibilityLabel = "Requested action"
            context.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
            context.font = .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize, weight: .regular)
            context.adjustsFontForContentSizeCategory = true
            stack.addArrangedSubview(context)
        }
        guard request.isSupported else {
            label("This request needs an interface that is not available on iPhone or iPad yet. Answer it in Bloom on Mac, or close this screen and stop the turn.")
            return
        }
        if request.questions.isEmpty {
            label("Allow this action once. This does not change your conversation’s permissions.", style: .subheadline)
            button("Allow Once", primary: true) { [weak self] in self?.decide(allow: true) }
            button("Don’t Allow", destructive: true) { [weak self] in self?.decide(allow: false) }
        } else {
            for question in request.questions { questionFields(question) }
            submitButton = button("Send Answers", primary: true) { [weak self] in self?.answer() }
            updateCompleteness()
        }
    }

    private func questionFields(_ question: AgentQuestion) {
        label(question.question, style: .headline)
        if question.options.count > 1 { label(question.multiSelect ? "Choose all that apply." : "Choose one option.", style: .subheadline) }
        optionButtons[question.id] = []
        for option in question.options {
            let control = button(option.label) {}
            control.contentHorizontalAlignment = .leading
            control.configuration?.subtitle = option.description.isEmpty ? nil : option.description
            control.configuration?.titleAlignment = .leading
            control.configuration?.image = UIImage(systemName: question.multiSelect ? "square" : "circle")
            control.configuration?.imagePadding = 12
            control.configuration?.baseForegroundColor = .label
            control.configuration?.background.backgroundColor = BloomTheme.panel
            control.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                self.draft.toggle(option.label, on: question)
                self.answerFields[question.id]?.text = ""
                self.updateOptions(question)
                self.updateCompleteness()
            }, for: .touchUpInside)
            optionButtons[question.id, default: []].append(control)
            if let preview = option.preview { label(preview, style: .callout) }
        }
        if question.allowsOther {
            let field = UITextField()
            field.borderStyle = .roundedRect
            field.placeholder = question.options.isEmpty ? "Your answer" : "Other answer"
            field.accessibilityLabel = question.question
            field.font = .preferredFont(forTextStyle: .body); field.adjustsFontForContentSizeCategory = true
            field.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            field.isSecureTextEntry = question.isSecret
            field.autocorrectionType = question.isSecret ? .no : .default
            field.autocapitalizationType = question.isSecret ? .none : .sentences
            field.spellCheckingType = question.isSecret ? .no : .default
            field.addAction(UIAction { [weak self, weak field] _ in
                guard let self else { return }
                self.draft.writeOther(on: question)
                self.draft.other[question.id] = field?.text ?? ""
                self.updateOptions(question)
                self.updateCompleteness()
            }, for: .editingChanged)
            fields.append(field)
            answerFields[question.id] = field
            stack.addArrangedSubview(field)
        }
    }

    private func updateOptions(_ question: AgentQuestion) {
        for (index, button) in (optionButtons[question.id] ?? []).enumerated() {
            button.isSelected = draft.chosen[question.id]?.contains(question.options[index].label) == true
            button.accessibilityTraits = button.isSelected ? [.button, .selected] : .button
            let symbol = question.multiSelect
                ? (button.isSelected ? "checkmark.square.fill" : "square")
                : (button.isSelected ? "checkmark.circle.fill" : "circle")
            button.configuration?.image = UIImage(systemName: symbol)
            button.configuration?.baseForegroundColor = button.isSelected ? BloomTheme.accent : .label
            button.configuration?.background.backgroundColor = button.isSelected ? BloomTheme.accent.withAlphaComponent(0.08) : BloomTheme.panel
        }
    }

    private func label(_ text: String, style: UIFont.TextStyle = .body) {
        let label = UILabel()
        label.text = text; label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: style); label.adjustsFontForContentSizeCategory = true
        if style == .headline { label.accessibilityTraits.insert(.header) }
        if style == .subheadline { label.textColor = .secondaryLabel }
        stack.addArrangedSubview(label)
    }

    @discardableResult private func button(_ title: String, destructive: Bool = false, primary: Bool = false, action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        var configuration = primary ? UIButton.Configuration.filled() : .plain()
        configuration.title = title
        configuration.cornerStyle = .large
        configuration.baseBackgroundColor = BloomTheme.accent
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var attributes = incoming
            attributes.font = .preferredFont(forTextStyle: primary ? .headline : .body)
            return attributes
        }
        configuration.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var attributes = incoming
            attributes.font = .preferredFont(forTextStyle: .subheadline)
            attributes.foregroundColor = .secondaryLabel
            return attributes
        }
        if destructive { configuration.baseForegroundColor = .systemRed }
        button.configuration = configuration
        button.titleLabel?.numberOfLines = 0
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        stack.addArrangedSubview(button); buttons.append(button)
        return button
    }

    private func updateCompleteness() { submitButton?.isEnabled = !sending && draft.isComplete(request.questions) }
    private func decide(allow: Bool) {
        do { try execute(request.decision(sessionID: sessionID, allow: allow)) } catch { show(error) }
    }
    private func answer() {
        do { try execute(request.answer(sessionID: sessionID, draft: draft)) } catch { show(error) }
    }
    private func execute(_ proposed: RemoteCommand) throws {
        guard !sending else { return }
        let submission = try self.submission ?? RemoteApprovalSubmission(command: proposed, origin: origin)
        self.submission = submission
        sending = true
        buttons.forEach { $0.isEnabled = false }; fields.forEach { $0.isEnabled = false }
        isModalInPresentation = true
        navigationItem.leftBarButtonItem?.isEnabled = false
        Task {
            do {
                let current = try currentService()
                try await submission.submit(using: current.service.client, origin: current.origin)
                await completed()
                dismiss(animated: true)
            } catch {
                sending = false
                isModalInPresentation = false
                navigationItem.leftBarButtonItem?.isEnabled = true
                // The decision stays locked until acknowledged. A failed allow must never turn
                // into a deny sharing its command ID, or be automatically replayed as a new ID.
                if retryButton == nil {
                    retryButton = button("Retry decision") { [weak self] in
                        guard let self else { return }
                        do { try self.execute(submission.command) } catch { self.show(error) }
                    }
                }
                retryButton?.isEnabled = true
                show(error)
            }
        }
    }
}
