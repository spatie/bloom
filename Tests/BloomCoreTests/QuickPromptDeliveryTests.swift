import Testing
import Foundation
@testable import BloomCore

/// What a quick prompt does when it is chosen: the four combinations of its two switches, what a
/// surface that cannot do all four falls back to, and the sentence the form reads back.
@Suite("Quick prompt delivery")
struct QuickPromptDeliveryTests {
    private static func prompt(sends: Bool = false, newChat: Bool = false) -> QuickPrompt {
        QuickPrompt(
            name: "Ship it",
            text: "Push the branch.",
            sendsImmediately: sends,
            opensNewChat: newChat
        )
    }

    /// The one that is not negotiable. Every prompt that exists was written when insert-and-stop
    /// was the only thing a quick prompt could do, and the value with nothing said about it has to
    /// still be that.
    @Test("a prompt with nothing turned on writes into the box and stops")
    func offByDefault() {
        let plain = QuickPrompt(name: "Explain", text: "Explain the changes.")
        #expect(!plain.sendsImmediately)
        #expect(!plain.opensNewChat)
        #expect(QuickPromptDelivery(plain) == .compose)
        #expect(!QuickPromptDelivery(plain).sends)
        #expect(!QuickPromptDelivery(plain).opensNewChat)
    }

    @Test("the two switches are the four things a press can do")
    func theFour() {
        #expect(QuickPromptDelivery(Self.prompt()) == .compose)
        #expect(QuickPromptDelivery(Self.prompt(sends: true)) == .send)
        #expect(QuickPromptDelivery(Self.prompt(newChat: true)) == .composeInNewChat)
        #expect(QuickPromptDelivery(Self.prompt(sends: true, newChat: true)) == .sendInNewChat)
    }

    @Test("each case says whether it sends and whether it opens a chat")
    func readsBack() {
        for delivery in QuickPromptDelivery.allCases {
            let round = QuickPromptDelivery(
                sendsImmediately: delivery.sends, opensNewChat: delivery.opensNewChat
            )
            #expect(round == delivery)
        }
    }

    // MARK: - What a surface can do

    /// The create window: no conversation to send into, no strip to open a chat on. Every prompt
    /// writes into the box there, which is what it did before either switch existed.
    @Test("a surface that can do neither writes into the box, whatever the prompt asks")
    func composeOnlySurface() {
        for delivery in QuickPromptDelivery.allCases {
            let asked = Self.prompt(sends: delivery.sends, newChat: delivery.opensNewChat)
            let decided = QuickPromptDelivery.decided(
                for: asked, canSend: false, canOpenNewChat: false
            )
            #expect(decided == .compose)
        }
    }

    /// A composer dropped in without a workspace model: it can send, and it has no strip.
    @Test("with no strip to open a chat on, a send in place still sends")
    func sendsInPlace() {
        let decided = QuickPromptDelivery.decided(
            for: Self.prompt(sends: true), canSend: true, canOpenNewChat: false
        )
        #expect(decided == .send)
    }

    /// The one worth arguing about. A prompt that asked for a new chat AND a send does not send
    /// here instead: the switch said this conversation is not where the words belong, so the send
    /// falls away with the chat and the words wait in the box.
    @Test("a prompt that wanted a chat it cannot have waits in the box rather than sending here")
    func neverSendsSomewhereItWasNotAskedTo() {
        let both = QuickPromptDelivery.decided(
            for: Self.prompt(sends: true, newChat: true), canSend: true, canOpenNewChat: false
        )
        #expect(both == .compose)

        let quiet = QuickPromptDelivery.decided(
            for: Self.prompt(newChat: true), canSend: true, canOpenNewChat: false
        )
        #expect(quiet == .compose)
    }

    @Test("a conversation with a strip behind it does what the prompt asks")
    func fullSurface() {
        for delivery in QuickPromptDelivery.allCases {
            let asked = Self.prompt(sends: delivery.sends, newChat: delivery.opensNewChat)
            let decided = QuickPromptDelivery.decided(
                for: asked, canSend: true, canOpenNewChat: true
            )
            #expect(decided == delivery)
        }
    }

    // MARK: - What the form says

    /// The line under the two switches is the whole of how clear this is, so it is pinned: every
    /// combination that changes something says a different thing, and the one that changes nothing
    /// says nothing at all.
    @Test("every combination that does something has its own sentence")
    func sentences() {
        let said = QuickPromptDelivery.allCases.compactMap(\.sentence)
        #expect(said.count == QuickPromptDelivery.allCases.count - 1)
        #expect(Set(said).count == said.count)
        #expect(said.allSatisfy { !$0.isEmpty })
    }

    /// The state the form opens in, and the one every prompt had before these switches existed.
    /// Its sentence read "The words go in the composer here, and nothing is sent until you send
    /// it", and the owner could not tell what it meant.
    @Test("both switches off explains nothing, because nothing unusual happens")
    func quietCombinationSaysNothing() {
        #expect(QuickPromptDelivery.compose.sentence == nil)
    }

    /// Sending in place sends the rest of the draft with the prompt, which is the one thing about
    /// these switches somebody could be surprised by afterwards. The sentence has to say so.
    @Test("the sentence for sending in place names what is already in the box")
    func namesTheDraft() {
        #expect(QuickPromptDelivery.send.sentence?.contains("already typed") == true)
    }

    @Test("both of the new chat sentences say a chat opens, and only one of them sends")
    func namesTheChat() {
        #expect(QuickPromptDelivery.composeInNewChat.sentence?.contains("new chat") == true)
        #expect(QuickPromptDelivery.sendInNewChat.sentence?.contains("new chat") == true)
        #expect(QuickPromptDelivery.composeInNewChat.sentence?.contains("Nothing is sent") == true)
    }

    // MARK: - What the chat is called

    /// A chat opened for a prompt takes the name the owner gave the prompt, and nothing else.
    /// `PaneNaming` is why: a tab is furniture, and the alternative here is the first stretch of
    /// somebody's sentence in the tab bar.
    @Test("a named prompt names the chat it opens, and an unnamed one leaves it to the strip")
    func chatTitle() {
        #expect(Self.prompt().chatTitle == "Ship it")
        #expect(QuickPrompt(name: "", text: "Walk me through the diff.").chatTitle == nil)
        #expect(QuickPrompt(name: "   ", text: "Walk me through the diff.").chatTitle == nil)
        #expect(QuickPrompt(name: "  Ship it  ", text: "Push.").chatTitle == "Ship it")
    }
}
