import BloomCore

/// Switching a saved connection uses the same teardown and generation checks as reconnecting.
extension ServerWindowModel {
    var connectionProfile: ServerConnectionProfile? {
        ServerConnectionProfile(values: [
            "usesHTTPS": usesHTTPS ? "true" : "false", "httpsAddress": httpsAddress,
            "host": host, "executable": executable, "directory": remoteDirectory,
            "identityFile": identityFile, "knownHostsFile": knownHostsFile,
        ], label: customLabel)
    }

    func rememberConnection() {
        if let profile = connectionProfile { savedServers.remember(profile) }
    }

    func selectServer(_ profile: ServerConnectionProfile) async {
        guard !isConnecting, !isSigningIn, !isPerformingCommand else { return }
        useConnectionProfile(profile)
        await connect()
    }

    func useConnectionProfile(_ profile: ServerConnectionProfile) {
        rememberConnection()
        let changed = connectionProfile?.id != profile.id
        usesHTTPS = profile.usesHTTPS
        httpsAddress = profile.httpsAddress
        host = profile.host
        executable = profile.executable
        remoteDirectory = profile.directory
        identityFile = profile.identityFile
        knownHostsFile = profile.knownHostsFile
        if changed { remoteRepositoryPath = ""; serverName = "" }
        renameServer(profile.label)
        connectionMode = .remote
    }
}
