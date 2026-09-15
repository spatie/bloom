import Testing
@testable import BloomCore

@Suite("Project creation context availability")
struct ProjectContextAvailabilityTests {
    @Test("Disconnected is never described as loading, including with cached project folders")
    func disconnectedOverridesCachedContext() {
        for loaded in [false, true] {
            let state = ProjectContextAvailability.resolve(isRemote: true, isConnected: false, isConnecting: false,
                                                           hasLoaded: loaded, isLoading: true, error: "Connect first")
            #expect(state == .disconnected)
            #expect(!state.allowsActions)
        }
    }

    @Test("A handshake is connecting even after its transport has opened")
    func incompleteHandshake() {
        let state = ProjectContextAvailability.resolve(isRemote: true, isConnected: true, isConnecting: true,
                                                       hasLoaded: true, isLoading: false, error: nil)
        #expect(state == .connecting)
        #expect(!state.allowsActions)
    }

    @Test("Failed and pending reads cannot enable project or GitHub actions")
    func failuresStopLoading() {
        let failed = ProjectContextAvailability.resolve(isRemote: true, isConnected: true, isConnecting: false,
                                                        hasLoaded: false, isLoading: false, error: "Folder read failed")
        let loading = ProjectContextAvailability.resolve(isRemote: true, isConnected: true, isConnecting: false,
                                                         hasLoaded: false, isLoading: true, error: nil)
        let waiting = ProjectContextAvailability.resolve(isRemote: true, isConnected: true, isConnecting: false,
                                                         hasLoaded: false, isLoading: false, error: nil)
        #expect(failed == .failed("Folder read failed"))
        #expect(loading == .loading)
        #expect(waiting == .waiting)
        #expect(!failed.allowsActions && !loading.allowsActions && !waiting.allowsActions)
    }

    @Test("A fresh context enables actions and local creation ignores remote connectivity")
    func readyContexts() {
        let remote = ProjectContextAvailability.resolve(isRemote: true, isConnected: true, isConnecting: false,
                                                        hasLoaded: true, isLoading: false, error: nil)
        let local = ProjectContextAvailability.resolve(isRemote: false, isConnected: false, isConnecting: true,
                                                       hasLoaded: true, isLoading: false, error: nil)
        #expect(remote == .ready && remote.allowsActions)
        #expect(local == .ready && local.allowsActions)
    }
}
