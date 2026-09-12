import Testing
@testable import BloomCore

@Suite struct ProviderIdlePolicyTests {
    @Test func evictionIsExplicitlyEnabledAndInvalidValuesAreDisabled() {
        for value in [nil, "0", "-1", "nonsense", "9999999"] {
            #expect(ProviderIdlePolicy.duration(stored: value) == nil)
        }
        #expect(ProviderIdlePolicy.duration(stored: "30") == .seconds(1_800))
    }
}
