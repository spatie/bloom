import SwiftUI
import BloomCore

/// The four crew rows on one page, so what a second agent's words look like in somebody else's
/// chat can be looked at rather than argued about.
///
/// It exists because none of this is testable. `CrewMessageRowView` is a view, and the decisions
/// it takes are which colour the rule is, which face the name is in and what is behind the
/// disclosure: three things a test can only assert by drawing them. The presentations that go with
/// this work are in `ToolPresenter` and are covered in the core, which is where the line is.
///
/// The payloads are built through `CrewMessage`'s own four constructors rather than by hand, so
/// the page shows the real envelope `BridgeUntrustedText` puts round a subagent's words rather
/// than a plausible looking one. That is the whole point of the disclosure being here.
struct CrewMessageGallery: View {
    var body: some View {
        // No `ScrollView`: offscreen it has no proposed height to lay out against and the page
        // renders blank. `RetrySnapshotGallery` learnt that first.
        VStack(alignment: .leading, spacing: 20) {
            group("A subagent talking back. The rule says an agent spoke; the header says which one.") {
                CrewMessageRowView(message: .said(
                    from: "read-the-cascade",
                    text: "The parser moved. It is `Sources/BloomCore/Git/DiffParser.swift` now, "
                        + "and the two callers under `Views/Inspector` follow it.",
                    sender: .subagent
                ))
            }

            group("The agent above talking down. The same rule, because direction is in the words.") {
                CrewMessageRowView(message: .said(
                    from: "orchestrator",
                    text: "Leave the inspector alone, I am editing it. Take the tests instead.",
                    sender: .orchestrator
                ))
            }

            group("The first row of a subagent's own chat: what it was started with.") {
                CrewMessageRowView(message: .brief(
                    from: "orchestrator",
                    task: "Read every file under `Sources/BloomCore/Git` and report what reads a "
                        + "diff. Do not edit anything: the write half is mine."
                ))
            }

            group("Bloom reporting a fact. No rule, because no agent said this.") {
                CrewMessageRowView(message: .stopped(
                    name: "read-the-cascade",
                    lastMessage: "Done. Eleven files read, three of them parse a diff."
                ))
            }

            group("And one that did not finish, which keeps its reason.") {
                CrewMessageRowView(message: .failed(
                    name: "tests", reason: "The CLI exited before its first turn."
                ))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.windowBackground)
    }

    @ViewBuilder
    private func group(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
            content()
        }
    }
}

extension Gallery {
    /// The registry entry for this page. See `Gallery`.
    static let crewMessages = Gallery(
        name: "crew-messages",
        title: "Subagent messages",
        size: CGSize(width: 860, height: 1_020),
        needsFocus: false,
        view: { _ in AnyView(CrewMessageGallery()) }
    )
}
