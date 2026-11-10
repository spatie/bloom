/// A live answer uses one text view for layout stability. Let wide content use the column while
/// it arrives, then apply paragraph measures individually once the structural renderer takes over.
extension MarkdownBlock {
    public var needsFullChatColumn: Bool {
        switch self {
        case .table, .codeBlock: true
        case .bulletList(let items, _), .numberedList(_, let items, _):
            items.contains { $0.contains(where: \.needsFullChatColumn) }
        case .blockQuote(let blocks): blocks.contains(where: \.needsFullChatColumn)
        default: false
        }
    }
}
