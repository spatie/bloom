import UIKit
import BloomAuthentication

/// Only this explicit access screen reads or shares the maintenance secret. Reports never do.
final class ServerMaintenanceAccessController: UITableViewController, UITextFieldDelegate {
    private let access: ServerMaintenanceAccess
    private let key = UITextField()
    private var feedback: String?

    init(access: ServerMaintenanceAccess) { self.access = access; super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("Use init(access:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Maintenance Access"
        navigationItem.largeTitleDisplayMode = .never
        BloomTheme.list(tableView)
        tableView.cellLayoutMarginsFollowReadableWidth = true
        key.placeholder = "Maintenance key"
        key.isSecureTextEntry = true
        key.autocorrectionType = .no; key.autocapitalizationType = .none; key.spellCheckingType = .no
        key.font = .preferredFont(forTextStyle: .body); key.adjustsFontForContentSizeCategory = true
        key.accessibilityLabel = "Maintenance key"
        key.returnKeyType = .done; key.delegate = self
        key.addAction(UIAction { [weak self] _ in self?.updateButton() }, for: .editingChanged)
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Save", primaryAction: UIAction { [weak self] _ in self?.save() })
        updateButton()
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !access.hasSavedCredential { key.becomeFirstResponder() }
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        key.text = ""
    }
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if navigationItem.rightBarButtonItem?.isEnabled == true { save() }
        return false
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 3 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? 1 : section == 1 ? (feedback == nil ? 0 : 1) : (access.hasSavedCredential ? 2 : 0)
    }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if section == 0 { return "Use the key created during server setup to allow updates from this device. It is saved in this device’s Keychain and does not sync to iCloud or appear in reports." }
        if section == 2, access.hasSavedCredential { return "Removing access here does not stop server updates or remove access from other devices." }
        return nil
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 0 {
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.selectionStyle = .none
            key.removeFromSuperview(); key.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.addSubview(key)
            NSLayoutConstraint.activate([
                key.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
                key.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
                key.topAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.topAnchor),
                key.bottomAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.bottomAnchor),
                key.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            ])
            return cell
        }
        if indexPath.section == 1 {
            let cell = BloomTheme.cell(title: feedback ?? "", symbol: "info.circle", disclosure: false)
            cell.selectionStyle = .none
            if var content = cell.contentConfiguration as? UIListContentConfiguration {
                content.textProperties.numberOfLines = 0; cell.contentConfiguration = content
            }
            return cell
        }
        return BloomTheme.cell(title: indexPath.row == 0 ? "Copy Key for Another Device" : "Remove Access from This Device",
            symbol: indexPath.row == 0 ? "doc.on.doc" : "minus.circle", tint: indexPath.row == 0 ? BloomTheme.accent : .systemRed, disclosure: false)
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 2, !access.isPairing else { return }
        if indexPath.row == 0 { confirmCopy() } else { confirmRemoval() }
    }

    private func updateButton() {
        navigationItem.rightBarButtonItem?.isEnabled = !(key.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !access.isPairing && access.session.activity == .idle
    }
    private func save() {
        guard navigationItem.rightBarButtonItem?.isEnabled == true else { return }
        view.endEditing(true)
        navigationItem.hidesBackButton = true; navigationItem.rightBarButtonItem?.isEnabled = false
        navigationItem.rightBarButtonItem?.title = "Checking…"
        isModalInPresentation = true; navigationController?.isModalInPresentation = true; tableView.isUserInteractionEnabled = false
        Task {
            let saved = await access.pair(token: key.text ?? "")
            isModalInPresentation = false; navigationController?.isModalInPresentation = false
            tableView.isUserInteractionEnabled = true; navigationItem.hidesBackButton = false
            navigationItem.rightBarButtonItem?.title = "Save"
            if saved { key.text = ""; navigationController?.popViewController(animated: true) } else {
                feedback = access.credentialFailure ?? access.session.failure?.message ?? "Maintenance access could not be confirmed. Try again."
                tableView.reloadData(); updateButton()
            }
        }
    }
    private func confirmCopy() {
        let alert = UIAlertController(title: "Copy maintenance access?", message: "This key allows server updates. Share it only with a device you trust. It will stay on this device’s clipboard for one minute.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Copy Key", style: .default) { [weak self] _ in
            guard let self else { return }
            do {
                guard let token = try ServerMaintenanceCredentials.load(serverID: access.serverID) else { return }
                UIPasteboard.general.setItems([["public.utf8-plain-text": token]], options: [.expirationDate: Date().addingTimeInterval(60)])
                feedback = "Key copied. Paste it into Maintenance Access on your other device."
                tableView.reloadData()
                UIAccessibility.post(notification: .announcement, argument: "Maintenance key copied")
            } catch { show(error) }
        })
        present(alert, animated: true)
    }
    private func confirmRemoval() {
        let alert = UIAlertController(title: "Remove maintenance access?", message: "Updates already running on the server will continue. Other devices keep their access.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Remove Access", style: .destructive) { [weak self] _ in
            guard let self else { return }
            do { try access.forget(); navigationController?.popViewController(animated: true) } catch { show(error) }
        })
        present(alert, animated: true)
    }
}
