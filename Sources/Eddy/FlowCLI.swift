import Foundation

/// Thin wrapper around the `flow` command-line tool.
enum FlowCLI {
    /// Finds the `flow` executable: an explicit path, the Flow repo's venv,
    /// or whatever a login shell resolves.
    static func resolve(custom: String) -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var candidates: [String] = []
        if !custom.isEmpty { candidates.append((custom as NSString).expandingTildeInPath) }
        candidates += [
            home.appendingPathComponent("Projects/flow/.venv/bin/flow").path,
            home.appendingPathComponent(".local/bin/flow").path,
            "/opt/homebrew/bin/flow",
            "/usr/local/bin/flow",
        ]
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        if let shell = loginShellLookup(), fm.isExecutableFile(atPath: shell) {
            return URL(fileURLWithPath: shell)
        }
        return nil
    }

    private static func loginShellLookup() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v flow"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasPrefix("/") ? path : nil
    }

    static func run(_ binary: URL, _ arguments: [String], cwd: URL? = nil) async -> (status: Int32, output: String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = binary
                process.arguments = arguments
                if let cwd { process.currentDirectoryURL = cwd }
                var env = ProcessInfo.processInfo.environment
                env["NO_COLOR"] = "1"
                env["TERM"] = "dumb"
                process.environment = env
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: (-1, error.localizedDescription))
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: (process.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
        }
    }

    static func validate(binary: URL, file: URL) async -> ValidationState {
        let (status, output) = await run(binary, ["validate", file.path], cwd: file.deletingLastPathComponent())
        if status == -1 { return .unavailable(output) }
        return parse(output, path: file.path)
    }

    static func parse(_ output: String, path: String) -> ValidationState {
        let clean = output.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
        let prefix = path + ": "
        var issues: [ValidationIssue] = []
        var valid = false
        for raw in clean.components(separatedBy: "\n") {
            if raw.hasPrefix(prefix) {
                let body = String(raw.dropFirst(prefix.count))
                if body == "valid" {
                    valid = true
                } else if body.hasPrefix("error: ") {
                    issues.append(ValidationIssue(severity: .error, message: String(body.dropFirst(7))))
                } else if body.hasPrefix("warning: ") {
                    issues.append(ValidationIssue(severity: .warning, message: String(body.dropFirst(9))))
                } else {
                    issues.append(ValidationIssue(severity: .error, message: body))
                }
            } else if !raw.trimmingCharacters(in: .whitespaces).isEmpty, !issues.isEmpty {
                issues[issues.count - 1].message += "\n" + raw
            }
        }
        for index in issues.indices {
            let message = issues[index].message
            if let match = message.firstMatch(of: #/line (\d+), column (\d+)/#), let line = Int(match.1) {
                issues[index].line = line - 1
            }
            if let match = message.firstMatch(of: #/state '([^']+)'/#) {
                issues[index].state = String(match.1)
            }
        }
        if issues.isEmpty { return valid ? .valid : .unavailable(clean.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return .issues(issues)
    }
}
