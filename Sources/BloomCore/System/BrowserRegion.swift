import Foundation

/// A selection uses top-left, unit coordinates so resizing the pane never changes the crop.
/// Pixel rounding happens only at export, retaining the retina detail in the original snapshot.
public enum BrowserRegion {
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

    public static func imageFrame(image: CGSize, canvas: CGSize) -> CGRect {
        guard image.width > 0, image.height > 0, canvas.width > 0, canvas.height > 0 else {
            return .zero
        }
        let scale = min(canvas.width / image.width, canvas.height / image.height)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(
            x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2,
            width: size.width, height: size.height
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
