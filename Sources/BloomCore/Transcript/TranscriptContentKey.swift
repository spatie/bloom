import Foundation

/// Everything about a drawn transcript entry that can change what it draws, and therefore how tall
/// it is, reduced to one number.
///
/// **A number rather than the string it was, because nothing ever reads it.** A stored row's key
/// was twelve interpolations joined with a separator, built for every row in the window on every
/// pass of the list, and that includes every 50ms flush of a streaming turn: four hundred rows is
/// some five thousand allocations a pass, to make strings the table only compares for equality and
/// then hashes again as a dictionary key. `Hasher` answers the same question and allocates
/// nothing.
///
/// It is the trade `TranscriptPayloadKey` and `SyntaxKey` already make, one step further on: they
/// keep a hash beside the fields and compare the fields behind it, and this keeps the hash and
/// drops the fields. What it costs is that two different entries hashing alike would be a row told
/// another row's height and never rebuilt. With the twenty thousand entries `TranscriptRowHeights`
/// holds at most, the chance of any two colliding is about one in ninety thousand million, and the
/// hand-built string prefixes it replaces were the likelier way to spell one entry into another.
///
/// The seed is per process, so a key is only ever comparable with another key from this launch.
/// Nothing here is persisted, which is what makes that fine.
public struct TranscriptContentKey: Hashable, Sendable {
    public let value: UInt64

    /// Built by combining every field that can change what the entry draws into a `Hasher`.
    ///
    /// The closure does not escape, so a key costs no allocation at all: the fields go into the
    /// hasher and none of them is kept.
    public init(_ combine: (inout Hasher) -> Void) {
        var hasher = Hasher()
        combine(&hasher)
        value = UInt64(bitPattern: Int64(hasher.finalize()))
    }
}
