import Foundation

/// The same admission checks apply before Mac upload and again on the server. Archives are not
/// accepted, so a client cannot smuggle links or extraction metadata through a file payload.
public enum ServerSkillBundlePolicy {
    public static let maximumBytes = 4_194_304
    public static let maximumFiles = 512
    public static let maximumFileBytes = 1_048_576
    public static let maximumInstructionsBytes = 65_536

    public static func validName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 64 && name != "synced" && name.first != "-" && name.last != "-"
            && name.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
    }

    public static func validate(path: String) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.utf8.count <= 512, parts.count >= 2, !path.contains("\\"), !path.contains("\0"),
              parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") && $0 != ".." && $0.utf8.count <= 180 }),
              let first = parts.first, validName(String(first)),
              !parts.contains(where: { ["credentials.json", "auth.json", "id_rsa", "id_ed25519"].contains($0.lowercased()) }),
              !parts.contains(where: { $0.lowercased().hasSuffix(".pem") || $0.lowercased().hasSuffix(".key") }) else {
            throw Failure("Skill bundles cannot contain hidden files, credentials, unsafe paths or reserved names.")
        }
    }

    public static func validate(_ files: [ServerSkillFile]) throws {
        guard !files.isEmpty, files.count <= maximumFiles else { throw Failure("Choose between 1 and 512 skill files.") }
        var total = 0
        var paths: Set<String> = []
        for file in files {
            try validate(path: file.path)
            guard paths.insert(file.path.lowercased()).inserted else { throw Failure("The bundle contains duplicate file paths.") }
            guard file.data.count <= maximumFileBytes else { throw Failure("Each skill file must be at most 1 MB.") }
            total += file.data.count
            guard total <= maximumBytes else { throw Failure("A skill bundle must be at most 4 MB.") }
            if file.path.hasSuffix("/SKILL.md") {
                guard file.data.count <= maximumInstructionsBytes, !file.data.contains(0),
                      String(data: file.data, encoding: .utf8) != nil else {
                    throw Failure("SKILL.md must be UTF-8 text up to 64 KB.")
                }
            }
        }
    }

    public struct Failure: LocalizedError, Sendable {
        public var errorDescription: String? { message }
        private let message: String
        public init(_ message: String) { self.message = message }
    }
}
