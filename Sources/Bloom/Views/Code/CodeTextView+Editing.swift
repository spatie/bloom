import AppKit
import BloomCore

extension CodeTextView {
    override func insertNewline(_ sender: Any?) {
        guard isEditable, !hasMarkedText() else { return super.insertNewline(sender) }
        apply(SourceEditing.newline(in: string, selection: selectedRange()))
    }

    override func insertTab(_ sender: Any?) {
        guard isEditable, !hasMarkedText() else { return super.insertTab(sender) }
        if selectedRange().length > 0 { editLines(.indent) } else { insertText(SourceEditing.indentation(in: string), replacementRange: selectedRange()) }
    }

    override func insertBacktab(_ sender: Any?) {
        guard isEditable else { return super.insertBacktab(sender) }
        editLines(.outdent)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Key-equivalent lookup can visit sibling views. Only the editor holding the caret acts.
        if window?.firstResponder === self, modifiers == .command, isEditable {
            switch event.charactersIgnoringModifiers {
            case "/": editLines(.comment); return true
            case "]": editLines(.indent); return true
            case "[": editLines(.outdent); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), onOpenReference != nil {
            let point = convert(event.locationInWindow, from: nil)
            let index = characterIndexForInsertion(at: point)
            if let reference = reference(at: index) { onOpenReference?(reference) } else { onDefinition?(index) }
            return
        }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        menu.addItem(.separator())
        if onAsk != nil, selectedRange().length > 0 {
            let ask = NSMenuItem(title: "Ask about this", action: #selector(askAboutSelection), keyEquivalent: "")
            ask.target = self
            menu.addItem(ask)
        }
        if onDefinition != nil {
            let definition = NSMenuItem(title: "Go to Definition", action: #selector(goToDefinition), keyEquivalent: "")
            definition.target = self
            menu.addItem(definition)
        }
        if isEditable {
            let comment = NSMenuItem(title: "Toggle Comment", action: #selector(toggleComment), keyEquivalent: "/")
            comment.target = self
            menu.addItem(comment)
        }
        return menu
    }

    @objc private func askAboutSelection() { onAsk?() }
    @objc private func goToDefinition() { onDefinition?(selectedRange().location) }
    @objc private func toggleComment() { editLines(.comment) }

    func editLines(_ command: SourceEditing.Command) {
        guard isEditable, let edit = SourceEditing.lines(in: string, selection: selectedRange(),
                                                         command: command, language: codeLanguage) else { return }
        apply(edit)
    }

    private func apply(_ edit: SourceEdit) {
        guard shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
        // insertText keeps AppKit's native undo grouping and input methods intact.
        insertText(edit.replacement, replacementRange: edit.range)
        setSelectedRange(edit.selection)
        scrollRangeToVisible(edit.selection)
    }

    private func reference(at index: Int) -> String? {
        let ns = string as NSString
        guard index < ns.length else { return nil }
        let lineRange = ns.lineRange(for: NSRange(location: index, length: 0))
        let line = ns.substring(with: lineRange)
        let pattern = #"[\"']([^\"'\n]+)[\"']|(?:\.?\.?/)?[\w./-]+\.[\w]+(?::\d+(?::\d+)?)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let local = index - lineRange.location
        for match in regex.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
            guard NSLocationInRange(local, match.range) else { continue }
            let quoted = match.range(at: 1)
            return (line as NSString).substring(with: quoted.location == NSNotFound ? match.range : quoted)
        }
        return nil
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layoutManager, textContainer != nil, selectedRange().length == 0,
              selectedRange().location < string.utf16.count else { return }
        let glyph = layoutManager.glyphIndexForCharacter(at: selectedRange().location)
        var line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        line.origin.y += textContainerOrigin.y
        line.origin.x = 0
        line.size.width = bounds.width
        NSColor.labelColor.withAlphaComponent(0.045).setFill()
        line.intersection(rect).fill()
    }

    func updateBracketMatch() {
        bracketTask?.cancel()
        if let bracketRange { layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: bracketRange) }
        bracketRange = nil
        guard selectedRange().length == 0, string.utf16.count < 400_000 else { return }
        let source = string
        let offset = max(0, selectedRange().location - 1)
        let language = codeLanguage
        bracketTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let worker = Task.detached(priority: .utility) { SourceEditing.matchingBracket(in: source, at: offset, language: language) }
            let match = await worker.value
            guard !Task.isCancelled, let self, self.string == source, let match else { return }
            let range = NSRange(location: match, length: 1)
            self.bracketRange = range
            self.layoutManager?.addTemporaryAttribute(.backgroundColor,
                value: NSColor.controlAccentColor.withAlphaComponent(0.25), forCharacterRange: range)
        }
    }
}
