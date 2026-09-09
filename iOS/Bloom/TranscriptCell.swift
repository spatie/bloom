import UIKit

/// Selectable text stays native. Reusing cells avoids rebuilding an entire view hierarchy on
/// every streamed token, and code remains readable without rendering untrusted HTML.
final class TranscriptCell: UITableViewCell {
    private let heading = UILabel()
    private let symbol = UIImageView()
    private let message = UITextView()
    private let stack = UIStackView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        heading.font = .preferredFont(forTextStyle: .caption1)
        heading.adjustsFontForContentSizeCategory = true
        heading.textColor = BloomTheme.secondary
        symbol.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .caption1)
        symbol.tintColor = BloomTheme.accent
        symbol.setContentHuggingPriority(.required, for: .horizontal)
        let header = UIStackView(arrangedSubviews: [symbol, heading])
        header.spacing = 7
        header.alignment = .center
        message.isEditable = false
        message.isScrollEnabled = false
        message.backgroundColor = .clear
        message.textContainerInset = .zero
        message.textContainer.lineFragmentPadding = 0
        message.adjustsFontForContentSizeCategory = true
        message.linkTextAttributes = [.foregroundColor: BloomTheme.accent]
        stack.axis = .vertical
        stack.spacing = 9
        stack.addArrangedSubview(header)
        stack.addArrangedSubview(message)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),
        ])
    }
    required init?(coder: NSCoder) { fatalError("Use init(style:reuseIdentifier:)") }

    func configure(kind: String, text: String) {
        let user = kind == "user"
        let assistant = kind == "assistant" || kind == "assistantText"
        let titles = ["thinking": "Thinking", "toolUse": "Tool call", "toolResult": "Tool result", "permissionAsk": "Permission request", "result": "Turn complete", "error": "Error", "system": "Session", "notice": "Notice", "crew": "Agent update"]
        heading.text = user ? "YOU" : assistant ? "BLOOM" : (titles[kind] ?? kind).uppercased()
        symbol.image = UIImage(systemName: user ? "person.crop.circle" : assistant ? "sparkle" : "terminal")
        message.attributedText = Self.render(text, markdown: !user)
        message.accessibilityLabel = (user ? "You" : heading.text ?? "Bloom") + ": " + text
    }

    private static func render(_ text: String, markdown: Bool) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.paragraphSpacing = 2
        let base = UIFont.preferredFont(forTextStyle: .body)
        let code = UIFontMetrics(forTextStyle: .body).scaledFont(for: .monospacedSystemFont(ofSize: 15, weight: .regular))
        let chunks = markdown ? text.components(separatedBy: "```") : [text]
        for (index, chunk) in chunks.enumerated() {
            if index % 2 == 1 {
                let value = chunk.firstIndex(of: "\n").map { String(chunk[chunk.index(after: $0)...]) } ?? chunk
                output.append(NSAttributedString(string: value, attributes: [.font: code, .foregroundColor: UIColor.label, .backgroundColor: BloomTheme.panel, .paragraphStyle: paragraph]))
                continue
            }
            guard markdown, let parsed = try? AttributedString(markdown: chunk, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
                output.append(NSAttributedString(string: chunk, attributes: [.font: base, .foregroundColor: UIColor.label, .paragraphStyle: paragraph]))
                continue
            }
            for run in parsed.runs {
                let intent = run.inlinePresentationIntent ?? []
                var font = intent.contains(.code) ? code : base
                var traits = font.fontDescriptor.symbolicTraits
                if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
                if intent.contains(.emphasized) { traits.insert(.traitItalic) }
                if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) { font = UIFont(descriptor: descriptor, size: font.pointSize) }
                var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.label, .paragraphStyle: paragraph]
                if intent.contains(.code) { attributes[.backgroundColor] = BloomTheme.panel }
                if let link = run.link { attributes[.link] = link }
                output.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
            }
        }
        return output
    }
}
