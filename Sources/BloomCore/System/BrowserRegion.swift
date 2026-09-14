import Foundation

/// A selection uses top-left, unit coordinates so resizing the pane never changes the crop.
/// Pixel rounding happens only at export, retaining the retina detail in the original snapshot.
public enum BrowserRegion {
    /// The editor is drawn over the page. Prefer space beside the selection, then the smallest
    /// overlap available, without changing the viewport or placing controls beyond the pane.
    public static func commentFrame(near selection: CGRect, in bounds: CGRect, size: CGSize) -> CGRect {
        let margin: CGFloat = 8
        let width = min(size.width, max(0, bounds.width - margin * 2))
        let height = min(size.height, max(0, bounds.height - margin * 2))
        let origins = [
            CGPoint(x: selection.minX, y: selection.maxY + margin),
            CGPoint(x: selection.minX, y: selection.minY - height - margin),
            CGPoint(x: selection.maxX + margin, y: selection.minY),
            CGPoint(x: selection.minX - width - margin, y: selection.minY),
        ]
        let candidates = origins.map { origin in
            CGRect(
                x: max(bounds.minX + margin, min(origin.x, bounds.maxX - margin - width)),
                y: max(bounds.minY + margin, min(origin.y, bounds.maxY - margin - height)),
                width: width, height: height
            )
        }
        return candidates.min { first, second in
            let firstOverlap = first.intersection(selection)
            let secondOverlap = second.intersection(selection)
            return firstOverlap.width * firstOverlap.height < secondOverlap.width * secondOverlap.height
        } ?? .zero
    }

    public enum Corner: String, CaseIterable, Sendable {
        case topLeft, topRight, bottomLeft, bottomRight

        public var isLeft: Bool { self == .topLeft || self == .bottomLeft }
        public var isTop: Bool { self == .topLeft || self == .topRight }
    }

    /// Moving keeps the size intact, even when the pointer travels beyond the screenshot.
    public static func moved(_ selection: CGRect, by delta: CGSize) -> CGRect {
        CGRect(
            x: min(max(selection.minX + delta.width, 0), 1 - selection.width),
            y: min(max(selection.minY + delta.height, 0), 1 - selection.height),
            width: selection.width, height: selection.height
        )
    }

    /// A handle cannot cross its opposite corner or escape the image. Keeping that corner fixed
    /// avoids a selection flipping under the pointer while someone is making a small adjustment.
    public static func resized(_ selection: CGRect, corner: Corner, to point: CGPoint) -> CGRect {
        let minimumWidth = min(0.01, selection.width)
        let minimumHeight = min(0.01, selection.height)
        let left = corner.isLeft ? min(max(point.x, 0), selection.maxX - minimumWidth) : selection.minX
        let right = corner.isLeft ? selection.maxX : max(min(point.x, 1), selection.minX + minimumWidth)
        let top = corner.isTop ? min(max(point.y, 0), selection.maxY - minimumHeight) : selection.minY
        let bottom = corner.isTop ? selection.maxY : max(min(point.y, 1), selection.minY + minimumHeight)
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// WebKit can share its native container with an inspector. Only the content's rectangle is
    /// replaced by the snapshot, using the same top-left coordinates as the selection overlay.
    public static func pageFrame(content: CGRect, viewport: CGRect, originAtTop: Bool) -> CGRect {
        guard viewport.width > 0, viewport.height > 0 else { return .zero }
        return CGRect(
            x: (content.minX - viewport.minX) / viewport.width,
            y: (originAtTop ? content.minY - viewport.minY : viewport.maxY - content.maxY) / viewport.height,
            width: content.width / viewport.width, height: content.height / viewport.height
        )
    }

    public static func selection(from start: CGPoint, to end: CGPoint, in frame: CGRect) -> CGRect? {
        guard frame.width > 0, frame.height > 0, frame.contains(start) else { return nil }
        let clipped = CGRect(
            x: min(start.x, end.x), y: min(start.y, end.y),
            width: abs(end.x - start.x), height: abs(end.y - start.y)
        ).intersection(frame)
        // A click or a shaky drag should not become an almost invisible attachment.
        guard clipped.width >= 4, clipped.height >= 4 else { return nil }
        return CGRect(
            x: (clipped.minX - frame.minX) / frame.width,
            y: (clipped.minY - frame.minY) / frame.height,
            width: clipped.width / frame.width, height: clipped.height / frame.height
        )
    }

    public static func rect(_ selection: CGRect, in frame: CGRect) -> CGRect {
        CGRect(
            x: frame.minX + selection.minX * frame.width,
            y: frame.minY + selection.minY * frame.height,
            width: selection.width * frame.width, height: selection.height * frame.height
        )
    }

    public static func pixels(_ selection: CGRect, image: CGSize) -> CGRect? {
        guard image.width > 0, image.height > 0,
              [selection.minX, selection.minY, selection.width, selection.height].allSatisfy(\.isFinite),
              selection.width > 0, selection.height > 0 else { return nil }
        let bounds = CGRect(origin: .zero, size: image)
        let crop = rect(selection, in: bounds).integral.intersection(bounds)
        return crop.isNull || crop.isEmpty ? nil : crop
    }

    public static func draft(comment: String, address: String, paths: [String]) -> String {
        let attachments = paths.map(AttachmentDraft.token(for:)).joined(separator: " ")
        return "\(comment.trimmingCharacters(in: .whitespacesAndNewlines))\nPage: \(address)\n\(attachments)"
    }
}
