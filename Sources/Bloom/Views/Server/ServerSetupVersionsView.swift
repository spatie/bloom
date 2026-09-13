import SwiftUI
import BloomClient

struct ServerSetupVersionsView: View {
    let comparison: ServerSetupVersionComparison

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            LabeledContent("Installed on server", value: comparison.installedLabel)
            LabeledContent("Included with this app", value: comparison.includedLabel)
            Text(explanation).settingsFootnote().fixedSize(horizontal: false, vertical: true)
        }
        .font(Typo.caption)
        .textSelection(.enabled)
    }

    private var explanation: String {
        if comparison.needsMaintenanceSetup {
            return "This server still needs the maintenance service. Set it up once to check published updates here."
        }
        switch comparison.state {
        case .sameBuild, .sameVersion: return "Up to date with this app. No package installation is needed."
        case .installedNewer: return "The installed version is newer than this app’s package. No update is needed."
        case .updateAvailable: return "This app includes a newer server version."
        case .differentDevelopmentBuild: return "These are development builds. Different build numbers do not indicate which is newer."
        case .unknown: return "Check the server to compare versions. Published releases can be checked after managed updates are enabled."
        case .packageUnavailable: return "This app does not include a server package."
        }
    }
}
