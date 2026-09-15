import SwiftUI
import BloomCore

/// What installation adds, as a list to scan before choosing Install. The rows say what each part
/// is for in a line; every path and the finer print are in the help popover beside the heading,
/// because with paths and a footnote in the list the optional extras fell below the window.
struct ServerSetupInstallPlan: View {
    var installationRoot: String?
    var serviceHome: String?
    var dataDirectory: String?
    var serviceUser: String?
    var alreadyInstalled = false

    private var summary: ServerInstallationSummary {
        ServerInstallationSummary(serviceUser: serviceUser, serviceHome: serviceHome,
                                  installationRoot: installationRoot, dataDirectory: dataDirectory)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gutter) {
            HStack(spacing: Metrics.spacing) {
                Text(alreadyInstalled ? "Your installation" : "What Bloom installs").font(Typo.bodyEmphasis)
                ServerSetupHelpButton(title: "Where everything is", details: summary.locationDetails)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: Metrics.gutter * 1.5, alignment: .topLeading),
                                GridItem(.flexible(), alignment: .topLeading)],
                      alignment: .leading, spacing: Metrics.gutter) {
                ForEach(summary.rows) { row in ServerSummaryRow(row: row, showsLocation: false) }
            }
        }
    }
}
