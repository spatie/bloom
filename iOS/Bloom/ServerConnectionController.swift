import UIKit
import BloomClient
import BloomSSH
@preconcurrency import AppAuth

/// One connection form on iPhone and iPad. SSH keys are generated on the device, never pasted
/// into a form whose contents could become a saved preference or diagnostic attachment.
final class ServerConnectionController: UIViewController, UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate {
    private let model: MobileConnection
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let content = UIStackView()
    private let introduction = UIStackView()
    private let connectionStatus = UILabel()
    private var introductionWidth: NSLayoutConstraint?
    private var tableHeight: NSLayoutConstraint?
    private var usesColumns = false
    private var showsAdvanced = false
    private var hasFocusedAddress = false
    private let transport = UISegmentedControl(items: ["SSH", "HTTPS"])
    private let host = UITextField()
    private let username = UITextField()
    private let port = UITextField()
    private let executable = UITextField()
    private let directory = UITextField()
    private let https = UITextField()
    private var connecting = false
    private var task: Task<Void, Never>?

    init(model: MobileConnection) { self.model = model; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("Use init(model:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Connect to Server"
        configureLayout()
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
        showsAdvanced = (saved?.port ?? 22) != 22
            || executable.text != SSHConfiguration.defaultExecutable || directory.text != SSHConfiguration.defaultDataDirectory
        https.text = model.address.hasPrefix("https:") ? model.address : nil
        https.placeholder = "https://bloom.example.com"; https.keyboardType = .URL
        transport.selectedSegmentIndex = model.address.hasPrefix("https:") ? 1 : 0
        transport.addAction(UIAction { [weak self] _ in
            self?.tableView.reloadData(); self?.updateConnectButton()
        }, for: .valueChanged)
        for field in [host, username, port, executable, directory, https] {
            field.autocapitalizationType = .none; field.autocorrectionType = .no
            field.font = .preferredFont(forTextStyle: .body); field.adjustsFontForContentSizeCategory = true
            field.clearButtonMode = .whileEditing
            field.delegate = self
            field.returnKeyType = field === host ? .next : .go
            field.addAction(UIAction { [weak self] _ in self?.updateConnectButton() }, for: .editingChanged)
        }
        host.accessibilityLabel = "Server address"
        username.accessibilityLabel = "SSH username"
        https.accessibilityLabel = "HTTPS server address"
        port.accessibilityLabel = "SSH port"
        executable.accessibilityLabel = "Server executable"
        directory.accessibilityLabel = "Server data directory"
        updateConnectButton()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !hasFocusedAddress else { return }
        hasFocusedAddress = true
        let field = transport.selectedSegmentIndex == 0 ? host : https
        if (field.text ?? "").isEmpty {
            tableView.scrollToRow(at: IndexPath(row: 0, section: 1), at: .top, animated: false)
            tableView.layoutIfNeeded()
            field.becomeFirstResponder()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let wide = view.bounds.width >= 1000 && !traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        if wide != usesColumns {
            usesColumns = wide
            if wide {
                tableView.tableHeaderView = nil
                introduction.translatesAutoresizingMaskIntoConstraints = false
                content.insertArrangedSubview(introduction, at: 0)
                content.axis = .horizontal; content.alignment = .top
            } else {
                introductionWidth?.isActive = false
                content.removeArrangedSubview(introduction); introduction.removeFromSuperview()
                content.axis = .vertical; content.alignment = .fill
                introduction.translatesAutoresizingMaskIntoConstraints = true
                tableView.tableHeaderView = introduction
            }
            introductionWidth?.isActive = wide
            tableHeight?.isActive = wide
        }
        if !wide {
            let width = tableView.bounds.width
            let height = introduction.systemLayoutSizeFitting(CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height
            let size = CGSize(width: width, height: height)
            if introduction.frame.size != size {
                introduction.frame = CGRect(origin: .zero, size: size)
                tableView.tableHeaderView = introduction
            }
        }
        // A contained table no longer gets UITableViewController's keyboard scrolling.
        if let field = [host, username, port, executable, directory, https].first(where: \.isFirstResponder), field.isDescendant(of: tableView) {
            let rect = field.convert(field.bounds, to: tableView).insetBy(dx: 0, dy: -12)
            if !tableView.bounds.inset(by: tableView.adjustedContentInset).contains(rect) {
                tableView.scrollRectToVisible(rect, animated: false)
            }
        }
    }

    func textFieldDidBeginEditing(_ textField: UITextField) { view.setNeedsLayout() }

    private func configureLayout() {
        view.backgroundColor = .systemGroupedBackground
        view.tintColor = BloomTheme.accent
        let icon = UIImageView(image: UIImage(systemName: "server.rack",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 36, weight: .regular)))
        icon.tintColor = BloomTheme.accent; icon.contentMode = .left
        icon.accessibilityElementsHidden = true
        let heading = BloomTheme.label("Your workspace, wherever you are.", style: .largeTitle)
        let detail = BloomTheme.label("Connect to Bloom Server to pick up your projects and conversations. Your agents keep working when you leave.", style: .body, secondary: true)
        connectionStatus.font = .preferredFont(forTextStyle: .subheadline)
        connectionStatus.adjustsFontForContentSizeCategory = true
        connectionStatus.textColor = BloomTheme.accent
        connectionStatus.numberOfLines = 0
        connectionStatus.isHidden = true
        introduction.axis = .vertical; introduction.alignment = .fill; introduction.spacing = 12
        [icon, heading, detail, connectionStatus].forEach { introduction.addArrangedSubview($0) }
        introduction.setContentHuggingPriority(.required, for: .vertical)
        introductionWidth = introduction.widthAnchor.constraint(equalToConstant: 300)
        tableView.dataSource = self; tableView.delegate = self
        tableView.rowHeight = UITableView.automaticDimension; tableView.estimatedRowHeight = 72
        tableView.keyboardDismissMode = .interactive
        tableView.cellLayoutMarginsFollowReadableWidth = true
        tableView.backgroundColor = .clear
        tableView.sectionHeaderTopPadding = 12
        content.axis = .vertical; content.spacing = 24; content.alignment = .fill
        content.addArrangedSubview(tableView)
        introduction.translatesAutoresizingMaskIntoConstraints = true
        tableView.tableHeaderView = introduction
        tableHeight = tableView.heightAnchor.constraint(equalTo: content.heightAnchor)
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            content.widthAnchor.constraint(lessThanOrEqualToConstant: 1040),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            content.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            content.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -12),
        ])
        let width = content.widthAnchor.constraint(equalTo: view.safeAreaLayoutGuide.widthAnchor, constant: -48)
        width.priority = .defaultHigh; width.isActive = true
    }

    private func updateConnectButton() {
        let address = transport.selectedSegmentIndex == 0 ? host.text : https.text
        navigationItem.rightBarButtonItem?.isEnabled = !connecting
            && !(address ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (transport.selectedSegmentIndex == 1 || !(username.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === host { username.becomeFirstResponder() } else if navigationItem.rightBarButtonItem?.isEnabled == true { connect() }
        return false
    }

    func numberOfSections(in tableView: UITableView) -> Int { transport.selectedSegmentIndex == 0 ? 4 : 2 }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if transport.selectedSegmentIndex == 1 { return 1 }
        return [1, 2, 1, showsAdvanced ? 6 : 1][section]
    }
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if section == 0 { return nil }
        return ["Connection method", "Server", "Device access", ""][section]
    }
    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if transport.selectedSegmentIndex == 1 {
            return section == 1 ? "Use your Bloom Gateway HTTPS address. You will sign in through your browser." : nil
        }
        if section == 1 { return "Connect directly to your existing SSH server. No domain, VPN or gateway is required." }
        if section == 2 { return "Use a key generated on this device. If it is already authorised on your server, you can connect now." }
        if section == 3, showsAdvanced { return "These defaults match Bloom’s installer. Keep them unless your server uses a custom installation." }
        return nil
    }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        if indexPath.section == 0 { attach(transport, to: cell); return cell }
        if transport.selectedSegmentIndex == 1 { attach(https, to: cell); return cell }
        if indexPath.section == 2 {
            var configuration = cell.defaultContentConfiguration()
            configuration.text = "Authorise This Device"
            configuration.secondaryText = "Your private key stays in its Keychain."
            configuration.image = UIImage(systemName: "key")
            configuration.imageProperties.tintColor = BloomTheme.accent
            cell.contentConfiguration = configuration; cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
            return cell
        }
        if indexPath.section == 3, indexPath.row == 0 {
            cell.textLabel?.text = "Advanced Connection Settings"
            cell.imageView?.image = UIImage(systemName: showsAdvanced ? "chevron.down" : "chevron.right")
            cell.imageView?.tintColor = .secondaryLabel
            cell.accessibilityValue = showsAdvanced ? "Expanded" : "Collapsed"
            cell.selectionStyle = .default
            return cell
        }
        if indexPath.section == 3, indexPath.row == 4 {
            cell.textLabel?.text = "Use Bloom’s Default Paths and Port"; cell.textLabel?.textColor = BloomTheme.accent
            cell.selectionStyle = .default
            return cell
        }
        if indexPath.section == 3, indexPath.row == 5 {
            cell.textLabel?.text = "Verify Host Key Again"; cell.textLabel?.textColor = .tintColor
            cell.selectionStyle = .default
            return cell
        }
        let fields = indexPath.section == 1 ? [host, username] : [port, executable, directory]
        let labels = indexPath.section == 1 ? ["Address", "Username"] : ["Port", "Executable", "Data directory"]
        let fieldIndex = indexPath.section == 3 ? indexPath.row - 1 : indexPath.row
        let label = UILabel(); label.text = labels[fieldIndex]; label.font = .preferredFont(forTextStyle: .caption1)
        label.textColor = .secondaryLabel; label.adjustsFontForContentSizeCategory = true
        let stack = UIStackView(arrangedSubviews: [label, fields[fieldIndex]])
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
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 3, indexPath.row == 0 {
            showsAdvanced.toggle(); tableView.reloadSections(IndexSet(integer: 3), with: .automatic)
        } else if indexPath.section == 3, indexPath.row == 4 {
            port.text = "22"; executable.text = SSHConfiguration.defaultExecutable; directory.text = SSHConfiguration.defaultDataDirectory
            tableView.reloadSections(IndexSet(integer: 3), with: .none)
        } else if indexPath.section == 3, indexPath.row == 5 {
            forgetHost()
        } else if indexPath.section == 2 {
            do {
                let key = try SSHIdentity.publicKey(SSHCredentials.identity()) + " bloom-ios"
                navigationController?.pushViewController(SSHDeviceAccessController(publicKey: key, username: username.text ?? "bloom"), animated: true)
            } catch { show(error) }
        }
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
            connecting = true; isModalInPresentation = true; tableView.isUserInteractionEnabled = false
            connectionStatus.text = "Connecting securely to your server…"; connectionStatus.isHidden = false
            navigationItem.rightBarButtonItem?.title = "Connecting…"; updateConnectButton()
            defer {
                connecting = false; isModalInPresentation = false; tableView.isUserInteractionEnabled = true
                connectionStatus.isHidden = true; navigationItem.rightBarButtonItem?.title = "Connect"; updateConnectButton()
            }
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
