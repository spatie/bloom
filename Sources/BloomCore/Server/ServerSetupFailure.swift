import Foundation

/// Setup failures contain only Bloom's own copy. SSH and installer output may contain credentials
/// or hostile remote text, so it is classified here rather than copied into an alert or a log.
public struct ServerSetupFailure: Error, LocalizedError, Sendable, Equatable {
    public enum Code: String, Codable, Sendable, CaseIterable {
        case invalidAddress, authentication, hostUnknown, hostChanged, unreachable, permission
        case unsupported, packageMissing, packageInvalid, installation, busy, cancelled, unknown
        case serverRunning, diskSpace, accountConflict, serviceFailed, backupFailed
    }

    public let code: Code
    public let title: String
    public let message: String
    public let recovery: String

    public var errorDescription: String? { message }
    public var recoverySuggestion: String? { recovery }

    public init(code: Code) {
        self.code = code
        switch code {
        case .invalidAddress:
            title = "Check the connection details"
            message = "The server address or SSH file path is not valid."
            recovery = "Use a host name, IP address or SSH alias, optionally preceded by user@. Configure custom ports in your SSH configuration and choose an absolute key file path."
        case .authentication:
            title = "SSH authentication failed"
            message = "Bloom could not sign in to the server with your SSH key."
            recovery = "Check the user name and selected key. Unlock your SSH agent or 1Password, then retry. Password-only SSH connections need a key added first."
        case .hostUnknown:
            title = "Verify this server"
            message = "This server's identity has not been trusted yet."
            recovery = "Compare its fingerprint with the server provider's fingerprint before trusting it. For a jump host or advanced SSH alias, verify and trust it with your normal SSH client first, then retry in Bloom."
        case .hostChanged:
            title = "The server identity changed"
            message = "The server presented a different SSH host key. Bloom has stopped the connection."
            recovery = "Check with your server provider or administrator. Only update the trusted key after independently verifying the new fingerprint."
        case .unreachable:
            title = "Could not reach the server"
            message = "The SSH connection could not be established or was interrupted."
            recovery = "Check the address, network connection and server firewall, then retry. If you use an SSH alias, check its host and port settings."
        case .permission:
            title = "Permission is needed"
            message = "The server account cannot complete this setup step."
            recovery = "Use an account authorised to install the required packages, or ask your administrator to prepare the server. Bloom will not change permissions automatically."
        case .unsupported:
            title = "This server is not supported"
            message = "Automatic setup is not available for this operating system or processor."
            recovery = "Choose a supported Ubuntu server, or install a compatible Bloom Server manually and use advanced connection settings."
        case .packageMissing:
            title = "Server package unavailable"
            message = "A compatible Bloom Server package could not be found."
            recovery = "Use a Bloom build that includes its matching server package, or connect to an already installed server through advanced settings."
        case .packageInvalid:
            title = "Server package could not be verified"
            message = "The server package is damaged or does not match this Bloom build."
            recovery = "Download a matching package from a trusted Bloom release and retry."
        case .installation:
            title = "Setup did not finish"
            message = "Bloom could not finish installing or starting its server component."
            recovery = "Check available disk space and the server's package manager, then retry. Your existing projects and workspaces are preserved."
        case .backupFailed:
            title = "The existing server could not be backed up"
            message = "Bloom stopped the update before replacing the server release or database."
            recovery = "Check available disk space and the service account's access to its database, then retry."
        case .busy:
            title = "The server is busy"
            message = "Bloom cannot update the server while work is running."
            recovery = "Wait for active sessions and workspace setup to finish, then retry."
        case .serverRunning:
            title = "Stop the server before updating"
            message = "Bloom Server is still running. The installer will not stop it automatically."
            recovery = "Wait until sessions and workspace setup are idle, stop Bloom Server on the server, then retry."
        case .diskSpace:
            title = "More disk space is needed"
            message = "The server does not have enough free disk space for installation."
            recovery = "Free at least 512 MB on the installation disk, then retry. Allow extra space for project dependencies and databases."
        case .accountConflict:
            title = "An existing installation needs attention"
            message = "The server account, installation files or permissions do not match a managed Bloom installation."
            recovery = "Ask your administrator to check the existing account and installation. Use separate empty directories and a dedicated account for a new installation."
        case .serviceFailed:
            title = "Bloom Server did not start"
            message = "Installation reached the service startup step, but Bloom Server did not become ready."
            recovery = "Check the Bloom Server systemd service status and journal on the server, resolve the startup error, then retry."
        case .cancelled:
            title = "Setup cancelled"
            message = "Server setup was cancelled."
            recovery = "You can retry setup when you are ready. A step already started on the server may still finish."
        case .unknown:
            title = "Setup could not continue"
            message = "An unexpected error interrupted server setup."
            recovery = "Retry the failed step. If it keeps failing, check the server connection and installation."
        }
    }

    /// Installer codes are part of the setup contract. Unknown codes deliberately do not expose
    /// accompanying remote messages, which can include paths, environment values or credentials.
    public static func installation(code: String) -> Self {
        switch code {
        case "server_running": Self(code: .serverRunning)
        case "server_busy", "installation_busy": Self(code: .busy)
        case "disk_space", "disk_full", "low_disk": Self(code: .diskSpace)
        case "package_checksum", "package_invalid", "invalid_checksum", "checksum_mismatch", "unsafe_package", "package_too_large", "invalid_package": Self(code: .packageInvalid)
        case "unsupported", "unsupported_os", "unsupported_architecture", "systemd_required": Self(code: .unsupported)
        case "account_conflict", "installation_conflict", "untrusted_installation", "untrusted_directory", "untrusted_database", "untrusted_keys": Self(code: .accountConflict)
        case "service_failed", "startup_failed": Self(code: .serviceFailed)
        case "database_backup_failed": Self(code: .backupFailed)
        case "permission", "administrator_required": Self(code: .permission)
        case "package_required": Self(code: .packageMissing)
        default: Self(code: .installation)
        }
    }

    public static func classify(status: Int32, stderr: String) -> Self {
        let output = stderr.lowercased()
        if output.contains("remote host identification has changed") || output.contains("revoked host key") || output.contains("offending") && output.contains("host key") {
            return Self(code: .hostChanged)
        }
        if output.contains("host key verification failed") || output.contains("host key is known") || output.contains("authenticity of host") {
            return Self(code: .hostUnknown)
        }
        if output.contains("unprotected private key") || output.contains("bad permissions") || output.contains("sign_and_send_pubkey") || output.contains("permission denied (") || output.contains("authentication failed") || output.contains("too many authentication failures") || output.contains("incorrect passphrase") || output.contains("load key") {
            return Self(code: .authentication)
        }
        if output.contains("could not resolve hostname") || output.contains("name or service not known") || output.contains("connection timed out") || output.contains("operation timed out") || output.contains("connection refused") || output.contains("no route to host") || output.contains("network is unreachable") || output.contains("connection reset") || output.contains("connection closed") || output.contains("broken pipe") {
            return Self(code: .unreachable)
        }
        if output.contains("sudo:") || output.contains("permission denied") || output.contains("operation not permitted") || output.contains("must be root") || output.contains("not in the sudoers") {
            return Self(code: .permission)
        }
        if output.contains("no space left on device") || output.contains("read-only file system") {
            return Self(code: output.contains("no space left on device") ? .diskSpace : .installation)
        }
        return Self(code: status == 255 ? .unreachable : .unknown)
    }
}
