import Foundation
import BloomClient

extension ServerDiagnosticsCollector {
    static func browserReadiness() -> ServerBrowserReadiness? {
        #if os(Linux)
        let path = "/opt/bloom-browser/readiness.json"
        let files = FileManager.default
        guard protectedBrowserPath(path),
              let attributes = try? files.attributesOfItem(atPath: path),
              ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 65_536,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return .unavailable }
        return .inspect(data, accountID: getuid()) { executable in
            protectedBrowserPath(executable) && files.isExecutableFile(atPath: executable)
        }
        #else
        return nil
        #endif
    }

    private static func protectedBrowserPath(_ path: String) -> Bool {
        var current = URL(fileURLWithPath: path)
        while true {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: current.path),
                  attributes[.type] as? FileAttributeType != .typeSymbolicLink,
                  (attributes[.ownerAccountID] as? NSNumber)?.intValue == 0,
                  let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue,
                  permissions & 0o022 == 0 else { return false }
            if current.path == "/" { return true }
            current.deleteLastPathComponent()
        }
    }
}
