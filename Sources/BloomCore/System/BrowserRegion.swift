import Foundation

/// A selection uses top-left, unit coordinates so resizing the pane never changes the crop.
/// Pixel rounding happens only at export, retaining the retina detail in the original snapshot.
public enum BrowserRegion {
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
