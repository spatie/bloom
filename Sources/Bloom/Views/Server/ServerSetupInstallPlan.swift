import SwiftUI
import BloomCore

/// What installation adds and where, as a list to scan before choosing Install. Paths used to
/// live only in help popovers; the everyday ones are in the rows now and the full set is one click away.
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
                Text(alreadyInstalled ? "Your installation" : "What Bloom installs").font(Typo.labelEmphasis)
                ServerSetupHelpButton(title: "Where everything is", details: summary.locationDetails)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: Metrics.gutter * 1.5, alignment: .topLeading),
                                GridItem(.flexible(), alignment: .topLeading)],
                      alignment: .leading, spacing: Metrics.gutter) {
                ForEach(summary.rows) { row in ServerSummaryRow(row: row) }
            }
            Text("This Mac’s private key never leaves this Mac. Existing projects, conversations and sign-ins are kept.")
                .font(Typo.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
