import AppKit

extension NSColor {
    var hex: String {
        let c = usingColorSpace(.sRGB) ?? self
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

/// Builds a Graphviz graph from the live analysis, in the visual language of
/// `flow chart`: a start dot, rounded state boxes with START / WAIT / EXIT
/// notes, wrapped condition labels, dashed edges for waits, and each state's
/// colour on its box and on the edges that enter it.
enum FlowGraph {
    /// Element ids: `s<i>` state i, `t<line>` transition, `g<line>` unknown target.
    static func dot(for states: [FlowStateInfo], theme: Theme, labels: Bool = true) -> String {
        let index = Dictionary(states.enumerated().map { ($1.name, $0) }, uniquingKeysWith: { first, _ in first })
        let page = theme.midBackground
        let mix: CGFloat = theme.isDark ? 0.16 : 0.11
        func color(_ name: String) -> NSColor { theme.stateColor(name) }

        var out = [
            "digraph flow {",
            "  graph [bgcolor=\"transparent\", rankdir=TB, pad=\"0.25\", nodesep=\"0.34\", ranksep=\"0.6\", splines=spline, outputorder=edgesfirst];",
            "  node [shape=box, style=\"rounded,filled\", fontname=\"Helvetica\", fontsize=12, margin=\"0.16,0.07\", penwidth=1.5, fontcolor=\"\(theme.text.hex)\"];",
            "  edge [fontname=\"Helvetica\", fontsize=10.5, arrowsize=0.7, penwidth=1.2, fontcolor=\"\(theme.muted.hex)\"];",
        ]

        if let start = states.first(where: \.isStart), let i = index[start.name] {
            let c = color(start.name).hex
            out.append("  __start [id=\"start\", shape=circle, label=\"\", width=0.13, fixedsize=true, style=filled, fillcolor=\"\(c)\", color=\"\(c)\"];")
            out.append("  __start -> s\(i) [id=\"start-edge\", color=\"\(c)\", penwidth=1.6];")
        }

        for (i, state) in states.enumerated() {
            let c = color(state.name)
            var notes: [String] = []
            if state.isStart { notes.append("START") }
            if let wait = state.wait { notes.append("WAIT \(wait)") }
            if let code = state.exitCode { notes.append("EXIT \(code)") }
            let noteColor = state.exitCode.map { $0 == "0" ? theme.string : theme.error } ?? theme.muted
            var label = "<<TABLE BORDER=\"0\" CELLBORDER=\"0\" CELLPADDING=\"1\"><TR><TD><FONT POINT-SIZE=\"13\"><B>\(html(state.name))</B></FONT></TD></TR>"
            if !notes.isEmpty {
                label += "<TR><TD><FONT POINT-SIZE=\"8.5\" COLOR=\"\(noteColor.hex)\">\(html(notes.joined(separator: "  ·  ")))</FONT></TD></TR>"
            }
            label += "</TABLE>>"
            let width = state.exitCode != nil ? 2.4 : 1.5
            out.append("  s\(i) [id=\"s\(i)\", label=\(label), color=\"\(c.hex)\", fillcolor=\"\(page.blended(with: c, mix).hex)\", penwidth=\(width), tooltip=\(quote(state.name))];")
        }

        // Only one edge into each terminal state constrains ranking, so
        // terminals don't drag the layout around (same trick as `flow chart`).
        var anchors: [String: Int] = [:]
        for state in states {
            for transition in state.transitions {
                if let target = transition.target, let t = index[target], states[t].exitCode != nil {
                    anchors[target] = transition.line
                }
            }
        }

        var ghosts: [String: Int] = [:]
        for (i, state) in states.enumerated() {
            for transition in state.transitions {
                guard let target = transition.target else { continue }
                var condition = transition.condition.isEmpty ? "always" : transition.condition
                if let wait = transition.wait { condition += "\nwait \(wait)" }
                var attributes = [
                    "id=\"t\(transition.line)\"",
                    "tooltip=\(quote(condition))",
                ]
                if labels { attributes.append("label=\(quote(wrap(condition)))") }
                let destination: String
                if let t = index[target] {
                    destination = "s\(t)"
                    attributes.append("color=\"\(color(target).hex)\"")
                    if let anchor = anchors[target], anchor != transition.line { attributes.append("constraint=false") }
                } else {
                    let line = ghosts[target] ?? transition.goLine ?? transition.line
                    if ghosts[target] == nil {
                        ghosts[target] = line
                        out.append("  g\(line) [id=\"g\(line)\", label=\(quote(target + "?")), style=\"rounded,dashed\", color=\"\(theme.error.hex)\", fontcolor=\"\(theme.error.hex)\", fillcolor=\"transparent\", tooltip=\(quote("No state named \(target)"))];")
                    }
                    destination = "g\(line)"
                    attributes.append("color=\"\(theme.error.hex)\"")
                    attributes.append("fontcolor=\"\(theme.error.hex)\"")
                }
                if transition.wait != nil { attributes.append("style=\"dashed\"") }
                out.append("  s\(i) -> \(destination) [\(attributes.joined(separator: ", "))];")
            }
        }
        out.append("}")
        return out.joined(separator: "\n") + "\n"
    }

    private static func wrap(_ text: String, width: Int = 20, maxLines: Int = 3) -> String {
        var lines: [String] = []
        for paragraph in text.components(separatedBy: "\n") {
            var line = ""
            for word in paragraph.split(separator: " ") {
                if line.isEmpty {
                    line = String(word)
                } else if line.count + 1 + word.count <= width {
                    line += " " + word
                } else {
                    lines.append(line)
                    line = String(word)
                }
            }
            lines.append(line)
        }
        if lines.count > maxLines {
            lines = Array(lines.prefix(maxLines))
            lines[maxLines - 1] = String(lines[maxLines - 1].prefix(width - 1)) + "…"
        }
        return lines.joined(separator: "\n")
    }

    private static func quote(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    private static func html(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: Graphviz

    static func resolveDot() -> URL? {
        let fm = FileManager.default
        for path in ["/opt/homebrew/bin/dot", "/usr/local/bin/dot", "/usr/bin/dot"] where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v dot"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return fm.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    /// Runs `dot -Tsvg`, returning the SVG element or an error message.
    static func svg(_ source: String, dot binary: URL) async -> Result<String, Error> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = binary
                process.arguments = ["-Tsvg"]
                let input = Pipe()
                let output = Pipe()
                let errors = Pipe()
                process.standardInput = input
                process.standardOutput = output
                process.standardError = errors
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: .failure(error))
                    return
                }
                input.fileHandleForWriting.write(Data(source.utf8))
                try? input.fileHandleForWriting.close()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let errorData = errors.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let text = String(decoding: data, as: UTF8.self)
                if process.terminationStatus == 0, let start = text.range(of: "<svg") {
                    continuation.resume(returning: .success(String(text[start.lowerBound...])))
                } else {
                    let message = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(returning: .failure(GraphError(message: message.isEmpty ? "dot failed" : message)))
                }
            }
        }
    }

    /// Width of a rendered SVG in CSS pixels.
    static func width(of svg: String) -> CGFloat? {
        guard let match = svg.firstMatch(of: #/width="([0-9.]+)pt"/#), let points = Double(match.1) else { return nil }
        return CGFloat(points) * 4 / 3
    }

    struct GraphError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }
}
