import SwiftUI

/// A native illustration shared by Apple clients. Motion follows presentation or real activity;
/// it never suggests that a connection has succeeded before the caller reports completion.
public struct BloomServerIllustration: View {
    public enum Presentation: Int, Sendable { case introduction, working, complete }
    private let state: Presentation
    private let accent: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var appeared = false

    public init(state: Presentation = .introduction, accent: Color = .accentColor) {
        self.state = state
        self.accent = accent
    }

    public var body: some View {
        HStack(spacing: 24) {
            VStack(spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .bottom, spacing: 6) {
                        Image(systemName: "laptopcomputer").font(.system(size: 54, weight: .ultraLight))
                        Image(systemName: "ipad.landscape").font(.system(size: 31, weight: .light))
                        Image(systemName: "iphone").font(.system(size: 26, weight: .light))
                    }
                    Image(systemName: "laptopcomputer.and.iphone").font(.system(size: 48, weight: .light))
                }
                .frame(height: 62)
                Text("Your devices").font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
            }
            ZStack {
                GeometryReader { geometry in
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: geometry.size.height / 2))
                        path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height / 2))
                    }
                    .trim(from: 0, to: appeared || reduceMotion ? 1 : 0)
                    .stroke(accent.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, dash: [3, 5]))
                }
                Image(systemName: state == .complete ? "checkmark.shield.fill" : state == .working ? "arrow.up.arrow.down.circle.fill" : "lock.shield.fill")
                    .font(.system(size: 23, weight: .medium))
                    .foregroundStyle(accent)
                    .padding(8)
                    .background(.background, in: Circle())
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.pulse, isActive: state == .working && !reduceMotion && scenePhase == .active)
                    .symbolEffect(.bounce, value: state == .complete && appeared)
            }
            .frame(maxWidth: 130).frame(height: 50)
            .padding(.bottom, 20)
            VStack(spacing: 8) {
                Image(systemName: "server.rack")
                    .font(.system(size: 45, weight: .light))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(accent)
                    .frame(width: 76, height: 62)
                    .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(accent.opacity(0.18)))
                Text("Your server").font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
            }
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity)
        .frame(height: 128)
        .opacity(appeared || reduceMotion ? 1 : 0)
        .offset(y: appeared || reduceMotion ? 0 : 5)
        .animation(reduceMotion ? nil : .smooth(duration: 0.4), value: appeared)
        .onAppear { appeared = true }
        .symbolEffectsRemoved(reduceMotion)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}
