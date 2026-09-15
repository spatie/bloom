import SwiftUI

/// Where the all-files review's sections, headers and diff blocks sit, for the review probe.
///
/// The navigation probe has landed on an empty viewport, not clamped and inside the target
/// file's estimated range, with no code drawn at all. Two explanations fit that: the lazy stack
/// left the stretch unrealised, or the file's section was realised and its `ReviewDiffBlock`s kept
/// their near-viewport flag off because nothing recomputed it after a programmatic scroll. Only the
/// code text views are AppKit views the probe can find, so the SwiftUI side has to say where the
/// rest of it is. Release builds compile every call here away.
extension View {
    @ViewBuilder
    func reviewProbeGeometry(_ name: String?, nearViewport: Bool? = nil) -> some View {
        #if DEBUG
        if let name, ReviewRunProbe.isRecording {
            modifier(ReviewProbeGeometry(name: name, nearViewport: nearViewport))
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// Names the review's stack, so a recorded frame is in document coordinates.
    @ViewBuilder
    func reviewProbeDocument() -> some View {
        #if DEBUG
        if ReviewRunProbe.isRecording {
            coordinateSpace(.named(ReviewProbeGeometry.document))
        } else {
            self
        }
        #else
        self
        #endif
    }
}

#if DEBUG
struct ReviewProbeGeometry: ViewModifier {
    /// Read from the geometry transform, which is a Sendable closure, so it cannot be actor isolated.
    nonisolated static let document = "review-probe-document"

    struct Record {
        var documentFrame: CGRect?
        /// The frame the view last reported relative to the visible region. It is refreshed by the
        /// same kind of geometry callback that drives the block's flag, so when it disagrees with
        /// the document frame at the current offset, that callback did not run after the scroll.
        var scrollFrame: CGRect?
        var appeared = false
        var nearViewport: Bool?
    }

    let name: String
    let nearViewport: Bool?

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named(Self.document))
            } action: { frame in
                ReviewRunProbe.sections[name, default: Record()].documentFrame = frame
            }
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .scrollView(axis: .vertical))
            } action: { frame in
                ReviewRunProbe.sections[name, default: Record()].scrollFrame = frame
            }
            .onAppear { ReviewRunProbe.sections[name, default: Record()].appeared = true }
            .onDisappear { ReviewRunProbe.sections[name, default: Record()].appeared = false }
            .onChange(of: nearViewport, initial: true) { _, near in
                ReviewRunProbe.sections[name, default: Record()].nearViewport = near
            }
    }
}
#endif
