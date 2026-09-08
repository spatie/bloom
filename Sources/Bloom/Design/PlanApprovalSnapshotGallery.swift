import SwiftUI
import BloomCore

struct PlanApprovalSnapshotGallery: View {
    private func card(mode: PermissionMode, decision: String? = nil) -> some View {
        PermissionAskRowView(
            ask: PermissionAsk(
                requestID: "plan-\(mode.rawValue)", toolName: "ExitPlanMode",
                input: .object(["plan": .string("Create two files, then update the first.")]),
                requiresUserInteraction: true, implementationMode: mode
            ),
            decision: decision, note: "", projectName: "Bloom"
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gutter) {
            card(mode: .acceptEdits)
            card(mode: .auto)
            card(mode: .bypassPermissions)
            card(mode: .acceptEdits, decision: "approve-plan-acceptEdits")
            card(mode: .acceptEdits).frame(width: 350)
        }
        .padding(20)
        .background(Palette.windowBackground)
    }
}
