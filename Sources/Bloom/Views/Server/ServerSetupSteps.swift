import SwiftUI

/// A stable outline of the assistant, including the introduction and completion page.
struct ServerSetupSteps: View {
    enum Step: Int, CaseIterable {
        case introduction, server, installation, accounts, finish

        var title: String {
            switch self {
            case .introduction: "Introduction"
            case .server: "Server"
            case .installation: "Installation"
            case .accounts: "Accounts"
            case .finish: "Finish"
            }
        }
    }

    let current: Step

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gutter * 1.5) {
            Text("Server Setup").font(Typo.captionEmphasis).foregroundStyle(.secondary)
            ForEach(Step.allCases, id: \.rawValue) { step in
                HStack(spacing: Metrics.spacingWide) {
                    Image(systemName: step.rawValue < current.rawValue ? "checkmark.circle.fill" : "\(step.rawValue + 1).circle\(step == current ? ".fill" : "")")
                        .imageScale(.large)
                        .accessibilityHidden(true)
                    Text(step.title).font(step == current ? Typo.captionEmphasis : Typo.caption)
                }
                .foregroundStyle(step == current ? Palette.controlAccent : Palette.textSecondary)
                .accessibilityElement(children: .combine)
                .accessibilityValue(step == current ? "Current step" : step.rawValue < current.rawValue ? "Complete" : "Not started")
            }
            Spacer()
            Text("Step \(current.rawValue + 1) of \(Step.allCases.count)")
                .font(Typo.caption).foregroundStyle(.secondary)
        }
        .padding(Metrics.gutter * 1.5)
        .frame(width: 170, alignment: .leading)
        .frame(maxHeight: .infinity)
        .background(.bar)
    }
}
