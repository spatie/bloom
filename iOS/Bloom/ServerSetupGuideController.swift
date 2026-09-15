import UIKit
import SwiftUI
import BloomUI

/// Initial provisioning belongs to Bloom on Mac. Mobile explains that handoff before asking
/// for an address, and returns to the existing connection flow without changing any credentials.
final class ServerSetupGuideController: UITableViewController {
    private let onConnect: (() -> Void)?

    init(onConnect: (() -> Void)? = nil) {
        self.onConnect = onConnect
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError("Use init(onConnect:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Set Up Bloom Server"
        navigationItem.largeTitleDisplayMode = .never
        BloomTheme.list(tableView)
        tableView.cellLayoutMarginsFollowReadableWidth = true
        tableView.estimatedRowHeight = 120
        if navigationController?.viewControllers.first === self {
            navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
                self?.dismiss(animated: true)
            })
        }
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "square.and.arrow.up"),
            primaryAction: UIAction { [weak self] _ in self?.shareSteps() })
        navigationItem.rightBarButtonItem?.accessibilityLabel = "Share setup steps"
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 3 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { [2, 3, 1][section] }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 1 ? "Start on your Mac" : nil
    }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 2 ? "Already have a Bloom Server? You can connect to it now." : nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        if indexPath.section == 0, indexPath.row == 0 {
            cell.contentConfiguration = UIHostingConfiguration {
                BloomServerIllustration(accent: Color(uiColor: BloomTheme.accent))
                    .frame(maxWidth: 500)
                    .frame(maxWidth: .infinity)
            }.margins(.all, 16)
            return cell
        }
        var content = cell.defaultContentConfiguration()
        content.textProperties.font = .preferredFont(forTextStyle: .headline)
        content.textProperties.numberOfLines = 0
        content.secondaryTextProperties.font = .preferredFont(forTextStyle: .body)
        content.secondaryTextProperties.numberOfLines = 0
        content.secondaryTextProperties.color = .secondaryLabel
        content.imageProperties.tintColor = BloomTheme.accent
        content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
        switch (indexPath.section, indexPath.row) {
        case (0, 1):
            content.text = "Your work travels with you"
            content.secondaryText = "Agents run on your server, even when you close Bloom. Connect from your iPhone, iPad or Mac to chat, review changes and preview your app."
        case (1, 0):
            content.text = "1. Bring an Ubuntu server"
            content.secondaryText = "Create a server with your hosting provider. Bloom supports Ubuntu 24.04 or 26.04 on x86_64. You’ll need its address and administrator SSH access."
            content.image = UIImage(systemName: "server.rack")
        case (1, 1):
            content.text = "2. Let Bloom install the tools"
            content.secondaryText = "In Bloom on your Mac, choose + at the bottom of the sidebar, then Add Server. Review the installation and sign in to GitHub and your agents."
            content.image = UIImage(systemName: "laptopcomputer")
        case (1, 2):
            content.text = "3. Connect this device"
            content.secondaryText = "Return here with the server address. Authorise this device’s public key for the Bloom account, then connect. Your private key stays on this device."
            content.image = UIImage(systemName: "key")
        default:
            content.text = "Enter Server Details"
            content.image = UIImage(systemName: "arrow.right.circle")
            content.textProperties.color = BloomTheme.accent
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
            cell.accessibilityTraits.insert(.button)
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 2 else { return }
        if let onConnect { onConnect() } else { navigationController?.popViewController(animated: true) }
    }

    private func shareSteps() {
        let steps = """
        Set up Bloom Server

        1. Create an Ubuntu 24.04 or 26.04 x86_64 server with your hosting provider. Have its address and administrator SSH access ready.
        2. In Bloom on Mac, choose + at the bottom of the sidebar, then Add Server. Follow setup, review the installation and sign in to GitHub and your agents.
        3. In Bloom on iPhone or iPad, enter the server address and choose Authorise This Device. Add its public key to the Bloom account on your server, then connect.

        Agents run on the server. Your device’s private key stays in its Keychain.
        """
        let share = UIActivityViewController(activityItems: [steps], applicationActivities: nil)
        share.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
        present(share, animated: true)
    }
}
