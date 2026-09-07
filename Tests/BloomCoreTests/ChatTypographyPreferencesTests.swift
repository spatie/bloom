import Foundation
import Testing
@testable import BloomCore

@Suite("Chat defaults preserve the reader's saved typography")
struct ChatTypographyPreferencesTests {
    @Test("missing and unrecognised preferences use the new defaults without writing them",
          arguments: [nil, "unknown"] as [String?])
    func defaultsWithoutMigration(rawValue: String?) throws {
        let domain = "bloom-test-typography-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(rawValue, forKey: ChatTextSize.defaultsKey)
        defaults.set(rawValue, forKey: ChatLineHeight.defaultsKey)

        #expect(ChatTextSize.read(from: defaults) == .large)
        #expect(ChatLineHeight.read(from: defaults) == .tighter)
        #expect(ChatTextSize.read(from: defaults).scale == 1.15)
        #expect(ChatLineHeight.read(from: defaults).ratio == 1.55)
        #expect(defaults.string(forKey: ChatTextSize.defaultsKey) == rawValue)
        #expect(defaults.string(forKey: ChatLineHeight.defaultsKey) == rawValue)
    }

    @Test("every saved text size keeps its original scale")
    func savedTextSizes() throws {
        let domain = "bloom-test-typography-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let choices: [(String, CGFloat)] = [
            ("small", 0.9), ("standard", 1), ("large", 1.15),
            ("extraLarge", 1.3), ("largest", 1.5),
        ]
        for (rawValue, scale) in choices {
            defaults.set(rawValue, forKey: ChatTextSize.defaultsKey)
            let size = ChatTextSize.read(from: defaults)
            #expect(size.rawValue == rawValue)
            #expect(size.scale == scale)
        }
    }

    @Test("every saved line height keeps its original ratio")
    func savedLineHeights() throws {
        let domain = "bloom-test-typography-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let choices: [(String, Double)] = [
            ("tightest", 1.4), ("tighter", 1.55), ("standard", 1.7),
            ("looser", 1.85), ("loosest", 2),
        ]
        for (rawValue, ratio) in choices {
            defaults.set(rawValue, forKey: ChatLineHeight.defaultsKey)
            let height = ChatLineHeight.read(from: defaults)
            #expect(height.rawValue == rawValue)
            #expect(height.ratio == ratio)
        }
    }

    @Test("Settings marks exactly the fallback choice as Default")
    func pickerDefaults() {
        #expect(ChatTextSize.allCases.filter { $0.title == "Default" } == [.defaultChoice])
        #expect(ChatLineHeight.allCases.filter { $0.title == "Default" } == [.defaultChoice])
        #expect(Set(ChatTextSize.allCases.map(\.title)).count == ChatTextSize.allCases.count)
        #expect((13 * ChatTextSize.defaultChoice.scale).rounded() == 15)
    }

    @Test("zoom walks the existing steps on both sides of the new default")
    func zoomSteps() {
        #expect(ChatTextSize.defaultChoice.stepped(by: -1) == .standard)
        #expect(ChatTextSize.defaultChoice.stepped(by: 1) == .extraLarge)
        #expect(ChatTextSize.small.stepped(by: -1) == nil)
        #expect(ChatTextSize.largest.stepped(by: 1) == nil)
    }
}
