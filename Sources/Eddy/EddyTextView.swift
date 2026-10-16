import AppKit

/// Draws background-colour runs (templates, code spans) as soft rounded pills
/// instead of full-height blocks.
final class EddyLayoutManager: NSLayoutManager {
    var pillInset: CGFloat = 3

    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int, forCharacterRange charRange: NSRange, color: NSColor) {
        guard let storage = textStorage, charRange.location < storage.length,
              let attribute = storage.attribute(.backgroundColor, at: charRange.location, effectiveRange: nil) as? NSColor,
              attribute == color
        else {
            super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
            return
        }
        color.setFill()
        for index in 0..<rectCount {
            let rect = rectArray[index].insetBy(dx: -1.5, dy: pillInset)
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        }
    }
}

final class EddyTextView: NSTextView {
    var onTyping: (() -> Void)?

    var columnWidth: CGFloat = 700 { didSet { if oldValue != columnWidth { updateInsets() } } }
    var typewriter = false { didSet { if oldValue != typewriter { updateInsets() } } }
    var charWidth: CGFloat = 8
    var lineHeight: CGFloat = 20
    var showGuides = true
    var highlightLine = true
    var currentLineColor = NSColor.clear
    var guideColor = NSColor.clear
    var dimColor = NSColor.clear
    var issueColor = NSColor.systemRed
    var warningColor = NSColor.systemOrange
    var analysis: () -> FlowAnalysis = { .empty }
    var focusRange: NSRange? { didSet { if oldValue != focusRange { needsDisplay = true } } }
    var issueLines: [Int: ValidationIssue.Severity] = [:] { didSet { needsDisplay = true } }

    // MARK: Layout

    func updateInsets() {
        guard let scrollView = enclosingScrollView else { return }
        let size = scrollView.contentSize
        let horizontal = max(28, ((size.width - columnWidth) / 2).rounded(.down))
        let vertical: CGFloat = typewriter ? max(48, (size.height / 2 - lineHeight).rounded()) : 36
        let inset = NSSize(width: horizontal, height: vertical)
        if textContainerInset != inset { textContainerInset = inset }
    }

    // MARK: Drawing

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layoutManager, let textContainer else { return }
        let origin = textContainerOrigin
        let columnRect = NSRect(x: origin.x - 14, y: 0, width: textContainer.size.width + 28, height: 0)
        let lines = analysis()

        // Issues reported by `flow validate`.
        for (line, severity) in issueLines where line < lines.lines.count {
            let info = lines.lines[line]
            let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: info.start, length: max(info.length, 1)), actualCharacterRange: nil)
            var band = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
            band.origin.y += origin.y
            guard band.intersects(rect.insetBy(dx: 0, dy: -lineHeight)) else { continue }
            let color = severity == .error ? issueColor : warningColor
            color.withAlphaComponent(0.09).setFill()
            NSBezierPath(roundedRect: NSRect(x: columnRect.minX, y: band.minY, width: columnRect.width, height: band.height), xRadius: 5, yRadius: 5).fill()
            color.setFill()
            let dot = NSRect(x: columnRect.minX - 12, y: band.minY + lineHeight / 2 - 3, width: 6, height: 6)
            NSBezierPath(ovalIn: dot).fill()
        }

        // Current line.
        if highlightLine, selectedRange().length == 0, window?.firstResponder === self {
            let caret = selectedRange().location
            var band = NSRect.zero
            let length = (string as NSString).length
            if caret >= length, layoutManager.extraLineFragmentRect.height > 0 {
                band = layoutManager.extraLineFragmentRect
            } else if length > 0 {
                let paragraph = (string as NSString).lineRange(for: NSRange(location: min(caret, length - 1), length: 0))
                let glyphs = layoutManager.glyphRange(forCharacterRange: paragraph, actualCharacterRange: nil)
                band = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
            }
            if band.height > 0 {
                band.origin.y += origin.y
                currentLineColor.setFill()
                NSBezierPath(roundedRect: NSRect(x: columnRect.minX, y: band.minY, width: columnRect.width, height: band.height), xRadius: 5, yRadius: 5).fill()
            }
        }

        // Indent guides.
        guard showGuides, !lines.lines.isEmpty else { return }
        let visible = NSRect(x: 0, y: rect.minY - origin.y, width: textContainer.size.width, height: rect.height)
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visible, in: textContainer)
        guard glyphRange.length > 0 else { return }
        guideColor.setFill()
        let padding = textContainer.lineFragmentPadding
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { fragment, _, _, fragmentGlyphs, _ in
            let charIndex = layoutManager.characterIndexForGlyph(at: fragmentGlyphs.location)
            let lineIndex = lines.lineIndex(at: charIndex)
            let indent = Self.guideIndent(lines, lineIndex)
            guard indent >= 2 else { return }
            var column = 2
            while column < indent {
                let x = (origin.x + padding + CGFloat(column) * self.charWidth).rounded() + 0.5
                NSRect(x: x - 0.5, y: fragment.minY + origin.y, width: 1, height: fragment.height).fill(using: .sourceOver)
                column += 2
            }
        }
    }

    /// Indentation used for guides; blank lines borrow from their neighbours.
    private static func guideIndent(_ analysis: FlowAnalysis, _ index: Int) -> Int {
        let lines = analysis.lines
        let line = lines[index]
        if !line.blank { return line.indent }
        var next = index + 1
        while next < lines.count, lines[next].blank, next - index < 40 { next += 1 }
        var previous = index - 1
        while previous >= 0, lines[previous].blank, index - previous < 40 { previous -= 1 }
        let after = next < lines.count && !lines[next].blank ? lines[next].indent : 0
        let before = previous >= 0 && !lines[previous].blank ? lines[previous].indent : 0
        return min(after, before)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let focusRange, let layoutManager, let textContainer, focusRange.length > 0 else { return }
        let glyphs = layoutManager.glyphRange(forCharacterRange: focusRange, actualCharacterRange: nil)
        var band = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        band.origin.y += textContainerOrigin.y
        let top = band.minY - 4
        let bottom = band.maxY + 4
        let fade: CGFloat = 28
        let visible = visibleRect
        let solid = dimColor
        let clear = dimColor.withAlphaComponent(0)
        // NSTextView leaves the clip at the text container; dim the margins too.
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: dirtyRect).setClip()

        if top > visible.minY {
            solid.setFill()
            NSRect(x: visible.minX, y: visible.minY, width: visible.width, height: max(0, top - fade - visible.minY)).fill(using: .sourceOver)
            NSGradient(starting: solid, ending: clear)?.draw(in: NSRect(x: visible.minX, y: top - fade, width: visible.width, height: fade), angle: 90)
        }
        if bottom < visible.maxY {
            NSGradient(starting: clear, ending: solid)?.draw(in: NSRect(x: visible.minX, y: bottom, width: visible.width, height: fade), angle: 90)
            solid.setFill()
            NSRect(x: visible.minX, y: bottom + fade, width: visible.width, height: max(0, visible.maxY - bottom - fade)).fill(using: .sourceOver)
        }
    }

    // MARK: Typing

    override func keyDown(with event: NSEvent) {
        if !event.modifierFlags.contains(.command) { onTyping?() }
        super.keyDown(with: event)
    }

    private var nsString: NSString { string as NSString }

    private func replace(_ range: NSRange, with text: String, select selection: NSRange? = nil, action: String? = nil) {
        guard shouldChangeText(in: range, replacementString: text) else { return }
        textStorage?.replaceCharacters(in: range, with: text)
        didChangeText()
        if let action { undoManager?.setActionName(action) }
        if let selection { setSelectedRange(selection) }
    }

    override func insertNewline(_ sender: Any?) {
        let selection = selectedRange()
        let lineStart = nsString.lineRange(for: NSRange(location: selection.location, length: 0)).location
        let before = nsString.substring(with: NSRange(location: lineStart, length: selection.location - lineStart))
        var indent = before.prefix { $0 == " " }.count
        let trimmed = before.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("- ") { indent += 2 }
        if trimmed.hasSuffix(":") || trimmed.range(of: #":\s*[|>][-+0-9]*$"#, options: .regularExpression) != nil {
            indent += 2
        }
        insertText("\n" + String(repeating: " ", count: indent), replacementRange: selection)
        if typewriter { scrollRangeToVisible(selectedRange()) }
    }

    override func insertTab(_ sender: Any?) {
        let selection = selectedRange()
        if selection.length > 0, nsString.substring(with: selection).contains("\n") {
            shiftLines(by: 2)
            return
        }
        let lineStart = nsString.lineRange(for: NSRange(location: selection.location, length: 0)).location
        let column = selection.location - lineStart
        insertText(String(repeating: " ", count: 2 - column % 2), replacementRange: selection)
    }

    override func insertBacktab(_ sender: Any?) { shiftLines(by: -2) }

    override func deleteBackward(_ sender: Any?) {
        let selection = selectedRange()
        if selection.length == 0, selection.location > 0 {
            let lineStart = nsString.lineRange(for: NSRange(location: selection.location, length: 0)).location
            let column = selection.location - lineStart
            if column > 1 {
                let before = nsString.substring(with: NSRange(location: lineStart, length: column))
                if before.allSatisfy({ $0 == " " }) {
                    let count = column % 2 == 0 ? 2 : 1
                    replace(NSRange(location: selection.location - count, length: count), with: "")
                    return
                }
            }
        }
        super.deleteBackward(sender)
    }

    @objc func indentSelection(_ sender: Any?) { shiftLines(by: 2) }
    @objc func outdentSelection(_ sender: Any?) { shiftLines(by: -2) }

    private func selectedLines() -> (range: NSRange, lines: [String]) {
        var selection = selectedRange()
        if selection.length > 0, nsString.character(at: NSMaxRange(selection) - 1) == 10 {
            selection.length -= 1
        }
        var range = nsString.lineRange(for: selection)
        if range.length > 0, nsString.character(at: NSMaxRange(range) - 1) == 10 { range.length -= 1 }
        return (range, nsString.substring(with: range).components(separatedBy: "\n"))
    }

    func shiftLines(by delta: Int) {
        let (range, lines) = selectedLines()
        let shifted = lines.map { line -> String in
            if delta > 0 { return line.isEmpty ? line : String(repeating: " ", count: delta) + line }
            let lead = line.prefix { $0 == " " }.count
            return String(line.dropFirst(min(lead, -delta)))
        }
        let text = shifted.joined(separator: "\n")
        replace(range, with: text, select: NSRange(location: range.location, length: (text as NSString).length),
                action: delta > 0 ? "Indent" : "Outdent")
    }

    @objc func toggleComment(_ sender: Any?) {
        let (range, lines) = selectedLines()
        let content = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !content.isEmpty else { return }
        let commented = content.allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        let minIndent = content.map { $0.prefix { $0 == " " }.count }.min() ?? 0
        let result = lines.map { line -> String in
            if line.trimmingCharacters(in: .whitespaces).isEmpty { return line }
            if commented {
                guard let hash = line.firstIndex(of: "#") else { return line }
                var rest = line[line.index(after: hash)...]
                if rest.first == " " { rest = rest.dropFirst() }
                return String(line[..<hash]) + rest
            }
            let index = line.index(line.startIndex, offsetBy: minIndent)
            return String(line[..<index]) + "# " + line[index...]
        }
        let text = result.joined(separator: "\n")
        let single = selectedRange().length == 0 && lines.count == 1
        let caret = selectedRange().location + (commented ? -min(2, selectedRange().location - range.location) : 2)
        replace(range, with: text,
                select: single ? NSRange(location: max(range.location, caret), length: 0)
                    : NSRange(location: range.location, length: (text as NSString).length),
                action: commented ? "Uncomment" : "Comment")
    }
}
