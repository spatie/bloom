import UIKit
import BloomClient

/// Skill instructions are displayed as selectable text, never executed or rendered as web content.
final class ServerSkillInstructionsController: UIViewController {
    private let session: ServerSkillsSession
    private let skill: ServerSkill
    private let planID: String?
    private let refreshConnection: () async -> Bool
    private let text = UITextView()
    private var loading: Task<Void, Never>?
    init(session: ServerSkillsSession, skill: ServerSkill, planID: String?, refreshConnection: @escaping () async -> Bool) {
        self.session = session; self.skill = skill; self.planID = planID; self.refreshConnection = refreshConnection
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("Use init(session:skill:planID:)") }
    deinit { loading?.cancel() }
    override func viewDidLoad() {
        super.viewDidLoad(); title = "SKILL.md"
        view.backgroundColor = BloomTheme.background
        text.backgroundColor = BloomTheme.background; text.isEditable = false
        text.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .monospacedSystemFont(ofSize: 15, weight: .regular))
        text.adjustsFontForContentSizeCategory = true
        text.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        text.accessibilityIdentifier = "server-skill-instructions"
        text.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: view.leadingAnchor), text.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            text.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), text.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        loadInstructions()
    }
    private func loadInstructions() {
        loading?.cancel(); contentUnavailableConfiguration = UIContentUnavailableConfiguration.loading()
        loading = Task { [weak self] in
            guard let self else { return }
            let ready = await refreshConnection()
            guard !Task.isCancelled else { return }
            if ready, await session.readDetails(skillID: skill.id, planID: planID), session.contentSkillID == skill.id, session.contentPlanID == planID {
                text.text = session.content; contentUnavailableConfiguration = nil
            } else {
                var unavailable = UIContentUnavailableConfiguration.empty()
                unavailable.text = "Instructions couldn’t load"
                unavailable.secondaryText = session.error ?? "Reconnect to this server, then try again."
                unavailable.button.title = "Try Again"
                unavailable.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.loadInstructions() }
                contentUnavailableConfiguration = unavailable
            }
        }
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        loading?.cancel(); loading = nil
    }
}
