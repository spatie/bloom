import Testing
@testable import BloomCore

/// One JSON-RPC frame off the bridge socket, and the one question asked of every frame before
/// anything else: does this expect an answer at all.
///
/// That rule was written twice. `MCPRequest.isNotification` said what a notification is, and
/// `BridgeDispatch` re-derived it from the id because it needed the id unwrapped, so a frame shape
/// added to one spelling would have been missed by the other. `replyID` is the question and the
/// answer in one reading, and these hold the two together.
@Suite("MCP message")
struct MCPMessageTests {
    @Test("a frame with no usable id is answered with silence")
    func aNotificationHasNoReplyID() {
        #expect(MCPRequest(id: nil, method: "notifications/initialized").replyID == nil)
        #expect(MCPRequest(id: .null, method: "notifications/initialized").replyID == nil)
    }

    /// The id is handed back rather than parsed, so both spellings the two CLIs use survive.
    @Test("an id that expects an answer comes back as it arrived")
    func anIdComesBackWhole() {
        #expect(MCPRequest(id: .integer(4), method: "ping").replyID == .integer(4))
        #expect(MCPRequest(id: .string("a"), method: "ping").replyID == .string("a"))
    }

    @Test("the two readings of a notification cannot disagree")
    func theTwoReadingsAgree() {
        for request in [
            MCPRequest(id: nil, method: "ping"),
            MCPRequest(id: .null, method: "ping"),
            MCPRequest(id: .integer(1), method: "ping"),
            MCPRequest(id: .string(""), method: "ping"),
        ] {
            #expect(request.isNotification == (request.replyID == nil))
        }
    }

    /// Decoding is what puts the id there in the first place, so the property is asked of a real
    /// line as well as of a value built in a test.
    @Test("a decoded notification is one too")
    func aDecodedNotification() {
        let notification = MCPRequest.decode(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        #expect(notification?.replyID == nil)

        let call = MCPRequest.decode(#"{"jsonrpc":"2.0","id":7,"method":"tools/list"}"#)
        #expect(call?.replyID == .integer(7))
    }
}
