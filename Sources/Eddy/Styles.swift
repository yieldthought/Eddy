import AppKit

enum ProseFont: String, CaseIterable, Identifiable {
    case mono, sans, serif
    var id: String { rawValue }
    var label: String {
        switch self {
        case .mono: "Monospaced"
        case .sans: "Sans Serif"
        case .serif: "Serif"
        }
    }
}

enum FocusMode: String, CaseIterable, Identifiable {
    case off, state, paragraph
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: "Off"
        case .state: "Current State"
        case .paragraph: "Current Paragraph"
        }
    }
}

enum GraphLabels: String, CaseIterable, Identifiable {
    case automatic, always, never
    var id: String { rawValue }
    var label: String {
        switch self {
        case .automatic: "Automatic"
        case .always: "Always"
        case .never: "Never"
        }
    }
}

struct EditorConfig: Equatable {
    var themeID: String
    var fontName: String
    var fontSize: CGFloat
    var lineSpacing: CGFloat
    var columnWidth: Int
    var prose: ProseFont
    var guides: Bool
    var currentLine: Bool
    var focus: FocusMode
    var typewriter: Bool

    var styleKey: String { "\(themeID)|\(fontName)|\(fontSize)|\(lineSpacing)|\(columnWidth)|\(prose.rawValue)" }
}

/// Fonts, line metrics and per-token attributes for one theme + font setup.
@MainActor
final class Styles {
    let theme: Theme
    let generation: Int
    let font: NSFont
    let bold: NSFont
    let italic: NSFont
    let prose: NSFont?
    let proseBold: NSFont?
    let lineHeight: CGFloat
    let baseline: CGFloat
    let charWidth: CGFloat
    let pillInset: CGFloat
    let columnWidth: Int

    private var paragraphs: [Int: NSParagraphStyle] = [:]
    private var cache: [String: [NSAttributedString.Key: Any]] = [:]

    init(theme: Theme, config: EditorConfig, generation: Int) {
        self.theme = theme
        self.generation = generation
        columnWidth = config.columnWidth
        let size = config.fontSize
        let system = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let base = config.fontName.isEmpty ? system : (NSFont(name: config.fontName, size: size) ?? system)
        font = base
        bold = config.fontName.isEmpty
            ? .monospacedSystemFont(ofSize: size, weight: .semibold)
            : Styles.variant(base, .bold)
        italic = Styles.variant(base, .italic)

        switch config.prose {
        case .mono:
            prose = nil
            proseBold = nil
        case .sans:
            prose = .systemFont(ofSize: size + 0.5)
            proseBold = .systemFont(ofSize: size + 0.5, weight: .semibold)
        case .serif:
            let descriptor = NSFont.systemFont(ofSize: size + 1.5).fontDescriptor.withDesign(.serif)
            let serif = descriptor.flatMap { NSFont(descriptor: $0, size: size + 1.5) } ?? .systemFont(ofSize: size + 1.5)
            prose = serif
            proseBold = Styles.variant(serif, .bold)
        }

        let glyphHeight = base.ascender - base.descender
        lineHeight = (glyphHeight * config.lineSpacing).rounded()
        baseline = ((lineHeight - glyphHeight) / 2 + base.ascender).rounded()
        charWidth = ("M" as NSString).size(withAttributes: [.font: base]).width
        pillInset = max(0, ((lineHeight - glyphHeight) / 2 - 1.5).rounded(.down))
    }

    private static func variant(_ font: NSFont, _ trait: NSFontDescriptor.SymbolicTraits) -> NSFont {
        let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(trait))
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    func paragraph(hang: Int) -> NSParagraphStyle {
        let hang = min(hang, columnWidth / 2)
        if let cached = paragraphs[hang] { return cached }
        let p = NSMutableParagraphStyle()
        p.headIndent = CGFloat(hang) * charWidth
        p.minimumLineHeight = lineHeight
        p.maximumLineHeight = lineHeight
        p.lineBreakMode = .byWordWrapping
        p.tabStops = []
        p.defaultTabInterval = charWidth * 2
        paragraphs[hang] = p
        return p
    }

    func base(hang: Int) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: theme.text, .paragraphStyle: paragraph(hang: hang)]
    }

    var typingAttributes: [NSAttributedString.Key: Any] { base(hang: 0) }

    func attributes(_ kind: TokenKind, state: String?, prose inProse: Bool) -> [NSAttributedString.Key: Any] {
        let key = "\(kind.rawValue)|\(state ?? "")|\(inProse)"
        if let cached = cache[key] { return cached }
        let t = theme
        let strong = inProse ? (proseBold ?? bold) : bold
        var a: [NSAttributedString.Key: Any] = [:]

        func glow(_ color: NSColor) {
            guard t.neon else { return }
            let shadow = NSShadow()
            shadow.shadowColor = color.withAlphaComponent(0.65)
            shadow.shadowBlurRadius = 8
            shadow.shadowOffset = .zero
            a[.shadow] = shadow
        }

        switch kind {
        case .shebang:
            a[.foregroundColor] = t.muted
            a[.font] = italic
        case .comment:
            a[.foregroundColor] = t.muted
            if t.italicComments { a[.font] = italic }
        case .docMarker, .punct:
            a[.foregroundColor] = t.muted
        case .key:
            a[.foregroundColor] = t.key
        case .flowKey:
            a[.foregroundColor] = t.flowKey
            a[.font] = bold
            glow(t.flowKey)
        case .stateKey:
            let color = t.stateColor(state ?? "")
            a[.foregroundColor] = color
            a[.font] = bold
            glow(color)
        case .argKey:
            a[.foregroundColor] = t.argKey
        case .indicator, .bullet:
            a[.foregroundColor] = t.indicator
        case .string:
            a[.foregroundColor] = t.string
        case .value:
            a[.foregroundColor] = t.value
        case .number, .duration:
            a[.foregroundColor] = t.number
        case .constant:
            a[.foregroundColor] = t.constant
        case .anchor:
            a[.foregroundColor] = t.constant
            a[.font] = italic
        case .stateRef:
            a[.foregroundColor] = t.stateColor(state ?? "")
        case .badStateRef:
            a[.foregroundColor] = t.error
            a[.underlineStyle] = NSUnderlineStyle.thick.rawValue | NSUnderlineStyle.patternDot.rawValue
            a[.underlineColor] = t.error.withAlphaComponent(0.8)
        case .condition:
            a[.foregroundColor] = t.condition
            a[.font] = italic
        case .template:
            a[.foregroundColor] = t.template
            a[.font] = font
            if let fill = t.templateFill { a[.backgroundColor] = fill }
        case .templateBrace:
            a[.foregroundColor] = t.template.withAlphaComponent(0.5)
        case .code:
            a[.foregroundColor] = t.code
            a[.font] = font
            if let fill = t.codeFill { a[.backgroundColor] = fill }
        case .stateCode:
            let color = t.stateColor(state ?? "")
            a[.foregroundColor] = color
            a[.font] = font
            a[.backgroundColor] = color.withAlphaComponent(t.isDark ? 0.15 : 0.12)
        case .heading:
            a[.foregroundColor] = t.heading
            a[.font] = strong
        case .bold:
            a[.foregroundColor] = t.heading
            a[.font] = strong
        case .link:
            a[.foregroundColor] = t.link
            a[.underlineStyle] = NSUnderlineStyle.single.rawValue
            a[.underlineColor] = t.link.withAlphaComponent(0.35)
        case .tabError:
            a[.backgroundColor] = t.error.withAlphaComponent(0.28)
        }
        cache[key] = a
        return a
    }

    /// Applies attributes to the lines of `analysis` in `range` (line indices).
    func apply(_ analysis: FlowAnalysis, lines range: Range<Int>, to storage: NSTextStorage) {
        let length = storage.length
        for index in range {
            let line = analysis.lines[index]
            guard line.start + line.fullLength <= length else { continue }
            if line.fullLength > 0 {
                storage.setAttributes(base(hang: line.hang), range: line.fullRange)
            }
            if line.prose, let prose, line.proseStart < line.length {
                storage.addAttribute(.font, value: prose, range: NSRange(location: line.start + line.proseStart, length: line.length - line.proseStart))
            }
            for token in line.tokens {
                storage.addAttributes(
                    attributes(token.kind, state: token.state, prose: line.prose),
                    range: NSRange(location: line.start + token.start, length: token.length)
                )
            }
        }
    }
}
