import Foundation

/// At most four recent workspace/language pairs, each with its own short idle timeout.
public actor SourceLanguageServers {
    public static let shared = SourceLanguageServers()
    private struct Key: Hashable { var root: String; var language: Language }
    private struct Entry { var server: SourceLanguageServer; var used: Date }
    private var entries: [Key: Entry] = [:]

    public func server(root: String, language: Language) async -> SourceLanguageServer {
        let key = Key(root: root, language: language)
        if let entry = entries[key], await !entry.server.isStopped {
            entries[key]?.used = .now
            return entry.server
        }
        if entries.count >= 4, let oldest = entries.min(by: { $0.value.used < $1.value.used })?.key,
           let old = entries.removeValue(forKey: oldest) {
            await old.server.close()
        }
        let server = SourceLanguageServer()
        entries[key] = Entry(server: server, used: .now)
        return server
    }
}
