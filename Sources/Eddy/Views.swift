import AppKit
import SwiftUI

extension Color {
    init(_ ns: NSColor) { self.init(nsColor: ns) }
}

// MARK: - Window

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $model.columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 360)
        } detail: {
            DetailView()
        }
        .toolbar(removing: .sidebarToggle)
        .windowToolbarFullScreenVisibility(.onHover)
        .background(WindowAccessor())
        .alert("Eddy", isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })) {
            Button("OK") { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "")
        }
    }
}

/// Window chrome that SwiftUI doesn't expose. NavigationSplitView insists on a
/// toolbar for its sidebar button, and macOS 26 paints a titlebar material band
/// over the page for it (a solid bar in full screen), so the toolbar is kept hidden.
struct WindowAccessor: NSViewRepresentable {
    final class Coordinator {
        var observation: NSKeyValueObservation?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.acceptsMouseMovedEvents = true
            window.tabbingMode = .disallowed
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.toolbar?.isVisible = false
            context.coordinator.observation = window.toolbar?.observe(\.isVisible) { toolbar, _ in
                if toolbar.isVisible { DispatchQueue.main.async { toolbar.isVisible = false } }
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Sidebar

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.sidebarSelection) {
            ForEach(model.roots) { root in
                Section {
                    ForEach(model.filtered(root.nodes)) { node in
                        NodeRows(node: node)
                    }
                } header: {
                    Text(root.title)
                }
            }
            if !model.looseFiles.isEmpty {
                Section("Opened") {
                    ForEach(model.looseFiles, id: \.self) { url in
                        FileRows(url: url)
                            .contextMenu {
                                Button("Remove from Sidebar") { model.closeLoose(url) }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $model.filter, placement: .sidebar, prompt: "Filter")
        .onChange(of: model.sidebarSelection) { _, item in model.handleSidebarSelection(item) }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 4) {
                Menu {
                    Button("New Flow…") { model.showNewFlowPanel() }
                    Button("Open…") { model.showOpenPanel() }
                    Divider()
                    Button("Add Folder to Sidebar…") { model.showAddFolderPanel() }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("New flow, open, or add a folder")
                Spacer()
                Button { model.refreshTree() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Rescan folders")
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .scrollContentBackground(model.theme.sidebarTint == nil ? .automatic : .hidden)
        .background {
            if let tint = model.theme.sidebarTint {
                Color(tint).ignoresSafeArea()
            }
        }
    }
}

struct NodeRows: View {
    let node: FileNode

    var body: some View {
        if let children = node.children {
            DisclosureGroup {
                ForEach(children) { NodeRows(node: $0) }
            } label: {
                Label(node.name, systemImage: "folder")
            }
        } else {
            FileRows(url: node.url)
        }
    }
}

struct FileRows: View {
    @Environment(AppModel.self) private var model
    let url: URL

    var body: some View {
        let document = model.documents[url]
        let isCurrent = model.current?.url == url
        FileRow(url: url, document: document)
            .tag(SidebarItem.file(url))
        if isCurrent, let document {
            ForEach(document.states) { state in
                StateRow(state: state, theme: model.theme)
                    .tag(SidebarItem.state(url, state.name))
            }
        }
    }
}

struct FileRow: View {
    let url: URL
    let document: FlowDocument?

    var body: some View {
        let isFlow = url.pathExtension == "flow"
        HStack(spacing: 7) {
            Image(systemName: isFlow ? "point.3.connected.trianglepath.dotted" : "doc.plaintext")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(isFlow ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if let document, document.validation.errorCount > 0 {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .imageScale(.small)
                    .help("\(document.validation.errorCount) validation error(s)")
            }
            if document?.isDirty == true {
                Circle().fill(.secondary).frame(width: 6, height: 6).help("Unsaved changes")
            }
        }
    }
}

struct StateRow: View {
    let state: FlowStateInfo
    let theme: Theme

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(Color(theme.stateColor(state.name)))
                .frame(width: 7, height: 7)
            Text(state.name)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if state.isStart {
                Image(systemName: "play.fill").font(.system(size: 8)).foregroundStyle(.secondary).help("Start state")
            }
            if state.waits {
                Image(systemName: "clock").font(.system(size: 9)).foregroundStyle(.secondary).help("Waits before a transition")
            }
            if let code = state.exitCode {
                Text("exit \(code)")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill((code == "0" ? Color.green : Color.orange).opacity(0.18)))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 23)
    }
}

// MARK: - Detail

struct DetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let theme = model.theme
        ZStack {
            PageBackground(theme: theme)
                .overlay(alignment: .top) {
                    // Centre the title over the editor, not across the graph.
                    GeometryReader { proxy in
                        HStack(alignment: .top, spacing: 0) {
                            title(theme).frame(maxWidth: .infinity)
                            if model.showGraph, model.current != nil {
                                Color.clear.frame(width: model.clampedGraphWidth(in: proxy.size.width) + 1, height: 1)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }
                }
                .ignoresSafeArea()
            if let document = model.current {
                GeometryReader { proxy in
                    HStack(spacing: 0) {
                        EditorView(document: document, config: model.editorConfig, model: model)
                            .mask(EdgeFade())
                        if model.showGraph {
                            let width = model.clampedGraphWidth(in: proxy.size.width)
                            SplitHandle(theme: theme, total: proxy.size.width)
                            GraphView(
                                document: document, states: document.states, theme: theme,
                                current: model.caretState, focus: model.focusMode != .off,
                                labels: model.graphLabels, model: model
                            )
                            .mask(EdgeFade())
                            .frame(width: width)
                            .background { Color(theme.text).opacity(theme.isDark ? 0.03 : 0.022).ignoresSafeArea() }
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                }
                .ignoresSafeArea(.container, edges: .bottom)
            } else {
                EmptyState(theme: theme)
            }
        }
        .animation(.easeInOut(duration: 0.28), value: model.showGraph)
        .overlay(alignment: .bottom) {
            if let document = model.current {
                StatusBar(document: document, theme: theme)
                    .opacity(model.chromeHidden ? 0 : 1)
                    .animation(.easeInOut(duration: model.chromeHidden ? 0.9 : 0.25), value: model.chromeHidden)
            }
        }
        .navigationTitle(model.current?.displayName ?? "Eddy")
    }

    @ViewBuilder private func title(_ theme: Theme) -> some View {
        if let document = model.current {
            HStack(spacing: 6) {
                Text(document.displayName)
                if document.isDirty {
                    Text("— Edited").foregroundStyle(Color(theme.muted).opacity(0.7))
                }
            }
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(Color(theme.muted))
            .padding(.top, 7)
            .opacity(model.chromeHidden ? 0 : 1)
            .animation(.easeInOut(duration: model.chromeHidden ? 0.9 : 0.25), value: model.chromeHidden)
            .allowsHitTesting(false)
        }
    }
}

/// Thin divider between editor and graph; drag to resize the graph.
struct SplitHandle: View {
    @Environment(AppModel.self) private var model
    let theme: Theme
    let total: CGFloat
    @State private var start: Double?

    var body: some View {
        Color.clear
            .frame(width: 1)
            .background { Color(theme.guide.withAlphaComponent(min(1, theme.guide.alphaComponent * 2))).ignoresSafeArea() }
            .overlay {
                Color.clear
                    .frame(width: 10)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let base = start ?? model.clampedGraphWidth(in: total)
                                if start == nil { start = base }
                                model.graphWidth = base - value.translation.width
                                model.graphWidth = model.clampedGraphWidth(in: total)
                            }
                            .onEnded { _ in start = nil }
                    )
            }
    }
}

/// Soft fade where text scrolls under the top and bottom edges.
struct EdgeFade: View {
    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 30)
            Rectangle().fill(.black)
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 56)
            Color.clear.frame(height: 22)
        }
    }
}

struct PageBackground: View {
    let theme: Theme

    var body: some View {
        ZStack {
            if let gradient = theme.gradient {
                LinearGradient(colors: [Color(gradient.0), Color(gradient.1)], startPoint: .top, endPoint: .bottom)
            } else {
                Color(theme.background)
            }
            if let glow = theme.glow {
                EllipticalGradient(colors: [Color(glow), .clear], center: .bottom, startRadiusFraction: 0, endRadiusFraction: 0.62)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: theme.id)
    }
}

struct EmptyState: View {
    let theme: Theme

    var body: some View {
        VStack(spacing: 14) {
            Text("eddy")
                .font(.system(size: 34, weight: .ultraLight, design: .serif))
                .foregroundStyle(Color(theme.text).opacity(0.75))
            Text("Choose a flow from the sidebar, or press ⌘N to begin a new one.")
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(Color(theme.muted))
        }
    }
}

// MARK: - Status bar

struct StatusBar: View {
    @Environment(AppModel.self) private var model
    let document: FlowDocument
    let theme: Theme
    @State private var showIssues = false
    @State private var showThemes = false

    var body: some View {
        HStack(spacing: 16) {
            Button {
                withAnimation { model.columnVisibility = model.columnVisibility == .detailOnly ? .all : .detailOnly }
            } label: {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(.plain)
            .help("Show or hide the sidebar (⌃⌘S)")
            if let state = model.caretState {
                HStack(spacing: 6) {
                    Circle().fill(Color(theme.stateColor(state))).frame(width: 6, height: 6)
                    Text(state)
                }
            } else if let name = document.flowName {
                Text(name)
            }
            if document.changedOnDisk {
                Button("Changed on disk · Reload") { model.revert(document) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color(theme.error))
            }
            Spacer()
            validation
            Text("Ln \(model.caretLine), Col \(model.caretColumn)")
                .monospacedDigit()
            Button { model.showGraph.toggle() } label: {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(Color(model.showGraph ? theme.text : theme.muted))
            }
            .buttonStyle(.plain)
            .help("Show or hide the graph (⌥⌘G)")
            Button { showThemes.toggle() } label: {
                Image(systemName: "paintpalette")
            }
            .buttonStyle(.plain)
            .help("Themes (⌃⌘T cycles)")
            .popover(isPresented: $showThemes, arrowEdge: .top) {
                ThemePicker().padding(16)
            }
        }
        .font(.system(size: 11, weight: .medium, design: .rounded))
        .foregroundStyle(Color(theme.muted))
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var validation: some View {
        switch document.validation {
        case .unknown:
            EmptyView()
        case .running:
            Text("Checking…")
        case .valid:
            Label("Valid", systemImage: "checkmark.circle")
                .labelStyle(.titleAndIcon)
                .help("flow validate found no problems")
        case .unavailable(let message):
            Label("No validator", systemImage: "questionmark.circle")
                .help(message)
        case .issues(let issues):
            let errors = issues.filter { $0.severity == .error }.count
            let warnings = issues.count - errors
            Button { showIssues.toggle() } label: {
                Label(
                    errors > 0 ? "\(errors) error\(errors == 1 ? "" : "s")" : "\(warnings) warning\(warnings == 1 ? "" : "s")",
                    systemImage: errors > 0 ? "exclamationmark.triangle.fill" : "exclamationmark.circle"
                )
                .foregroundStyle(Color(errors > 0 ? theme.error : theme.number))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showIssues, arrowEdge: .top) {
                IssueList(issues: issues, document: document) { showIssues = false }
            }
        }
    }
}

struct IssueList: View {
    @Environment(AppModel.self) private var model
    let issues: [ValidationIssue]
    let document: FlowDocument
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("flow validate")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            ForEach(issues) { issue in
                Button {
                    dismiss()
                    if let line = issue.line {
                        model.editor?.jump(toLine: line)
                    } else if let state = issue.state {
                        model.open(document.url, state: state)
                    }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(issue.severity == .error ? .red : .orange)
                        Text(issue.message)
                            .font(.system(size: 12, design: .monospaced))
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(width: 440)
    }
}

// MARK: - Themes

struct ThemePicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            Picker("Appearance", selection: $model.appearance) {
                ForEach(AppearanceMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            group("Light", Theme.light, selected: model.lightThemeID)
            group("Dark", Theme.dark, selected: model.darkThemeID)
        }
        .frame(width: 372)
    }

    private func group(_ title: String, _ themes: [Theme], selected: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(116), spacing: 12), count: 3), alignment: .leading, spacing: 12) {
                ForEach(themes) { theme in
                    ThemeSwatch(theme: theme, selected: theme.id == selected, active: theme.id == model.theme.id) {
                        model.choose(theme)
                    }
                }
            }
        }
    }
}

struct ThemeSwatch: View {
    let theme: Theme
    let selected: Bool
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                ZStack(alignment: .topLeading) {
                    PageBackground(theme: theme)
                    sample.padding(.horizontal, 9).padding(.vertical, 8)
                }
                .frame(width: 116, height: 66)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 2 : 1)
                )
                Text(theme.name)
                    .font(.system(size: 11, weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? .primary : .secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }

    private var sample: some View {
        let font = Font.system(size: 9, design: .monospaced)
        return VStack(alignment: .leading, spacing: 3) {
            (Text("review").foregroundStyle(Color(theme.stateColor("review"))).bold()
                + Text(":").foregroundStyle(Color(theme.muted)))
            (Text("  prompt").foregroundStyle(Color(theme.key))
                + Text(": ").foregroundStyle(Color(theme.muted))
                + Text("|").foregroundStyle(Color(theme.indicator)))
            (Text("    fix ").foregroundStyle(Color(theme.text))
                + Text("{{pr}}").foregroundStyle(Color(theme.template))
                + Text(" `ok`").foregroundStyle(Color(theme.code)))
            (Text("  go").foregroundStyle(Color(theme.key))
                + Text(": ").foregroundStyle(Color(theme.muted))
                + Text("merged").foregroundStyle(Color(theme.stateColor("merged"))))
        }
        .font(font)
    }
}

// MARK: - Settings

struct SettingsView: View {
    var body: some View {
        TabView {
            AppearanceSettings().tabItem { Label("Appearance", systemImage: "paintpalette") }
            EditorSettings().tabItem { Label("Editor", systemImage: "text.alignleft") }
            FlowSettings().tabItem { Label("Flows", systemImage: "point.3.connected.trianglepath.dotted") }
        }
        .frame(width: 540)
    }
}

struct AppearanceSettings: View {
    var body: some View {
        ThemePicker()
            .padding(24)
            .frame(maxWidth: .infinity)
    }
}

struct EditorSettings: View {
    @Environment(AppModel.self) private var model

    private static let monoFonts: [(name: String, label: String)] = {
        let manager = NSFontManager.shared
        var result: [(String, String)] = [("", "SF Mono")]
        for family in manager.availableFontFamilies where !family.hasPrefix(".") {
            guard let font = manager.font(withFamily: family, traits: [], weight: 5, size: 13),
                  font.isFixedPitch, family != "SF Mono" else { continue }
            result.append((font.fontName, family))
        }
        return result
    }()

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Type") {
                Picker("Font", selection: $model.fontName) {
                    ForEach(Self.monoFonts, id: \.name) { Text($0.label).tag($0.name) }
                }
                LabeledContent("Size") {
                    HStack {
                        Slider(value: $model.fontSize, in: 10...24, step: 1)
                        Text("\(Int(model.fontSize)) pt").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                LabeledContent("Line spacing") {
                    HStack {
                        Slider(value: $model.lineSpacing, in: 1.2...2.0, step: 0.05)
                        Text(String(format: "%.2f×", model.lineSpacing)).monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                Stepper("Column width: \(model.columnWidth) characters", value: $model.columnWidth, in: 60...140, step: 4)
                Picker("Prompt prose", selection: $model.proseFont) {
                    ForEach(ProseFont.allCases) { Text($0.label).tag($0) }
                }
            }
            Section("Page") {
                Toggle("Indent guides", isOn: $model.showGuides)
                Toggle("Highlight current line", isOn: $model.highlightCurrentLine)
                Picker("Focus", selection: $model.focusMode) {
                    ForEach(FocusMode.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Typewriter scrolling", isOn: $model.typewriter)
                Toggle("Fade the interface while typing", isOn: $model.fadeChrome)
            }
        }
        .formStyle(.grouped)
        .frame(height: 520)
    }
}

struct FlowSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("flow command") {
                TextField("Path", text: $model.flowBinaryPath, prompt: Text(model.flowBinary?.path ?? "Not found"))
                Toggle("Validate while editing", isOn: $model.liveValidation)
                Toggle("Save automatically", isOn: $model.autosave)
            }
            Section("Sidebar folders") {
                ForEach(model.rootPaths, id: \.self) { path in
                    HStack {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        Text(path)
                        Spacer()
                        Button { model.rootPaths.removeAll { $0 == path } } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button("Add Folder…") { model.showAddFolderPanel() }
            }
        }
        .formStyle(.grouped)
        .frame(height: 420)
    }
}
