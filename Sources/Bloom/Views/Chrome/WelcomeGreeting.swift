import AppKit
import SwiftUI
import BloomCore

/// The first thing Bloom ever says, and the only screen in the app with nothing to do on it.
///
/// It exists because the window used to open straight onto four probes, which meant a new Bloom
/// introduced itself by listing what your Mac might be missing. That is a form, and the app it
/// belongs to feels like a utility rather than like something anybody made. So the plinth, which
/// on the next screen is a band at the top, is the whole window here: the mark, the name, one line
/// saying what Bloom does, and the branches running through the water behind all three. One
/// press and it is gone.
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
    /// Tall enough that the branches have somewhere to run. A curve that reached the wall of the
    /// plinth in its first second would read as a border being drawn rather than as water. It is
    /// the height BELOW the title bar; the gradient behind it runs up past that, so the window is
    /// this plus the title bar's inset and the plinth fills all of it.
    private static let height: CGFloat = 424
    private static let plinth = "welcome.plinth"

    /// Where `main` runs, measured down from the top of the plinth: the middle of the mark.
    ///
    /// Measured rather than added up, and that is the whole reason there is a preference key on
    /// this screen. The first version worked it out from the constants (`pane + inset` down, plus
    /// half the mark) and put the spine 59 points too high, because the content is a `VStack` with
    /// no height of its own inside a 424 point `ZStack`, so it is CENTRED, and where the mark ends
    /// up therefore depends on the height of a serif line, a prose line and a button. Any of
    /// those three changing moves the mark and would leave a line drawn through empty water
    /// above it.
    ///
    /// The line through the mark is the point of the whole figure. Every branch on this screen
    /// leaves the thing the app is, and the mark hides the middle of the spine, so what is seen is
    /// a line going into one side of it and coming out of the other.
    @State private var spineDepth: CGFloat = 145

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
            branches
            content
        }
        .frame(height: Self.height)
        .coordinateSpace(name: Self.plinth)
        .onPreferenceChange(SpineDepth.self) { depth in
            if let depth { spineDepth = depth }
        }
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

    /// The branches, filling the plinth rather than sitting in a box inside it, because `main`
    /// runs the width of the window and a branch that stopped short of the edge would be a
    /// drawing of a branch instead of one.
    private var branches: some View {
        BrandBranching(spineDepth: spineDepth)
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
                // Reported before the entrance is applied, so the branches are drawn against
                // where the mark LANDS rather than against where it starts. `scaleEffect` does
                // not change a layout frame, so this reads the same on every frame of the rise.
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: SpineDepth.self,
                            value: proxy.frame(in: .named(Self.plinth)).midY
                        )
                    }
                }
                .opacity(entered ? 1 : 0)
                .scaleEffect(entered ? 1 : 0.88)
                .animation(step(0), value: entered)

            Text(verbatim: "Welcome to Bloom")
                .font(.system(size: 38, weight: .light, design: .serif))
                .tracking(-0.9)
                .foregroundStyle(Brand.foam)
                .padding(.top, Metrics.pane + Metrics.spacingWide)
                .modifier(Rise(entered: entered, animation: step(0.16)))

            // The only sentence on the screen that says what the app is, so it is set in the face
            // and at the size the app sets a sentence in: `Typo.body`, the same rung as the
            // verdict line on the checks screen. The two screens are one window and the sentence
            // that introduces Bloom and the sentence that reports on your Mac should not read as
            // two different kinds of text.
            //
            // It was mono, and going up a rung within mono did not fix it, because the size was
            // never the whole fault. Mono is this app's voice for what a machine said: a version,
            // a path, a command, an account. This sentence is English, and English set in mono
            // reads as data, which is the same mistake the checks column's state words used to
            // make. Between a thirty eight point serif line and a large button, at the floor of
            // the scale in a face that is wider and greyer per word than the text around it, the
            // one line explaining the product was the hardest thing in the window to read.
            Text("A worktree, an agent and a branch for every task you describe")
                .font(Typo.body)
                .foregroundStyle(Brand.mistDim)
                .multilineTextAlignment(.center)
                .padding(.top, Metrics.inset + Metrics.spacingSmall)
                .padding(.horizontal, Metrics.pane)
                .modifier(Rise(entered: entered, animation: step(0.28)))

            Button("See what Bloom needs", action: onContinue)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                // Bloom's own fill rather than whatever the user picked in Appearance, for the
                // reason the checks screen's primary button carries: a system blue button under a
                // teal wordmark is the one place this window could look like somebody else's.
                .tint(Palette.accentFill)
                .controlSize(.large)
                .padding(.top, Metrics.pane + Metrics.inset)
                .modifier(Rise(entered: entered, animation: step(0.40)))

            // What the button is about to do, said plainly, because "Check my Mac" on its own
            // could be read as anything from a hardware scan to something rummaging through the
            // disk. It names the four things by the shapes they are rather than by their four
            // names: the next screen lists Git, Claude Code, Codex and the GitHub CLI with their
            // versions, and printing that list twice would turn a greeting into the screen it is
            // introducing. There is no line here saying nothing leaves the Mac, because a screen
            // that says that has raised the question it is answering; being specific about what
            // is looked for does the same work without the flinch.
            //
            // Left where it is, below the lede in both size and weight, which is the whole of its
            // job: it is the footnote to a button, not a second lede.
            Text("Bloom looks for Git, a coding agent and the GitHub CLI")
                .font(Typo.codeTiny)
                .foregroundStyle(Brand.mistDim)
                .multilineTextAlignment(.center)
                .padding(.top, Metrics.inset + Metrics.spacingSmall)
                .padding(.horizontal, Metrics.pane)
                .modifier(Rise(entered: entered, animation: step(0.52)))
        }
        .padding(.top, Metrics.pane + Metrics.inset)
        .frame(maxWidth: .infinity)
    }

    /// One element of the entrance, and its place in the queue.
    ///
    /// The whole sequence is a little over a second from the mark to the line under the button,
    /// and every element is faded and lifted eight points rather than slid, scaled or sprung. It is an app
    /// opening its door, and a door that bounced would be a splash screen. Reduce Motion is not
    /// given a slower version of it: `entered` is already true on the first frame, so there is
    /// nothing to play at all.
    private func step(_ delay: Double) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.45).delay(delay)
    }
}

/// Where the middle of the mark ended up, so `BrandBranching` can run `main` through it.
private struct SpineDepth: PreferenceKey {
    static let defaultValue: CGFloat? = nil

    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
    }
}

/// Faded and lifted into place. Its own modifier because five elements do the same thing at five
/// different moments, and five copies of two lines is five places for one of them to drift.
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
