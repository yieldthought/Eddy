import Foundation

enum TokenKind: UInt8 {
    case shebang, comment, docMarker
    case key, flowKey, stateKey, argKey
    case punct, indicator
    case string, value, number, constant, anchor
    case stateRef, badStateRef, duration, condition
    case template, templateBrace
    case code, stateCode, heading, bullet, bold, link
    case tabError
}

struct Token: Hashable {
    /// Offset from the start of the line, in UTF-16 units.
    var start: Int
    var length: Int
    var kind: TokenKind
    var state: String?
}

struct LineInfo {
    var start: Int
    var length: Int
    var fullLength: Int
    var indent: Int
    var blank: Bool
    /// Column that soft-wrapped continuation lines hang from.
    var hang: Int
    /// True for lines inside a block scalar (`prompt: |`).
    var prose: Bool
    var proseStart: Int
    var tokens: [Token]
    var signature: Int

    var range: NSRange { NSRange(location: start, length: length) }
    var fullRange: NSRange { NSRange(location: start, length: fullLength) }
}

struct FlowTransition: Hashable {
    var condition = ""
    var target: String?
    var wait: String?
    /// Line of the `- ` item, and of its `go:` key.
    var line: Int
    var goLine: Int?
}

struct FlowStateInfo: Identifiable, Hashable {
    var name: String
    var id: String { name }
    var line: Int
    var location: Int
    var nameLength: Int
    var isStart = false
    var exitCode: String?
    var waits = false
    var wait: String?
    var targets: [String] = []
    var transitions: [FlowTransition] = []
}

struct FlowAnalysis {
    var lines: [LineInfo]
    var states: [FlowStateInfo]
    var flowName: String?

    static let empty = FlowAnalysis(lines: [], states: [], flowName: nil)

    /// Index of the line containing a UTF-16 offset.
    func lineIndex(at location: Int) -> Int {
        guard !lines.isEmpty else { return 0 }
        var lo = 0, hi = lines.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lines[mid].start <= location { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// The state whose block contains a UTF-16 offset.
    func state(at location: Int) -> FlowStateInfo? {
        states.last { $0.location <= location }
    }
}

private enum C {
    static let tab: unichar = 9
    static let lf: unichar = 10
    static let cr: unichar = 13
    static let space: unichar = 32
    static let bang: unichar = 33
    static let dquote: unichar = 34
    static let hash: unichar = 35
    static let percent: unichar = 37
    static let amp: unichar = 38
    static let squote: unichar = 39
    static let rparen: unichar = 41
    static let star: unichar = 42
    static let plus: unichar = 43
    static let comma: unichar = 44
    static let dash: unichar = 45
    static let dot: unichar = 46
    static let zero: unichar = 48
    static let nine: unichar = 57
    static let colon: unichar = 58
    static let gt: unichar = 62
    static let at: unichar = 64
    static let lbracket: unichar = 91
    static let backslash: unichar = 92
    static let rbracket: unichar = 93
    static let backtick: unichar = 96
    static let h: unichar = 104
    static let lbrace: unichar = 123
    static let pipe: unichar = 124
    static let rbrace: unichar = 125
}

/// A forgiving, line-oriented YAML tokenizer that knows about Flow files:
/// top-level keys are states, `go:` values are state references, block
/// scalars are prompt prose with Markdown-ish inline structure.
enum FlowAnalyzer {
    private static let constants: Set<String> = [
        "true", "false", "yes", "no", "on", "off", "null", "~",
        "True", "False", "TRUE", "FALSE", "Yes", "No", "Null", "NULL",
    ]
    private static let enumKeys: Set<String> = ["thinking", "mode", "model", "backend", "effort", "sandbox"]

    static func analyze(_ string: NSString) -> FlowAnalysis {
        let n = string.length
        var u = [unichar](repeating: 0, count: n)
        if n > 0 { string.getCharacters(&u, range: NSRange(location: 0, length: n)) }
        var scanner = Scanner(u: u, string: string)
        return scanner.run()
    }

    private struct Scanner {
        let u: [unichar]
        let string: NSString

        var lines: [LineInfo] = []
        var states: [FlowStateInfo] = []
        var stateNames: Set<String> = []
        var flowName: String?

        // Per-line scratch.
        var lineStart = 0
        var tokens: [Token] = []
        var hang = 0

        // Cross-line context.
        var block: (parent: Int, content: Int?)?
        var plain: (indent: Int, kind: TokenKind)?
        var topKey: String?
        var argsIndent: Int?
        var transitionsIndent: Int?

        init(u: [unichar], string: NSString) {
            self.u = u
            self.string = string
        }

        func text(_ a: Int, _ b: Int) -> String {
            string.substring(with: NSRange(location: a, length: b - a))
        }

        mutating func add(_ a: Int, _ b: Int, _ kind: TokenKind, _ state: String? = nil) {
            guard b > a else { return }
            tokens.append(Token(start: a - lineStart, length: b - a, kind: kind, state: state))
        }

        // MARK: Lines

        func splitLines() -> [(start: Int, end: Int, full: Int)] {
            var result: [(Int, Int, Int)] = []
            var i = 0, s = 0
            let n = u.count
            while i < n {
                let c = u[i]
                if c == C.lf {
                    result.append((s, i, i + 1))
                    s = i + 1
                } else if c == C.cr {
                    let e = i
                    if i + 1 < n, u[i + 1] == C.lf { i += 1 }
                    result.append((s, e, i + 1))
                    s = i + 1
                }
                i += 1
            }
            result.append((s, n, n))
            return result
        }

        mutating func run() -> FlowAnalysis {
            let raw = splitLines()

            // Pass 1: every unindented key is a state (except `flow`).
            for (start, end, _) in raw where start < end {
                let c = u[start]
                if c == C.space || c == C.tab || c == C.hash || c == C.dash { continue }
                if let (ks, ke, _) = scanKey(start, end) {
                    let name = unquote(text(ks, ke))
                    if name != "flow" { stateNames.insert(name) }
                }
            }

            // Pass 2: tokens.
            for (index, (start, end, full)) in raw.enumerated() {
                lineStart = start
                tokens = []
                hang = 0
                var indent = 0
                var hasTab = false
                while start + indent < end, u[start + indent] == C.space || u[start + indent] == C.tab {
                    if u[start + indent] == C.tab { hasTab = true }
                    indent += 1
                }
                let blank = start + indent >= end
                var prose = false
                var proseStart = 0
                hang = indent

                lineBody: do {
                    if var b = block {
                        if blank {
                            prose = b.content != nil
                            break lineBody
                        }
                        if b.content == nil {
                            if indent > b.parent { b.content = indent; block = b } else { block = nil }
                        }
                        if let content = b.content, block != nil, indent >= content {
                            prose = true
                            proseStart = proseLine(start + indent, end)
                            break lineBody
                        }
                        block = nil
                    }
                    if blank { break lineBody }
                    if hasTab { add(start, start + indent, .tabError) }

                    let p = start + indent
                    if index == 0, u[p] == C.hash, p + 1 < end, u[p + 1] == C.bang {
                        add(p, end, .shebang)
                        break lineBody
                    }
                    if u[p] == C.hash {
                        add(p, end, .comment)
                        plain = nil
                        break lineBody
                    }
                    if indent == 0, end - start >= 3 {
                        let head = text(start, start + 3)
                        if (head == "---" || head == "...") && (end - start == 3 || u[start + 3] == C.space) {
                            add(start, end, .docMarker)
                            break lineBody
                        }
                    }
                    if let cont = plain, indent > cont.indent, u[p] != C.dash || p + 1 >= end || u[p + 1] != C.space,
                       scanKey(p, end) == nil {
                        let e = trimmedEnd(p, plainEnd(p, end))
                        add(p, e, cont.kind)
                        if cont.kind == .value || cont.kind == .condition { templates(p, e) }
                        if cont.kind == .condition, let i = currentStateIndex, !states[i].transitions.isEmpty {
                            states[i].transitions[states[i].transitions.count - 1].condition += " " + text(p, e)
                        }
                        commentAfter(e, end)
                        break lineBody
                    }
                    plain = nil
                    structural(index: index, indent: indent, start: start, end: end)
                }

                var hasher = Hasher()
                u[start..<end].withUnsafeBytes { hasher.combine(bytes: $0) }
                hasher.combine(tokens)
                hasher.combine(hang)
                hasher.combine(prose)
                hasher.combine(proseStart)
                hasher.combine(full - start)

                lines.append(LineInfo(
                    start: start, length: end - start, fullLength: full - start,
                    indent: indent, blank: blank, hang: hang, prose: prose,
                    proseStart: proseStart, tokens: tokens, signature: hasher.finalize()
                ))
            }
            return FlowAnalysis(lines: lines, states: states, flowName: flowName)
        }

        // MARK: Structure

        var currentStateIndex: Int? {
            guard let top = topKey, top != "flow" else { return nil }
            return states.lastIndex { $0.name == top }
        }

        mutating func structural(index: Int, indent: Int, start: Int, end: Int) {
            var p = start + indent
            var sequence = 0
            while p < end, u[p] == C.dash, p + 1 == end || u[p + 1] == C.space {
                add(p, p + 1, .indicator)
                p += 1
                sequence += 1
                while p < end, u[p] == C.space { p += 1 }
            }
            hang = p - start
            if p >= end { return }
            if u[p] == C.hash {
                add(p, end, .comment)
                return
            }

            if indent == 0, sequence == 0 {
                argsIndent = nil
                transitionsIndent = nil
            }
            if let a = argsIndent, indent <= a { argsIndent = nil }
            if let t = transitionsIndent, sequence == 0, indent <= t { transitionsIndent = nil }

            guard let (ks, ke, colon) = scanKey(p, end) else {
                value(p, end, key: nil, lineIndent: indent)
                return
            }
            let name = unquote(text(ks, ke))
            if indent == 0, sequence == 0 {
                topKey = name
                if name == "flow" {
                    add(ks, ke, .flowKey)
                } else {
                    add(ks, ke, .stateKey, name)
                    if !states.contains(where: { $0.name == name }) {
                        states.append(FlowStateInfo(name: name, line: index, location: ks, nameLength: ke - ks))
                    }
                }
            } else if let a = argsIndent, indent > a, sequence == 0 {
                add(ks, ke, .argKey)
            } else {
                add(ks, ke, .key)
            }
            add(colon, colon + 1, .punct)

            if topKey == "flow", name == "args", indent > 0 { argsIndent = indent }

            var v = colon + 1
            while v < end, u[v] == C.space { v += 1 }
            hang = v < end && u[v] != C.hash && u[v] != C.pipe && u[v] != C.gt ? v - start : ks - start + 2

            let raw = v < end ? text(v, trimmedEnd(v, plainEnd(v, end))) : ""
            if topKey == "flow", indent > 0, name == "name", flowName == nil, !raw.isEmpty { flowName = unquote(raw) }
            if let i = currentStateIndex, indent > 0 {
                if name == "start", sequence == 0, raw == "true" { states[i].isStart = true }
                if name == "exit", sequence == 0 { states[i].exitCode = raw }
                if name == "wait" { states[i].waits = true }
                if name == "go", !raw.isEmpty { states[i].targets.append(unquote(raw)) }
                if name == "transitions", sequence == 0 {
                    transitionsIndent = indent
                } else if let t = transitionsIndent, indent >= t {
                    if sequence > 0 { states[i].transitions.append(FlowTransition(line: index)) }
                    if let last = states[i].transitions.indices.last {
                        let scalar = raw.hasPrefix("|") || raw.hasPrefix(">") ? "" : unquote(raw)
                        switch name {
                        case "if": states[i].transitions[last].condition = scalar
                        case "go":
                            states[i].transitions[last].target = scalar.isEmpty ? nil : scalar
                            states[i].transitions[last].goLine = index
                        case "wait": states[i].transitions[last].wait = scalar
                        default: break
                        }
                    }
                } else if name == "wait", sequence == 0 {
                    states[i].wait = raw
                }
            }
            value(v, end, key: name, lineIndent: indent)
        }

        mutating func value(_ start: Int, _ end: Int, key: String?, lineIndent: Int) {
            var p = start
            while p < end, u[p] == C.space { p += 1 }
            guard p < end else { return }

            while p < end, u[p] == C.amp || u[p] == C.bang {
                var q = p
                while q < end, u[q] != C.space { q += 1 }
                add(p, q, .anchor)
                p = q
                while p < end, u[p] == C.space { p += 1 }
            }
            guard p < end else { return }

            let c = u[p]
            if c == C.hash {
                add(p, end, .comment)
                return
            }
            if c == C.pipe || c == C.gt {
                var q = p + 1
                var explicit: Int?
                while q < end, u[q] == C.plus || u[q] == C.dash || (u[q] >= C.zero && u[q] <= C.nine) {
                    if u[q] >= C.zero && u[q] <= C.nine { explicit = Int(u[q] - C.zero) }
                    q += 1
                }
                var r = q
                while r < end, u[r] == C.space { r += 1 }
                if r == end || u[r] == C.hash {
                    add(p, q, .punct)
                    if r < end { add(r, end, .comment) }
                    block = (parent: lineIndent, content: explicit.map { lineIndent + $0 })
                    return
                }
            }
            if c == C.dquote || c == C.squote {
                let close = quotedEnd(p, end)
                add(p, close, .string)
                templates(p, close)
                commentAfter(close, end)
                return
            }
            if c == C.lbracket || c == C.lbrace {
                flowCollection(p, end)
                return
            }
            if c == C.star {
                var q = p
                while q < end, u[q] != C.space { q += 1 }
                add(p, q, .anchor)
                return
            }

            let e = trimmedEnd(p, plainEnd(p, end))
            let raw = text(p, e)
            let kind = classify(raw, key: key)
            add(p, e, kind, kind == .stateRef || kind == .badStateRef ? raw : nil)
            if kind == .value || kind == .condition { templates(p, e) }
            commentAfter(e, end)
            if key != nil, kind == .value || kind == .condition { plain = (lineIndent, kind) }
        }

        func classify(_ raw: String, key: String?) -> TokenKind {
            if key == "go", !raw.contains("{{") {
                return stateNames.contains(unquote(raw)) ? .stateRef : .badStateRef
            }
            if key == "wait" { return .duration }
            if FlowAnalyzer.constants.contains(raw) { return .constant }
            if let first = raw.unicodeScalars.first,
               CharacterSet.decimalDigits.contains(first) || ((first == "-" || first == "+" || first == ".") && raw.count > 1),
               Double(raw) != nil || Int(raw.replacingOccurrences(of: "_", with: "")) != nil || raw.hasPrefix("0x") {
                return .number
            }
            if let key, FlowAnalyzer.enumKeys.contains(key) { return .constant }
            if key == "if" { return .condition }
            return .value
        }

        mutating func flowCollection(_ start: Int, _ end: Int) {
            var p = start
            while p < end {
                let c = u[p]
                switch c {
                case C.lbracket, C.rbracket, C.lbrace, C.rbrace, C.comma, C.colon:
                    add(p, p + 1, .punct)
                    p += 1
                case C.space:
                    p += 1
                case C.hash where p > start && u[p - 1] == C.space:
                    add(p, end, .comment)
                    return
                case C.dquote, C.squote:
                    let close = quotedEnd(p, end)
                    add(p, close, .string)
                    p = close
                default:
                    var q = p
                    while q < end {
                        let d = u[q]
                        if d == C.comma || d == C.rbracket || d == C.rbrace { break }
                        if d == C.colon, q + 1 < end, u[q + 1] == C.space { break }
                        q += 1
                    }
                    let e = trimmedEnd(p, q)
                    let raw = text(p, e)
                    add(p, e, q < end && u[q] == C.colon ? .key : classify(raw, key: nil))
                    p = max(q, p + 1)
                }
            }
        }

        // MARK: Prose

        /// Tokenizes one line of block-scalar prose; returns where the prose text begins.
        mutating func proseLine(_ start: Int, _ end: Int) -> Int {
            var p = start
            if u[p] == C.hash {
                var q = p
                while q < end, u[q] == C.hash, q - p < 6 { q += 1 }
                if q == end || u[q] == C.space {
                    add(p, end, .heading)
                    inline(q, end)
                    return p - lineStart
                }
            }
            if (u[p] == C.dash || u[p] == C.star || u[p] == C.plus), p + 1 < end, u[p + 1] == C.space {
                add(p, p + 1, .bullet)
                p += 2
            } else {
                var q = p
                while q < end, u[q] >= C.zero, u[q] <= C.nine, q - p < 3 { q += 1 }
                if q > p, q + 1 < end, u[q] == C.dot || u[q] == C.rparen, u[q + 1] == C.space {
                    add(p, q + 1, .bullet)
                    p = q + 2
                }
            }
            hang = p - lineStart
            inline(p, end)
            return p - lineStart
        }

        mutating func inline(_ start: Int, _ end: Int) {
            var i = start
            while i < end {
                let c = u[i]
                if c == C.backtick {
                    var j = i + 1
                    while j < end, u[j] != C.backtick { j += 1 }
                    if j < end {
                        let inner = text(i + 1, j)
                        if stateNames.contains(inner) {
                            add(i, j + 1, .stateCode, inner)
                        } else {
                            add(i, j + 1, .code)
                            templates(i + 1, j)
                        }
                        i = j + 1
                        continue
                    }
                } else if c == C.lbrace, i + 1 < end, u[i + 1] == C.lbrace {
                    if let close = find("}}", from: i + 2, to: end) {
                        templateToken(i, close + 2)
                        i = close + 2
                        continue
                    }
                } else if c == C.star, i + 1 < end, u[i + 1] == C.star {
                    if let close = find("**", from: i + 2, to: end), close > i + 2 {
                        add(i, close + 2, .bold)
                        i = close + 2
                        continue
                    }
                } else if c == C.h, i == start || !isWordChar(u[i - 1]) {
                    let rest = text(i, min(end, i + 8))
                    if rest.hasPrefix("https://") || rest.hasPrefix("http://") {
                        var j = i
                        while j < end, u[j] != C.space, u[j] != C.backtick, u[j] != C.rparen { j += 1 }
                        while j > i, u[j - 1] == C.dot || u[j - 1] == C.comma || u[j - 1] == C.colon { j -= 1 }
                        add(i, j, .link)
                        i = j
                        continue
                    }
                }
                i += 1
            }
        }

        mutating func templates(_ start: Int, _ end: Int) {
            var i = start
            while i + 1 < end {
                if u[i] == C.lbrace, u[i + 1] == C.lbrace, let close = find("}}", from: i + 2, to: end) {
                    templateToken(i, close + 2)
                    i = close + 2
                } else {
                    i += 1
                }
            }
        }

        mutating func templateToken(_ start: Int, _ end: Int) {
            add(start, end, .template)
            add(start, start + 2, .templateBrace)
            add(end - 2, end, .templateBrace)
        }

        // MARK: Helpers

        func scanKey(_ p: Int, _ end: Int) -> (Int, Int, Int)? {
            guard p < end else { return nil }
            let c = u[p]
            if c == C.dquote || c == C.squote {
                let close = quotedEnd(p, end)
                guard close < end, u[close] == C.colon, close + 1 == end || u[close + 1] == C.space else { return nil }
                return (p, close, close)
            }
            switch c {
            case C.hash, C.lbracket, C.lbrace, C.pipe, C.gt, C.amp, C.star, C.bang, C.percent, C.at, C.backtick:
                return nil
            default:
                break
            }
            var q = p
            while q < end {
                let ch = u[q]
                if ch == C.colon, q + 1 == end || u[q + 1] == C.space || u[q + 1] == C.tab {
                    var ke = q
                    while ke > p, u[ke - 1] == C.space { ke -= 1 }
                    return ke > p ? (p, ke, q) : nil
                }
                if ch == C.hash, q > p, u[q - 1] == C.space { return nil }
                q += 1
            }
            return nil
        }

        /// Index just past the closing quote (or `end` if unterminated).
        func quotedEnd(_ p: Int, _ end: Int) -> Int {
            let quote = u[p]
            var q = p + 1
            while q < end {
                if quote == C.dquote, u[q] == C.backslash { q += 2; continue }
                if u[q] == quote {
                    if quote == C.squote, q + 1 < end, u[q + 1] == C.squote { q += 2; continue }
                    return q + 1
                }
                q += 1
            }
            return end
        }

        /// End of a plain scalar: the line end or a ` #` comment.
        func plainEnd(_ p: Int, _ end: Int) -> Int {
            var q = p
            while q < end {
                if u[q] == C.hash, q > p, u[q - 1] == C.space || u[q - 1] == C.tab { return q }
                q += 1
            }
            return end
        }

        func trimmedEnd(_ p: Int, _ e: Int) -> Int {
            var e = e
            while e > p, u[e - 1] == C.space || u[e - 1] == C.tab { e -= 1 }
            return e
        }

        mutating func commentAfter(_ p: Int, _ end: Int) {
            var q = p
            while q < end, u[q] == C.space { q += 1 }
            if q < end, u[q] == C.hash { add(q, end, .comment) }
        }

        func find(_ needle: String, from start: Int, to end: Int) -> Int? {
            let units = Array(needle.utf16)
            guard units.count <= end - start else { return nil }
            var i = start
            while i + units.count <= end {
                var match = true
                for k in 0..<units.count where u[i + k] != units[k] {
                    match = false
                    break
                }
                if match { return i }
                i += 1
            }
            return nil
        }

        func isWordChar(_ c: unichar) -> Bool {
            (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95
        }

        func unquote(_ s: String) -> String {
            if s.count >= 2, let f = s.first, f == "\"" || f == "'", s.last == f {
                return String(s.dropFirst().dropLast())
            }
            return s
        }
    }
}
