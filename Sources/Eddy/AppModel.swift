import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum SidebarItem: Hashable {
    case file(URL)
    case state(URL, String)
}

struct FileNode: Identifiable, Hashable {
    var url: URL
    var id: URL { url }
    var name: String
    var children: [FileNode]?
}

struct SidebarRoot: Identifiable, Hashable {
    var url: URL
    var id: URL { url }
    var title: String
    var nodes: [FileNode]
}

extension UTType {
    static let flowFile = UTType(filenameExtension: "flow", conformingTo: .yaml) ?? .yaml
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    private static let defaults = UserDefaults.standard

    // MARK: Preferences

    var appearance: AppearanceMode { didSet { store(appearance.rawValue, "appearance"); applyAppearance() } }
    var lightThemeID: String { didSet { store(lightThemeID, "lightTheme") } }
    var darkThemeID: String { didSet { store(darkThemeID, "darkTheme") } }
    var fontName: String { didSet { store(fontName, "fontName") } }
    var fontSize: Double { didSet { store(fontSize, "fontSize") } }
    var lineSpacing: Double { didSet { store(lineSpacing, "lineSpacing") } }
    var columnWidth: Int { didSet { store(columnWidth, "columnWidth") } }
    var proseFont: ProseFont { didSet { store(proseFont.rawValue, "proseFont") } }
    var showGuides: Bool { didSet { store(showGuides, "showGuides") } }
    var highlightCurrentLine: Bool { didSet { store(highlightCurrentLine, "highlightCurrentLine") } }
    var focusMode: FocusMode { didSet { store(focusMode.rawValue, "focusMode") } }
    var typewriter: Bool { didSet { store(typewriter, "typewriter") } }
    var fadeChrome: Bool { didSet { store(fadeChrome, "fadeChrome") } }
    var liveValidation: Bool { didSet { store(liveValidation, "liveValidation") } }
    var autosave: Bool { didSet { store(autosave, "autosave") } }
    var flowBinaryPath: String { didSet { store(flowBinaryPath, "flowBinaryPath"); resolvedBinary = nil } }
    var rootPaths: [String] { didSet { store(rootPaths, "rootPaths"); refreshTree() } }
    var showGraph: Bool { didSet { store(showGraph, "showGraph") } }
    var graphWidth: Double { didSet { store(graphWidth, "graphWidth") } }
    var graphLabels: GraphLabels { didSet { store(graphLabels.rawValue, "graphLabels") } }

    // MARK: State

    var systemDark = false
    var chromeHidden = false
    var columnVisibility = NavigationSplitViewVisibility.all
    var roots: [SidebarRoot] = []
    var looseFiles: [URL] = []
    var documents: [URL: FlowDocument] = [:]
    var current: FlowDocument?
    var sidebarSelection: SidebarItem?
    var filter = ""
    var caretLine = 1
    var caretColumn = 1
    var caretState: String?
    var lastError: String?

    @ObservationIgnored weak var editor: EditorCoordinator?
    @ObservationIgnored private var cachedStyles: (key: String, styles: Styles)?
    @ObservationIgnored private var styleGeneration = 0
    @ObservationIgnored private var resolvedBinary: URL??
    @ObservationIgnored private var watchers: [DispatchSourceFileSystemObject] = []
    @ObservationIgnored private var suppressSelectionHandling = false

    private init() {
        let d = Self.defaults
        appearance = AppearanceMode(rawValue: d.string(forKey: "appearance") ?? "") ?? .system
        lightThemeID = d.string(forKey: "lightTheme") ?? Theme.paper.id
        darkThemeID = d.string(forKey: "darkTheme") ?? Theme.synthwave.id
        fontName = d.string(forKey: "fontName") ?? ""
        fontSize = d.object(forKey: "fontSize") as? Double ?? 14
        lineSpacing = d.object(forKey: "lineSpacing") as? Double ?? 1.55
        columnWidth = d.object(forKey: "columnWidth") as? Int ?? 84
        proseFont = ProseFont(rawValue: d.string(forKey: "proseFont") ?? "") ?? .mono
        showGuides = d.object(forKey: "showGuides") as? Bool ?? true
        highlightCurrentLine = d.object(forKey: "highlightCurrentLine") as? Bool ?? true
        focusMode = FocusMode(rawValue: d.string(forKey: "focusMode") ?? "") ?? .off
        typewriter = d.object(forKey: "typewriter") as? Bool ?? false
        fadeChrome = d.object(forKey: "fadeChrome") as? Bool ?? true
        liveValidation = d.object(forKey: "liveValidation") as? Bool ?? true
        autosave = d.object(forKey: "autosave") as? Bool ?? false
        flowBinaryPath = d.string(forKey: "flowBinaryPath") ?? ""
        rootPaths = d.stringArray(forKey: "rootPaths") ?? ["~/flows", "~/Projects/flow"]
        showGraph = d.object(forKey: "showGraph") as? Bool ?? true
        graphWidth = d.object(forKey: "graphWidth") as? Double ?? 440
        graphLabels = GraphLabels(rawValue: d.string(forKey: "graphLabels") ?? "") ?? .automatic
        looseFiles = (d.stringArray(forKey: "looseFiles") ?? []).map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        systemDark = Self.readSystemDark()
        refreshTree()
        applyAppearance()
    }

    private func store(_ value: Any, _ key: String) { Self.defaults.set(value, forKey: key) }

    // MARK: Appearance

    var isDark: Bool {
        switch appearance {
        case .system: systemDark
        case .light: false
        case .dark: true
        }
    }

    var theme: Theme {
        let id = isDark ? darkThemeID : lightThemeID
        return Theme.named(id) ?? (isDark ? .synthwave : .paper)
    }

    static func readSystemDark() -> Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle")?.lowercased() == "dark"
    }

    func applyAppearance() {
        switch appearance {
        case .system: NSApp?.appearance = nil
        case .light: NSApp?.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp?.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// Picks a theme and makes sure it is the one on screen.
    func choose(_ theme: Theme) {
        if theme.isDark { darkThemeID = theme.id } else { lightThemeID = theme.id }
        if theme.isDark != isDark { appearance = theme.isDark ? .dark : .light }
    }

    func cycleTheme(_ step: Int) {
        let list = isDark ? Theme.dark : Theme.light
        let index = list.firstIndex { $0.id == theme.id } ?? 0
        choose(list[(index + step + list.count) % list.count])
    }

    var editorConfig: EditorConfig {
        EditorConfig(
            themeID: theme.id, fontName: fontName, fontSize: CGFloat(fontSize),
            lineSpacing: CGFloat(lineSpacing), columnWidth: columnWidth, prose: proseFont,
            guides: showGuides, currentLine: highlightCurrentLine, focus: focusMode, typewriter: typewriter
        )
    }

    func styles(for config: EditorConfig) -> Styles {
        if let cachedStyles, cachedStyles.key == config.styleKey { return cachedStyles.styles }
        styleGeneration += 1
        let theme = Theme.named(config.themeID) ?? .paper
        let styles = Styles(theme: theme, config: config, generation: styleGeneration)
        cachedStyles = (config.styleKey, styles)
        return styles
    }

    var currentStyles: Styles { styles(for: editorConfig) }

    func adjustFontSize(_ delta: Double) {
        fontSize = delta == 0 ? 14 : min(28, max(10, fontSize + delta))
    }

    // MARK: File tree

    private static let skippedDirectories: Set<String> = [
        "runs", "node_modules", "dist", "build", ".venv", "venv", "stress-runs", "__pycache__",
        "src-tauri", "target", "site-packages",
    ]
    private static let extensions: Set<String> = ["flow", "yaml", "yml"]

    func refreshTree() {
        let fm = FileManager.default
        roots = rootPaths.compactMap { path in
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return nil }
            return SidebarRoot(url: url, title: (url.path as NSString).abbreviatingWithTildeInPath, nodes: Self.scan(url, depth: 3))
        }
        watch()
    }

    private static func scan(_ dir: URL, depth: Int) -> [FileNode] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [FileNode] = []
        var dirs: [FileNode] = []
        for item in items {
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                guard depth > 0, !skippedDirectories.contains(item.lastPathComponent) else { continue }
                let children = scan(item, depth: depth - 1)
                if !children.isEmpty {
                    dirs.append(FileNode(url: item, name: item.lastPathComponent, children: children))
                }
            } else if extensions.contains(item.pathExtension.lowercased()) {
                files.append(FileNode(url: item.standardizedFileURL, name: item.lastPathComponent, children: nil))
            }
        }
        let order: (FileNode, FileNode) -> Bool = { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return files.sorted(by: order) + dirs.sorted(by: order)
    }

    private func watch() {
        watchers.forEach { $0.cancel() }
        watchers = roots.compactMap { root in
            let fd = Darwin.open(root.url.path, O_EVTONLY)
            guard fd >= 0 else { return nil }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.refreshTreeSoon() }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            return source
        }
    }

    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    private func refreshTreeSoon() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let before = roots
            refreshTreeKeepingWatchers()
            if before != roots { checkDisk() }
        }
    }

    private func refreshTreeKeepingWatchers() {
        let fm = FileManager.default
        roots = rootPaths.compactMap { path in
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
            guard fm.fileExists(atPath: url.path) else { return nil }
            return SidebarRoot(url: url, title: (url.path as NSString).abbreviatingWithTildeInPath, nodes: Self.scan(url, depth: 3))
        }
    }

    func filtered(_ nodes: [FileNode]) -> [FileNode] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return nodes }
        return nodes.compactMap { node in
            if let children = node.children {
                let kept = filtered(children)
                return kept.isEmpty ? nil : FileNode(url: node.url, name: node.name, children: kept)
            }
            return node.name.localizedCaseInsensitiveContains(query) ? node : nil
        }
    }

    func isInRoots(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return roots.contains { path.hasPrefix($0.url.path + "/") }
    }

    func addRoot(_ url: URL) {
        let path = (url.standardizedFileURL.path as NSString).abbreviatingWithTildeInPath
        if !rootPaths.contains(path) { rootPaths.append(path) }
    }

    // MARK: Documents

    func document(for url: URL) -> FlowDocument? {
        let url = url.standardizedFileURL
        if let existing = documents[url] { return existing }
        do {
            let doc = try FlowDocument(url: url)
            documents[url] = doc
            return doc
        } catch {
            lastError = "Couldn’t open \(url.lastPathComponent): \(error.localizedDescription)"
            return nil
        }
    }

    func open(_ url: URL, state: String? = nil) {
        let url = url.standardizedFileURL
        guard let doc = document(for: url) else { return }
        if !isInRoots(url), !looseFiles.contains(url) {
            looseFiles.append(url)
            store(looseFiles.map(\.path), "looseFiles")
        }
        if current !== doc {
            current = doc
            store(url.path, "lastFile")
            if doc.validation == .unknown { scheduleValidation(doc, delay: .zero) }
        }
        suppressSelectionHandling = true
        sidebarSelection = state.map { .state(url, $0) } ?? .file(url)
        suppressSelectionHandling = false
        if let state { editor?.reveal(state: state) }
    }

    func handleSidebarSelection(_ item: SidebarItem?) {
        guard !suppressSelectionHandling, let item else { return }
        switch item {
        case .file(let url):
            open(url)
        case .state(let url, let name):
            open(url, state: name)
        }
    }

    func restoreLastFile() {
        guard current == nil, let path = Self.defaults.string(forKey: "lastFile"),
              FileManager.default.fileExists(atPath: path) else { return }
        open(URL(fileURLWithPath: path))
    }

    func closeLoose(_ url: URL) {
        looseFiles.removeAll { $0 == url }
        store(looseFiles.map(\.path), "looseFiles")
    }

    var dirtyDocuments: [FlowDocument] { documents.values.filter(\.isDirty) }

    func save(_ doc: FlowDocument? = nil) {
        guard let doc = doc ?? current else { return }
        do {
            try doc.save()
            scheduleValidation(doc, delay: .zero)
        } catch {
            lastError = "Couldn’t save \(doc.name): \(error.localizedDescription)"
        }
    }

    func saveAll() { dirtyDocuments.forEach { save($0) } }

    func revert(_ doc: FlowDocument? = nil) {
        guard let doc = doc ?? current else { return }
        doc.reload(styles: currentStyles)
        editor?.documentReloaded(doc)
        scheduleValidation(doc, delay: .zero)
    }

    /// Picks up edits made by other tools while we were away.
    func checkDisk() {
        for doc in documents.values where doc.isStaleOnDisk {
            if doc.isDirty {
                doc.changedOnDisk = true
            } else {
                doc.reload(styles: currentStyles)
                editor?.documentReloaded(doc)
                scheduleValidation(doc, delay: .zero)
            }
        }
    }

    func textDidChange(_ doc: FlowDocument) {
        doc.pendingWork?.cancel()
        doc.pendingWork = Task { @MainActor [weak self, weak doc] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, let self, let doc else { return }
            if self.autosave, doc.isDirty, !doc.changedOnDisk { self.save(doc) }
            if self.liveValidation { await self.validate(doc) }
        }
    }

    // MARK: Graph

    @ObservationIgnored private var resolvedDot: URL??

    var dotBinary: URL? {
        if let resolvedDot { return resolvedDot }
        let found = FlowGraph.resolveDot()
        resolvedDot = .some(found)
        return found
    }

    /// Graph pane width, leaving the editor at least a comfortable column.
    func clampedGraphWidth(in total: CGFloat) -> CGFloat {
        let upper = max(240, total - 420)
        return min(max(240, CGFloat(graphWidth)), upper)
    }

    // MARK: Flow CLI

    var flowBinary: URL? {
        if let resolvedBinary { return resolvedBinary }
        let found = FlowCLI.resolve(custom: flowBinaryPath)
        resolvedBinary = .some(found)
        return found
    }

    func scheduleValidation(_ doc: FlowDocument, delay: Duration) {
        Task { @MainActor in
            if delay > .zero { try? await Task.sleep(for: delay) }
            await validate(doc)
        }
    }

    func validate(_ doc: FlowDocument) async {
        guard let binary = flowBinary else {
            doc.validation = .unavailable("Couldn’t find the flow command. Set its path in Settings.")
            return
        }
        if case .unknown = doc.validation { doc.validation = .running }
        let file: URL
        if doc.isDirty {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("eddy-validate", isDirectory: true)
                .appendingPathComponent(String(UInt(bitPattern: doc.url.path.hashValue), radix: 36), isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            file = dir.appendingPathComponent(doc.url.lastPathComponent)
            do { try doc.text.write(to: file, atomically: true, encoding: .utf8) } catch { return }
        } else {
            file = doc.url
        }
        let result = await FlowCLI.validate(binary: binary, file: file)
        if result != doc.validation { doc.validation = result }
        if doc === current { editor?.validationChanged() }
    }

    func validateNow() {
        guard let current else { return }
        Task { await validate(current) }
    }

    func openChart() {
        guard let doc = current, let binary = flowBinary else { NSSound.beep(); return }
        if doc.isDirty { save(doc) }
        let theme = isDark ? "dark" : "light"
        Task {
            let (status, output) = await FlowCLI.run(binary, ["chart", doc.url.path, "--theme", theme], cwd: doc.url.deletingLastPathComponent())
            if status != 0 {
                await MainActor.run { self.lastError = output.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
        }
    }

    func revealInFinder() {
        guard let doc = current else { return }
        NSWorkspace.shared.activateFileViewerSelecting([doc.url])
    }

    // MARK: Panels

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.flowFile, .yaml]
        panel.allowsMultipleSelection = true
        panel.directoryURL = roots.first?.url
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach { open($0) }
    }

    func showAddFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add to Sidebar"
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach { addRoot($0) }
    }

    func showNewFlowPanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.flowFile]
        panel.nameFieldStringValue = "new-flow.flow"
        panel.directoryURL = roots.first?.url
        panel.prompt = "Create"
        panel.message = "Name your new flow"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let name = url.deletingPathExtension().lastPathComponent
        let template = """
        #!/usr/bin/env flow
        flow:
          name: \(name)
          version: 2
          thinking: medium
          description: >-
            One or two sentences on what this flow does and when to use it.
          args:
            target:
              help: What the flow should work on

        work:
          start: true
          prompt: |
            Describe the first step. Refer to arguments like {{target}}.
          transitions:
            - if: the work is complete
              go: done
            - if: a human decision is needed
              go: needs-human

        done:
          exit: 0

        needs-human:
          exit: 2
          prompt: Record the concrete blocker and the smallest useful next action.

        """
        do {
            try template.write(to: url, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            refreshTree()
            open(url)
        } catch {
            lastError = "Couldn’t create \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    // MARK: Chrome

    func typingStarted() {
        if fadeChrome, !chromeHidden { chromeHidden = true }
    }

    func pointerMoved() {
        if chromeHidden { chromeHidden = false }
    }
}
