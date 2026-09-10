import UIKit
import BloomClient
import BloomSSH
@preconcurrency import AppAuth

/// One connection form on iPhone and iPad. SSH keys are generated on the device, never pasted
/// into a form whose contents could become a saved preference or diagnostic attachment.
final class ServerConnectionController: UITableViewController {
    private let model: MobileConnection
    private let transport = UISegmentedControl(items: ["SSH", "HTTPS"])
    private let host = UITextField()
    private let username = UITextField()
    private let port = UITextField()
    private let executable = UITextField()
    private let directory = UITextField()
    private let https = UITextField()
    private var connecting = false
    private var task: Task<Void, Never>?

    init(model: MobileConnection) { self.model = model; super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("Use init(model:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Connect to Server"
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
            self?.task?.cancel(); self?.dismiss(animated: true)
        })
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Connect", primaryAction: UIAction { [weak self] _ in self?.connect() })
        if model.service != nil || model.catalogue != nil || model.canRetryConnection {
            toolbarItems = [UIBarButtonItem(title: model.address.hasPrefix("https:") ? "Sign Out" : "Disconnect", primaryAction: UIAction { [weak self] _ in
                guard let self else { return }
                do {
                    if model.address.hasPrefix("https:") { try model.authentication.signOut(address: model.address) }
                    model.disconnect(); dismiss(animated: true)
                } catch { show(error) }
            })]
            navigationController?.setToolbarHidden(false, animated: false)
        }
        let saved = UserDefaults.standard.data(forKey: "server.ssh").flatMap { try? JSONDecoder().decode(SSHConfiguration.self, from: $0) }
        host.text = saved?.host; host.placeholder = "IP address or hostname"
        username.text = saved?.username ?? "bloom"
        port.text = String(saved?.port ?? 22); port.keyboardType = .numberPad
        executable.text = saved?.executable ?? SSHConfiguration.defaultExecutable
        directory.text = saved?.dataDirectory ?? SSHConfiguration.defaultDataDirectory
        https.text = model.address.hasPrefix("https:") ? model.address : nil
        https.placeholder = "https://bloom.example.com"; https.keyboardType = .URL
        transport.selectedSegmentIndex = model.address.hasPrefix("https:") ? 1 : 0
        transport.addAction(UIAction { [weak self] _ in self?.tableView.reloadData() }, for: .valueChanged)
        for field in [host, username, port, executable, directory, https] {
            field.autocapitalizationType = .none; field.autocorrectionType = .no
            field.font = .preferredFont(forTextStyle: .body); field.adjustsFontForContentSizeCategory = true
            field.clearButtonMode = .whileEditing
        }
    }

    override func numberOfSections(in tableView: UITableView) -> Int { transport.selectedSegmentIndex == 0 ? 4 : 2 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if transport.selectedSegmentIndex == 1 { return 1 }
        return [1, 2, 1, 4][section]
    }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if section == 0 { return nil }
        return ["", "Server", "This device's SSH key", "Advanced"][section]
    }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if transport.selectedSegmentIndex == 1 {
            return section == 1 ? "Use your Bloom Gateway HTTPS address. You will sign in through your browser." : nil
        }
        if section == 1 { return "Connect directly to your existing SSH server. No domain, VPN or gateway is required." }
        if section == 2 { return "Add this public key to ~/.ssh/authorized_keys for the selected server account. Its private key stays in this device's Keychain." }
        if section == 3 { return "The defaults match Bloom's server installer. Change these only for an existing custom installation." }
        return nil
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        if indexPath.section == 0 { attach(transport, to: cell); return cell }
        if transport.selectedSegmentIndex == 1 { attach(https, to: cell); return cell }
        if indexPath.section == 2 {
            cell.textLabel?.text = "Copy Public Key"; cell.textLabel?.textColor = .tintColor
            cell.imageView?.image = UIImage(systemName: "key"); cell.selectionStyle = .default
            return cell
        }
        if indexPath.section == 3, indexPath.row == 3 {
            cell.textLabel?.text = "Verify Host Key Again"; cell.textLabel?.textColor = .tintColor
            cell.selectionStyle = .default
            return cell
        }
        let fields = indexPath.section == 1 ? [host, username] : [port, executable, directory]
        let labels = indexPath.section == 1 ? ["Address", "Username"] : ["Port", "Executable", "Data directory"]
        let label = UILabel(); label.text = labels[indexPath.row]; label.font = .preferredFont(forTextStyle: .caption1)
        label.textColor = .secondaryLabel
        let stack = UIStackView(arrangedSubviews: [label, fields[indexPath.row]])
        stack.axis = .vertical; stack.spacing = 4
        attach(stack, to: cell)
        return cell
    }
    private func attach(_ view: UIView, to cell: UITableViewCell) {
        view.translatesAutoresizingMaskIntoConstraints = false; cell.contentView.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
            view.topAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.topAnchor),
            view.bottomAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.bottomAnchor),
        ])
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if indexPath.section == 3, indexPath.row == 3 {
            tableView.deselectRow(at: indexPath, animated: true); forgetHost(); return
        }
        guard indexPath.section == 2 else { return }
        tableView.deselectRow(at: indexPath, animated: true)
        do {
            UIPasteboard.general.string = try SSHIdentity.publicKey(SSHCredentials.identity()) + " bloom-ios"
            let alert = UIAlertController(title: "Public Key Copied", message: "Only the public key was copied. Add it to the server account's authorised keys, then connect.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default)); present(alert, animated: true)
        } catch { show(error) }
    }
    private func forgetHost() {
        do {
            guard let portNumber = Int(port.text ?? "") else { throw ConnectionFailure("Enter a valid SSH port.") }
            let configuration = try SSHConfiguration(host: host.text ?? "", port: portNumber, username: username.text ?? "")
            guard let saved = try SSHCredentials.fingerprint(for: configuration.hostIdentity) else {
                throw ConnectionFailure("No host key is saved for this address and port yet.")
            }
            let alert = UIAlertController(title: "Remove Saved Server Trust?", message: "Only continue if you have independently confirmed the server's identity or that it was rebuilt. You must verify its fingerprint again on your next connection.\n\n\(configuration.hostIdentity)\n\nSaved: \(saved)", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Remove Trust", style: .destructive) { [weak self] _ in
                do { try SSHCredentials.forgetHost(configuration.hostIdentity) } catch { self?.show(error) }
            })
            present(alert, animated: true)
        } catch { show(error) }
    }

    private func connect() {
        guard !connecting else { return }
        view.endEditing(true)
        task = Task {
            connecting = true; isModalInPresentation = true; tableView.isUserInteractionEnabled = false; navigationItem.rightBarButtonItem?.isEnabled = false
            defer { connecting = false; isModalInPresentation = false; tableView.isUserInteractionEnabled = true; navigationItem.rightBarButtonItem?.isEnabled = true }
            do {
                if transport.selectedSegmentIndex == 1 {
                    let address = https.text ?? ""
                    _ = try HTTPSConnection.origin(address)
                    try await model.authentication.signIn(address: address, externalUserAgent: OIDExternalUserAgentIOS(presenting: self))
                    try await model.connect(address: address)
                } else {
                    guard let portNumber = Int(port.text ?? "") else { throw ConnectionFailure("Enter an SSH port from 1 to 65535.") }
                    let configuration = try SSHConfiguration(host: host.text ?? "", port: portNumber, username: username.text ?? "", executable: executable.text ?? "", dataDirectory: directory.text ?? "")
                    do { try await model.connect(ssh: configuration) } catch let trust as SSHHostTrustRequired { confirm(trust, configuration: configuration); return }
                }
                guard !Task.isCancelled else { return }
                dismiss(animated: true)
            } catch is CancellationError {} catch { if !Task.isCancelled { show(error) } }
        }
    }
    private func confirm(_ trust: SSHHostTrustRequired, configuration: SSHConfiguration) {
        let alert = UIAlertController(title: "Verify Server Identity", message: "Compare this fingerprint with the server's SSH host key through a trusted source before continuing.\n\n\(configuration.hostIdentity)\n\n\(trust.fingerprint)", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Trust and Connect", style: .default) { [weak self] _ in
            guard let self else { return }
            do { try SSHCredentials.trust(trust.fingerprint, host: configuration.hostIdentity); connect() } catch { show(error) }
        })
        present(alert, animated: true)
    }
}
