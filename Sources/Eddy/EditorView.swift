import AppKit
import SwiftUI

final class EditorContainerView: NSView {
    let scrollView = NSScrollView()
    let textView: EddyTextView
    let layoutManager = EddyLayoutManager()

    init() {
        let storage = NSTextStorage()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 2
        layoutManager.addTextContainer(container)
        layoutManager.allowsNonContiguousLayout = true
        textView = EddyTextView(frame: .zero, textContainer: container)
        super.init(frame: .zero)

        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.allowsCharacterPickerTouchBarItem = false
        textView.displaysLinkToolTips = false

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.autoresizingMask = [.width, .height]
        addSubview(scrollView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        textView.updateInsets()
    }
}

struct EditorView: NSViewRepresentable {
    let document: FlowDocument
    let config: EditorConfig
    let model: AppModel

    func makeCoordinator() -> EditorCoordinator { EditorCoordinator(model: model) }

    func makeNSView(context: Context) -> EditorContainerView {
        let view = EditorContainerView()
        context.coordinator.attach(view)
        return view
    }

    func updateNSView(_ view: EditorContainerView, context: Context) {
        context.coordinator.update(document: document, config: config)
    }
}

@MainActor
final class EditorCoordinator: NSObject, NSTextViewDelegate, @preconcurrency NSLayoutManagerDelegate {
    let model: AppModel
    private weak var container: EditorContainerView?
    private var document: FlowDocument?
    private var config: EditorConfig?
    private var styles: Styles?

    init(model: AppModel) {
        self.model = model
    }

    private var textView: EddyTextView? { container?.textView }

    func attach(_ view: EditorContainerView) {
        container = view
        view.textView.delegate = self
        view.layoutManager.delegate = self
        view.textView.onTyping = { [weak self] in self?.model.typingStarted() }
        view.textView.analysis = { [weak self] in self?.document?.analysis ?? .empty }
        model.editor = self
    }

    func update(document: FlowDocument, config: EditorConfig) {
        guard let textView, let container else { return }
        var restyle = false
        if config != self.config {
            let styles = model.styles(for: config)
            restyle = styles !== self.styles
            self.config = config
            self.styles = styles
            apply(config, styles, to: textView, in: container)
        }
        if document !== self.document {
            swap(to: document)
        } else if restyle {
            document.restyle(styles!)
            textView.typingAttributes = styles!.typingAttributes
            refreshDecorations()
        }
    }

    private func apply(_ config: EditorConfig, _ styles: Styles, to textView: EddyTextView, in container: EditorContainerView) {
        let theme = styles.theme
        textView.insertionPointColor = theme.caret
        textView.selectedTextAttributes = [.backgroundColor: theme.selection]
        textView.typingAttributes = styles.typingAttributes
        textView.charWidth = styles.charWidth
        textView.lineHeight = styles.lineHeight
        textView.columnWidth = (CGFloat(config.columnWidth) * styles.charWidth + 4).rounded()
        textView.typewriter = config.typewriter
        textView.showGuides = config.guides
        textView.highlightLine = config.currentLine
        textView.currentLineColor = theme.currentLine
        textView.guideColor = theme.guide
        textView.dimColor = theme.midBackground.withAlphaComponent(0.72)
        textView.issueColor = theme.error
        textView.warningColor = theme.number
        container.layoutManager.pillInset = styles.pillInset
        container.scrollView.scrollerKnobStyle = theme.isDark ? .light : .dark
        container.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        textView.updateInsets()
        textView.needsDisplay = true
    }

    private func swap(to document: FlowDocument) {
        guard let textView, let container, let styles else { return }
        if let old = self.document {
            old.selection = textView.selectedRange()
            old.scrollY = container.scrollView.contentView.bounds.origin.y
        }
        textView.breakUndoCoalescing()
        container.layoutManager.replaceTextStorage(document.storage)
        self.document = document
        document.restyle(styles)
        textView.typingAttributes = styles.typingAttributes

        let length = document.storage.length
        let selection = document.selection
        textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        container.layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: min(length, NSMaxRange(selection) + 2000)))
        let clip = container.scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: document.scrollY))
        container.scrollView.reflectScrolledClipView(clip)
        textView.window?.makeFirstResponder(textView)
        refreshDecorations()
        updateStatus()
    }

    func documentReloaded(_ document: FlowDocument) {
        guard document === self.document, let textView else { return }
        let length = document.storage.length
        if NSMaxRange(textView.selectedRange()) > length {
            textView.setSelectedRange(NSRange(location: length, length: 0))
        }
        refreshDecorations()
        updateStatus()
    }

    func validationChanged() { refreshDecorations() }

    func refreshDecorations() {
        guard let textView, let document else { return }
        var lines: [Int: ValidationIssue.Severity] = [:]
        for issue in document.validation.issues {
            var line = issue.line
            if line == nil, let state = issue.state {
                line = document.states.first { $0.name == state }?.line
            }
            if let line, lines[line] != .error { lines[line] = issue.severity }
        }
        textView.issueLines = lines
        textView.focusRange = focusRange()
        textView.needsDisplay = true
    }

    // MARK: Navigation

    func reveal(state name: String) {
        guard let textView, let container, let document,
              let state = document.states.first(where: { $0.name == name }) else { return }
        let range = NSRange(location: state.location, length: state.nameLength)
        textView.setSelectedRange(NSRange(location: state.location, length: 0))
        guard let layoutManager = textView.layoutManager, let textContainer = textView.textContainer else { return }
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: NSMaxRange(range)))
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        let clip = container.scrollView.contentView
        let target = max(0, rect.minY + textView.textContainerOrigin.y - clip.bounds.height * 0.22)
        let maxY = max(0, textView.frame.height - clip.bounds.height)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            context.allowsImplicitAnimation = true
            clip.animator().setBoundsOrigin(NSPoint(x: 0, y: min(target, maxY)))
        } completionHandler: {
            container.scrollView.reflectScrolledClipView(clip)
            textView.showFindIndicator(for: range)
        }
        textView.window?.makeFirstResponder(textView)
    }

    func jumpState(_ step: Int) {
        guard let textView, let document, !document.states.isEmpty else { return }
        let caret = textView.selectedRange().location
        let states = document.states
        let target = step > 0
            ? states.first { $0.location > caret } ?? states.first
            : states.last { $0.location < caret } ?? states.last
        if let target { model.open(document.url, state: target.name) }
    }

    func jump(toLine line: Int) {
        guard let textView, let document, line < document.analysis.lines.count else { return }
        let info = document.analysis.lines[line]
        textView.setSelectedRange(NSRange(location: info.start + info.indent, length: 0))
        textView.scrollRangeToVisible(info.range)
        textView.showFindIndicator(for: NSRange(location: info.start + info.indent, length: max(0, info.length - info.indent)))
        textView.window?.makeFirstResponder(textView)
    }

    /// Types at the end of the document, as a user would (snapshot testing).
    func debugType(_ text: String) {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        for character in text {
            if character == "\n" {
                textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            } else {
                textView.insertText(String(character), replacementRange: textView.selectedRange())
            }
        }
    }

    // MARK: Focus

    private func focusRange() -> NSRange? {
        guard let config, config.focus != .off, let textView, let document else { return nil }
        let lines = document.analysis.lines
        guard !lines.isEmpty else { return nil }
        let index = document.analysis.lineIndex(at: textView.selectedRange().location)
        var first = index
        var last = index
        switch config.focus {
        case .off:
            return nil
        case .state:
            func isTop(_ line: LineInfo) -> Bool {
                line.tokens.first.map { ($0.kind == .stateKey || $0.kind == .flowKey) && $0.start == 0 } ?? false
            }
            while first > 0, !isTop(lines[first]) { first -= 1 }
            last = index + 1
            while last < lines.count, !isTop(lines[last]) { last += 1 }
            last -= 1
            while last > index, lines[last].blank { last -= 1 }
        case .paragraph:
            if lines[index].blank { return NSRange(location: lines[index].start, length: 0) }
            while first > 0, !lines[first - 1].blank { first -= 1 }
            while last + 1 < lines.count, !lines[last + 1].blank { last += 1 }
        }
        let start = lines[first].start
        return NSRange(location: start, length: max(1, lines[last].start + lines[last].length - start))
    }

    // MARK: Status

    private func updateStatus() {
        guard let textView, let document else { return }
        let caret = textView.selectedRange().location
        let analysis = document.analysis
        let index = analysis.lineIndex(at: caret)
        let column = analysis.lines.isEmpty ? 1 : caret - analysis.lines[index].start + 1
        let state = analysis.state(at: caret)?.name
        if model.caretLine != index + 1 { model.caretLine = index + 1 }
        if model.caretColumn != column { model.caretColumn = column }
        if model.caretState != state { model.caretState = state }
    }

    private func centerCaret() {
        guard let textView, let container, let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }
        let caret = textView.selectedRange().location
        let length = (textView.string as NSString).length
        var rect: NSRect
        if caret >= length, layoutManager.extraLineFragmentRect.height > 0 {
            rect = layoutManager.extraLineFragmentRect
        } else if length > 0 {
            let glyph = layoutManager.glyphIndexForCharacter(at: min(caret, length - 1))
            rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        } else {
            return
        }
        _ = textContainer
        let clip = container.scrollView.contentView
        let target = rect.midY + textView.textContainerOrigin.y - clip.bounds.height / 2
        let maxY = max(0, textView.frame.height - clip.bounds.height)
        let y = min(max(0, target), maxY).rounded()
        guard abs(y - clip.bounds.origin.y) > 1 else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.allowsImplicitAnimation = true
            clip.animator().setBoundsOrigin(NSPoint(x: 0, y: y))
        } completionHandler: {
            container.scrollView.reflectScrolledClipView(clip)
        }
    }

    // MARK: NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        guard let textView, let document, let styles, !textView.hasMarkedText() else { return }
        document.restyle(styles)
        document.refreshDirty()
        model.textDidChange(document)
        refreshDecorations()
        updateStatus()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let textView, document != nil else { return }
        updateStatus()
        textView.focusRange = focusRange()
        if config?.typewriter == true { centerCaret() }
        textView.needsDisplay = true
    }

    func undoManager(for view: NSTextView) -> UndoManager? { document?.undoManager }

    // MARK: NSLayoutManagerDelegate

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
        lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
        baselineOffset: UnsafeMutablePointer<CGFloat>,
        in textContainer: NSTextContainer,
        forGlyphRange glyphRange: NSRange
    ) -> Bool {
        guard let styles else { return false }
        lineFragmentRect.pointee.size.height = styles.lineHeight
        lineFragmentUsedRect.pointee.size.height = styles.lineHeight
        baselineOffset.pointee = styles.baseline
        return true
    }
}
