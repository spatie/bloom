import AppKit
import SwiftUI
import BloomCore

/// The first thing Bloom ever says, and the only screen in the app with nothing to do on it.
///
/// It exists because the window used to open straight onto four probes, which meant a new Bloom
/// introduced itself by listing what your Mac might be missing. That is a form, and the app it
/// belongs to feels like a utility rather than like something anybody made. So the plinth, which
/// on the next screen is a band at the top, is the whole window here: the mark, the name, one line
/// saying what Bloom does, and a sounding going out across the water. One press and it is gone.
///
/// The cost of it is one press for somebody who has already read it, and that is paid for in
/// `OnboardingFlow.firstStep`: this screen is where a FIRST run opens, and the Help menu and a
/// later broken launch both open on the checks instead. Somebody who has been here before is not
/// greeted twice, and can still walk back to it.
///
/// Nothing here waits for anything. The probes are started when the window opens, so they run
/// underneath this screen and the checks are usually already answered by the time anybody presses
/// on. See `SetupInspection.presentChecks`, which is what holds the settling back so the second
/// screen still has its moment rather than opening onto a finished list.
struct WelcomeGreeting: View {
    /// False when somebody has walked back to this screen from the checks. A return is not an
    /// arrival, and replaying the whole opening on one is how a nice moment becomes a wait.
    let isFirstVisit: Bool
    let onContinue: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var entered = false

    private static let markSize: CGFloat = 104
    /// Tall enough that the sounding has somewhere to go. A ring that reached the edge of the
    /// plinth in its first second would read as a border being drawn rather than as water. It is
    /// the height BELOW the title bar; the gradient behind it runs up past that, so the window is
    /// this plus the title bar's inset and the plinth fills all of it.
    private static let height: CGFloat = 424

    /// The gradient and the water are the BACKGROUND, and only the background ignores the safe
    /// area, which is the arrangement the checks step has always had.
    ///
    /// It used to be one ZStack, gradient and all, with `.frame(height: 424)` and then
    /// `.ignoresSafeArea(edges: .top)` over the whole thing. Ignoring the safe area moved the
    /// drawing up under the title bar without taking the title bar's inset back out of the fitting
    /// size, so the hosting view asked for 456 points and the plinth painted 424 of them from the
    /// top down. What was left was 27 points of flat `Palette.surface` along the bottom edge with
    /// a hard horizontal line above it, on the first screen the app ever draws. A background is
    /// not asked how big it is, so it bleeds upwards and fills downwards and there is no strip.
    var body: some View {
        ZStack {
            sounding
            content
        }
        .frame(height: Self.height)
        .clipped()
        .background {
            ZStack {
                Brand.depth
                BrandWater()
            }
            .clipped()
            .ignoresSafeArea(edges: .top)
        }
        .onAppear {
            guard !entered else { return }
            if reduceMotion || !isFirstVisit {
                entered = true
            } else {
                // Set on the next runloop pass rather than inside `onAppear` itself, because a
                // state change made while the view is being installed is applied without the
                // animation and the whole entrance was skipped.
                DispatchQueue.main.async { entered = true }
            }
        }
    }

    /// The rings, centred on the mark rather than on the window. They go out from the thing that
    /// is doing the sounding, which is the only placement that means anything.
    private var sounding: some View {
        BrandSounding(reach: 260)
            .frame(width: 560, height: 560)
            .offset(y: -Self.height / 2 + 150)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var content: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: Self.markSize, height: Self.markSize)
                .shadow(color: .black.opacity(0.55), radius: 18, y: 10)
                .accessibilityHidden(true)
                .opacity(entered ? 1 : 0)
                .scaleEffect(entered ? 1 : 0.88)
                .animation(step(0), value: entered)

            Text(verbatim: "Welcome to Bloom")
                .font(.system(size: 38, weight: .light, design: .serif))
                .tracking(-0.9)
                .foregroundStyle(Brand.foam)
                .padding(.top, Metrics.pane + Metrics.spacingWide)
                .modifier(Rise(entered: entered, animation: step(0.16)))

            Text("A worktree, an agent and a branch for every task you describe")
                .font(Typo.codeTiny)
                .foregroundStyle(Brand.mistDim)
                .multilineTextAlignment(.center)
                .padding(.top, Metrics.inset + Metrics.spacingSmall)
                .padding(.horizontal, Metrics.pane)
                .modifier(Rise(entered: entered, animation: step(0.28)))

            Button("Check my Mac", action: onContinue)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                // Bloom's own fill rather than whatever the user picked in Appearance, for the
                // reason the checks screen's primary button carries: a system blue button under a
                // teal wordmark is the one place this window could look like somebody else's.
                .tint(Palette.accentFill)
                .controlSize(.large)
                .padding(.top, Metrics.pane + Metrics.inset)
                .modifier(Rise(entered: entered, animation: step(0.40)))
        }
        .padding(.top, Metrics.pane + Metrics.inset)
        .frame(maxWidth: .infinity)
    }

    /// One element of the entrance, and its place in the queue.
    ///
    /// The whole sequence is under nine tenths of a second from the mark to the button, and every
    /// element is faded and lifted eight points rather than slid, scaled or sprung. It is an app
    /// opening its door, and a door that bounced would be a splash screen. Reduce Motion is not
    /// given a slower version of it: `entered` is already true on the first frame, so there is
    /// nothing to play at all.
    private func step(_ delay: Double) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.45).delay(delay)
    }
}

/// Faded and lifted into place. Its own modifier because four elements do the same thing at four
/// different moments, and four copies of two lines is four places for one of them to drift.
private struct Rise: ViewModifier {
    let entered: Bool
    let animation: Animation?

    func body(content: Content) -> some View {
        content
            .opacity(entered ? 1 : 0)
            .offset(y: entered ? 0 : 8)
            .animation(animation, value: entered)
    }
}
