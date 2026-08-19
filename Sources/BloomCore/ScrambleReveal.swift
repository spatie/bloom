import Foundation

/// The frames of the reveal that plays when Bloom renames a workspace for you.
///
/// Pure, and deterministic given a seed, so the thing the eye is asked to read can be asserted on
/// rather than watched. A view only has to walk `step` from 0 to `steps` on a timer and hand each
/// frame to a `Text`.
///
/// The invariant that matters is that every frame has exactly as many characters as the final
/// name, and that whitespace never moves. A frame with a different length would resize the row it
/// sits in on every tick, which is what makes this kind of effect read as a slot machine instead
/// of as a name resolving.
public enum ScrambleReveal {
    /// How many ticks the reveal takes, and how long each one lasts.
    ///
    /// Sixteen at 30ms is a little under half a second. This is an ornament on a sidebar row that
    /// fires once in the life of a workspace, so it has to be over before it becomes something the
    /// user is waiting for. It is also above the ~24fps floor where the scramble stops reading as
    /// motion and starts reading as three separate strings.
    public static let steps = 16
    public static let interval = Duration.milliseconds(30)

    /// The characters an unresolved position is drawn with.
    ///
    /// Deliberately not the whole alphabet. `i`, `l`, `j`, `f`, `t` and `r` are far narrower than
    /// the mean in every proportional face, and `m` and `w` far wider, so a scramble that used
    /// them would visibly breathe as the letters churn even though the string length never
    /// changes. What is left is the band of letters within a few percent of each other's advance
    /// width, which is what keeps the churn confined to the glyphs themselves.
    static let lowercase = Array("abcdeghknopqsuvxyz")
    static let uppercase = Array("ABCDEGHKNOPQSUVXYZ")
    static let digits = Array("0123456789")

    /// One frame of the reveal.
    ///
    /// - Parameter step: 0 is fully scrambled, `steps` and above is the finished name.
    /// - Parameter seed: fixes the churn. Pass the same seed for every step of one reveal, so the
    ///   unresolved tail changes from tick to tick but not from view to view: the sidebar row and
    ///   the Home row showing the same workspace draw the same thing.
    public static func frame(target: String, step: Int, seed: UInt64) -> String {
        guard step < steps else { return target }
        let characters = Array(target)
        guard !characters.isEmpty else { return target }

        // Clamped rather than trusted. A caller that starts at -1 to hold the scramble for one
        // extra tick is asking for a reasonable thing, and the churn is indexed by step, which
        // has to be a number that can be hashed.
        let tick = max(0, step)
        let resolved = resolvedCount(of: characters.count, step: tick)

        var output = String()
        output.reserveCapacity(target.count)
        for (index, character) in characters.enumerated() {
            if index < resolved || character.isWhitespace {
                output.append(character)
            } else {
                output.append(scramble(character, index: index, step: tick, seed: seed))
            }
        }
        return output
    }

    /// How many leading characters have settled by this step.
    ///
    /// Rounded up rather than down, so a name shorter than the step count still moves on every
    /// tick instead of standing still for three frames and then jumping.
    static func resolvedCount(of length: Int, step: Int) -> Int {
        guard step > 0 else { return 0 }
        guard step < steps else { return length }
        let scaled = (length * step + steps - 1) / steps
        return min(length, scaled)
    }

    /// A stand-in for one character, from the same class so the shape of the name survives.
    ///
    /// Never the character it is standing in for. Without that a fully scrambled frame of a short
    /// name can come back partly readable, and the first frame is the one that has to say "this is
    /// not the name yet".
    static func scramble(_ character: Character, index: Int, step: Int, seed: UInt64) -> Character {
        let alphabet: [Character]
        if character.isNumber {
            alphabet = digits
        } else if character.isUppercase {
            alphabet = uppercase
        } else if character.isLetter {
            alphabet = lowercase
        } else {
            // Punctuation stands still. A hyphen or an apostrophe churning into a letter reads as
            // a different word rather than as the same word arriving.
            return character
        }

        var roll = Int(mix(seed, UInt64(step) &* 1_000_003 &+ UInt64(index)) % UInt64(alphabet.count))
        if alphabet[roll] == character {
            roll = (roll + 1) % alphabet.count
        }
        return alphabet[roll]
    }

    /// splitmix64. A hash rather than a `RandomNumberGenerator`, because every frame has to be
    /// reproducible from its own step and index alone: a stateful generator would make the frame
    /// depend on how many frames were drawn before it, and two views joining the reveal at
    /// different moments would then disagree.
    static func mix(_ seed: UInt64, _ counter: UInt64) -> UInt64 {
        var z = seed &+ (counter &* 0x9E37_79B9_7F4A_7C15)
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
