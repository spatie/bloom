import UIKit

/// This screen handles public material only. The private identity is never passed to a view.
final class SSHDeviceAccessController: UITableViewController {
    private let publicKey: String
    private let username: String
    private var copied = false

    init(publicKey: String, username: String) {
        self.publicKey = publicKey
        self.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError("Use init(publicKey:username:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Authorise This Device"
        navigationItem.largeTitleDisplayMode = .never
        BloomTheme.list(tableView)
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 80
        tableView.cellLayoutMarginsFollowReadableWidth = true
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 3 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { [2, 3, 1][section] }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        ["1. Your device key", "2. Add it to your server", "You stay in control"][section]
    }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 1 ? "Return to Connect to Server when the public key has been added. Bloom will then ask you to verify the server’s identity." : nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.textProperties.numberOfLines = 0
        content.textProperties.font = .preferredFont(forTextStyle: .body)
        content.secondaryTextProperties.numberOfLines = 0
        content.secondaryTextProperties.font = .preferredFont(forTextStyle: .subheadline)
        content.secondaryTextProperties.color = .secondaryLabel
        content.imageProperties.tintColor = BloomTheme.accent
        cell.selectionStyle = .none
        switch (indexPath.section, indexPath.row) {
        case (0, 0):
            content.text = "A key of your own"
            content.secondaryText = "Bloom generated this device’s key. Your Mac’s private key is not needed."
            content.image = UIImage(systemName: "key")
        case (0, 1):
            content.text = "The private key stays here"
            content.secondaryText = "The private key stays in this device’s Keychain, available while unlocked. It does not sync to iCloud. Only the public key is shared."
            content.image = UIImage(systemName: "lock.shield")
        case (1, 0):
            content.text = "Use an existing trusted connection"
            content.secondaryText = "From your Mac or server console, add the public key to ~/.ssh/authorized_keys for the \(username.isEmpty ? "selected" : username) account. This gives this device access to that account."
        case (1, 1):
            content.text = copied ? "Public Key Copied" : "Copy Public Key"
            content.image = UIImage(systemName: copied ? "checkmark" : "doc.on.doc")
            content.textProperties.color = BloomTheme.accent
            cell.selectionStyle = .default; cell.accessibilityTraits.insert(.button)
        case (1, 2):
            content.text = "Share Public Key…"
            content.secondaryText = "Send it to your Mac with AirDrop."
            content.image = UIImage(systemName: "square.and.arrow.up")
            content.textProperties.color = BloomTheme.accent
            cell.selectionStyle = .default; cell.accessibilityTraits.insert(.button)
        default:
            content.text = "Remove its public key from the server"
            content.secondaryText = "That prevents new SSH connections from this device. Existing connections must be closed separately. Other devices keep their own keys."
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 1 else { return }
        if indexPath.row == 1 {
            UIPasteboard.general.string = publicKey
            copied = true
            tableView.reloadRows(at: [indexPath], with: .none)
            UIAccessibility.post(notification: .announcement, argument: "Public key copied")
        } else if indexPath.row == 2 {
            let share = UIActivityViewController(activityItems: [publicKey], applicationActivities: nil)
            if let popover = share.popoverPresentationController, let cell = tableView.cellForRow(at: indexPath) {
                popover.sourceView = cell; popover.sourceRect = cell.bounds
            }
            present(share, animated: true)
        }
    }
}
