public struct PaneRefusal: Error, Sendable, Equatable {
    public let sentence: String

    public init(_ sentence: String) {
        self.sentence = sentence
    }
}
