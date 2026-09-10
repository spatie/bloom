import Foundation

/// A saved annotation on this snapshot. Its attachment carries the durable comment and URL;
/// the rectangle belongs to the review currently being shown in this browser tab.
public struct BrowserRegionComment: Identifiable, Sendable, Equatable {
    public var id: String { path }
    public let path: String
    public let selection: CGRect
    public let address: String
    public var body: String

    public init(path: String, selection: CGRect, address: String, body: String) {
        self.path = path
        self.selection = selection
        self.address = address
        self.body = body
    }

}
