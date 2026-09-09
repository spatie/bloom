import UIKit
import BloomClient

/// Explicit, native controls. Polling never replaces a partially answered form.
final class ApprovalController: UIViewController {
    private let request: RemoteApproval
    private let sessionID: SessionID
    private let service: RemoteWorkspaceService
    private let completed: () async -> Void
    private let stack = UIStackView()
    private var draft = AgentQuestionDraft()
    private var command: RemoteCommand?
    private var buttons: [UIButton] = []
    private var fields: [UITextField] = []
    private var optionButtons: [String: [UIButton]] = [:]
    private var answerFields: [String: UITextField] = [:]
    private var submitButton: UIButton?
    private var retryButton: UIButton?
    private var sending = false

    init(request: RemoteApproval, sessionID: SessionID, service: RemoteWorkspaceService, completed: @escaping () async -> Void) {
        self.request = request; self.sessionID = sessionID; self.service = service; self.completed = completed
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("Use init(request:sessionID:service:completed:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = request.questions.isEmpty ? "Review request" : "Answer questions"
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        stack.axis = .vertical; stack.spacing = 16; stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -20),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -40),
        ])
        label(request.toolName, style: .headline)
        if request.questions.isEmpty {
            let context = UITextView()
            context.text = request.context; context.isEditable = false; context.isScrollEnabled = false
            context.font = .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize, weight: .regular)
            context.adjustsFontForContentSizeCategory = true
            stack.addArrangedSubview(context)
        }
        guard request.isSupported else {
            label("This request needs an interface that is not available on iPhone or iPad yet. Answer it in Bloom on Mac, or close this screen and stop the turn.")
            return
        }
        if request.questions.isEmpty {
            label("Allow once applies only to this call. It does not create a session or project permission.")
            button("Allow once") { [weak self] in self?.decide(allow: true) }
            button("Deny", destructive: true) { [weak self] in self?.decide(allow: false) }
        } else {
            for question in request.questions { questionFields(question) }
            submitButton = button("Send answers") { [weak self] in self?.answer() }
            updateCompleteness()
        }
    }

    private func questionFields(_ question: AgentQuestion) {
        label(question.question, style: .headline)
        optionButtons[question.id] = []
        for option in question.options {
            let control = button(option.label + (option.description.isEmpty ? "" : "\n" + option.description)) {}
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
            button.configuration?.image = button.isSelected ? UIImage(systemName: "checkmark") : nil
        }
    }

    private func label(_ text: String, style: UIFont.TextStyle = .body) {
        let label = UILabel()
        label.text = text; label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: style); label.adjustsFontForContentSizeCategory = true
        stack.addArrangedSubview(label)
    }

    @discardableResult private func button(_ title: String, destructive: Bool = false, action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        var configuration = UIButton.Configuration.bordered()
        configuration.title = title
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
        let command = self.command ?? proposed
        self.command = command
        sending = true
        buttons.forEach { $0.isEnabled = false }; fields.forEach { $0.isEnabled = false }
        isModalInPresentation = true
        navigationItem.leftBarButtonItem?.isEnabled = false
        Task {
            do {
                let result = try await service.client.request(command)
                guard result["accepted"]?.objectValue != nil else { throw ConnectionFailure("The server did not acknowledge this decision. Retry sends the same decision.") }
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
                        do { try self.execute(command) } catch { self.show(error) }
                    }
                }
                retryButton?.isEnabled = true
                show(error)
            }
        }
    }
}
