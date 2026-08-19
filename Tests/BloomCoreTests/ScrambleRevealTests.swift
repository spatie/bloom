import Testing
import Foundation
@testable import BloomCore

@Suite("Scramble reveal")
struct ScrambleRevealTests {
    private let name = "Fix the invoices N+1 query"

    @Test("every frame is exactly as long as the finished name")
    func frameLength() {
        // The whole reason the row does not jitter. A frame one character short would resize the
        // text and shove everything after it along, on every tick.
        for step in -2...(ScrambleReveal.steps + 2) {
            let frame = ScrambleReveal.frame(target: name, step: step, seed: 7)
            #expect(frame.count == name.count, "step \(step) produced \(frame.count) characters")
        }
    }

    @Test("whitespace and punctuation never move")
    func punctuationHolds() {
        let target = Array(name)
        for step in 0...ScrambleReveal.steps {
            let frame = Array(ScrambleReveal.frame(target: name, step: step, seed: 3))
            for index in target.indices {
                let original = target[index]
                guard !original.isLetter, !original.isNumber else { continue }
                #expect(frame[index] == original, "step \(step) moved \(original) at \(index)")
            }
        }
    }

    @Test("the name resolves from the left, and the last frame is the name itself")
    func resolvesLeftToRight() {
        var previouslyResolved = 0
        for step in 0...ScrambleReveal.steps {
            let frame = ScrambleReveal.frame(target: name, step: step, seed: 11)
            let resolved = ScrambleReveal.resolvedCount(of: name.count, step: step)
            #expect(resolved >= previouslyResolved)
            previouslyResolved = resolved
            #expect(frame.hasPrefix(name.prefix(resolved)))
        }
        #expect(ScrambleReveal.frame(target: name, step: ScrambleReveal.steps, seed: 11) == name)
    }

    @Test("the first frame gives nothing away")
    func firstFrameIsUnreadable() {
        let frame = Array(ScrambleReveal.frame(target: name, step: 0, seed: 5))
        for (index, character) in Array(name).enumerated() where character.isLetter || character.isNumber {
            #expect(frame[index] != character, "\(character) at \(index) survived the scramble")
        }
    }

    @Test("case and digits keep their class, so the shape of the name survives")
    func keepsCharacterClass() {
        let target = "Fix Invoice 42"
        let frame = Array(ScrambleReveal.frame(target: target, step: 0, seed: 9))
        for (index, character) in Array(target).enumerated() {
            if character.isNumber {
                #expect(frame[index].isNumber)
            } else if character.isUppercase {
                #expect(frame[index].isUppercase)
            } else if character.isLowercase {
                #expect(frame[index].isLowercase)
            }
        }
    }

    @Test("the scramble alphabet leaves out the letters that would make the row breathe")
    func alphabetIsWidthStable() {
        // `i`, `l`, `j`, `f`, `t` and `r` are the narrow ones; `m` and `w` the wide ones. A
        // scramble drawn from those visibly changes width inside its own box.
        for letter in "iljftmw" {
            #expect(!ScrambleReveal.lowercase.contains(letter))
        }
        #expect(ScrambleReveal.lowercase.count == ScrambleReveal.uppercase.count)
    }

    @Test("the same seed and step give the same frame, so two views agree")
    func deterministic() {
        let first = ScrambleReveal.frame(target: name, step: 4, seed: 12_345)
        let second = ScrambleReveal.frame(target: name, step: 4, seed: 12_345)
        #expect(first == second)
        #expect(ScrambleReveal.frame(target: name, step: 4, seed: 999) != first)
    }

    @Test("an empty name is not something to animate")
    func empty() {
        #expect(ScrambleReveal.frame(target: "", step: 0, seed: 1) == "")
    }

    @Test("the whole reveal is under three quarters of a second")
    func isQuick() {
        // An ornament on a sidebar row. If this ever grows past a beat, it has become something
        // the user waits for.
        let total = ScrambleReveal.interval * ScrambleReveal.steps
        #expect(total < .milliseconds(750))
    }
}
