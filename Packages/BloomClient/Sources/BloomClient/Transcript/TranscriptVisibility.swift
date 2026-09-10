import Foundation

/// Desktop transcript visibility, shared without decoding every stored event during layout.
public enum TranscriptVisibility {
    private static let probeLength = 256
    private static let hookMarker = Data("\"hook_".utf8)
    private static let initMarker = Data("\"subtype\":\"init".utf8)

    public static func hidesNoise(kind: String, payload: Data) -> Bool {
        if kind == "notice" { return true }
        guard kind == "system" else { return false }
        return payload.prefix(probeLength).range(of: hookMarker) != nil
    }

    /// Matches the desktop's inexpensive system-row height/visibility decision.
    public static func systemDrawsNothing(kind: String, payload: Data) -> Bool {
        guard kind == "system" else { return false }
        return payload.prefix(probeLength).range(of: initMarker) == nil
    }

    public static func isVisible(kind: String, payload: Data) -> Bool {
        !hidesNoise(kind: kind, payload: payload) && !systemDrawsNothing(kind: kind, payload: payload)
    }
}

/// A result settles the most recent call with its reference, exactly as desktop absorption does.
public enum TranscriptToolPairing {
    public static func resultIndex(kind: String, refID: String?, indexByRefID: [String: Int]) -> Int? {
        guard kind == "toolResult", let refID else { return nil }
        return indexByRefID[refID]
    }

    public static func recordCall(kind: String, refID: String?, rowIndex: Int, indexByRefID: inout [String: Int]) {
        guard kind == "toolUse", let refID else { return }
        indexByRefID[refID] = rowIndex
    }
}
