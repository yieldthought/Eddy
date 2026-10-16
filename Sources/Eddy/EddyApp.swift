import AppKit
import SwiftUI

@main
struct EddyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let model = AppModel.shared

    var body: some Scene {
        Window("Eddy", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 640, minHeight: 420)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1200, height: 840)
        .commands { EddyCommands(model: model) }

        Settings {
            SettingsView().environment(model)
        }
    }
}

struct EddyCommands: Commands {
    let model: AppModel

    private func send(_ action: Selector) {
        NSApp.sendAction(action, to: nil, from: nil)
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Flow…") { model.showNewFlowPanel() }
                .keyboardShortcut("n")
            Button("Open…") { model.showOpenPanel() }
                .keyboardShortcut("o")
            Button("Add Folder to Sidebar…") { model.showAddFolderPanel() }
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { model.save() }
                .keyboardShortcut("s")
                .disabled(model.current == nil)
            Button("Save All") { model.saveAll() }
                .keyboardShortcut("s", modifiers: [.command, .option])
            Button("Revert to Saved") { model.revert() }
                .disabled(model.current?.isDirty != true)
            Divider()
            Button("Reveal in Finder") { model.revealInFinder() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.current == nil)
        }
        TextEditingCommands()
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Toggle Comment") { send(#selector(EddyTextView.toggleComment(_:))) }
                .keyboardShortcut("/")
            Button("Indent") { send(#selector(EddyTextView.indentSelection(_:))) }
                .keyboardShortcut("]")
            Button("Outdent") { send(#selector(EddyTextView.outdentSelection(_:))) }
                .keyboardShortcut("[")
        }
        SidebarCommands()
        CommandGroup(after: .sidebar) {
            Divider()
            Picker("Focus", selection: Binding(get: { model.focusMode }, set: { model.focusMode = $0 })) {
                ForEach(FocusMode.allCases) { Text($0.label).tag($0) }
            }
            Button("Cycle Focus") {
                let all = FocusMode.allCases
                model.focusMode = all[(all.firstIndex(of: model.focusMode)! + 1) % all.count]
            }
            .keyboardShortcut("f", modifiers: [.command, .option])
            Toggle("Show Graph", isOn: Binding(get: { model.showGraph }, set: { model.showGraph = $0 }))
                .keyboardShortcut("g", modifiers: [.command, .option])
            Picker("Graph Labels", selection: Binding(get: { model.graphLabels }, set: { model.graphLabels = $0 })) {
                ForEach(GraphLabels.allCases) { Text($0.label).tag($0) }
            }
            Toggle("Typewriter Scrolling", isOn: Binding(get: { model.typewriter }, set: { model.typewriter = $0 }))
                .keyboardShortcut("t", modifiers: [.command, .option])
            Toggle("Indent Guides", isOn: Binding(get: { model.showGuides }, set: { model.showGuides = $0 }))
            Toggle("Highlight Current Line", isOn: Binding(get: { model.highlightCurrentLine }, set: { model.highlightCurrentLine = $0 }))
            Divider()
            Button("Bigger") { model.adjustFontSize(1) }
                .keyboardShortcut("=")
            Button("Smaller") { model.adjustFontSize(-1) }
                .keyboardShortcut("-")
            Button("Actual Size") { model.adjustFontSize(0) }
                .keyboardShortcut("0")
            Divider()
        }
        CommandMenu("Theme") {
            Picker("Appearance", selection: Binding(get: { model.appearance }, set: { model.appearance = $0 })) {
                ForEach(AppearanceMode.allCases) { Text($0.label).tag($0) }
            }
            Divider()
            Section("Light") {
                ForEach(Theme.light) { theme in
                    Toggle(theme.name, isOn: Binding(get: { model.theme.id == theme.id }, set: { _ in model.choose(theme) }))
                }
            }
            Section("Dark") {
                ForEach(Theme.dark) { theme in
                    Toggle(theme.name, isOn: Binding(get: { model.theme.id == theme.id }, set: { _ in model.choose(theme) }))
                }
            }
            Divider()
            Button("Next Theme") { model.cycleTheme(1) }
                .keyboardShortcut("t", modifiers: [.command, .control])
            Button("Previous Theme") { model.cycleTheme(-1) }
                .keyboardShortcut("t", modifiers: [.command, .control, .shift])
        }
        CommandMenu("Flow") {
            Button("Validate") { model.validateNow() }
                .keyboardShortcut("b")
                .disabled(model.current == nil)
            Button("Open Chart") { model.openChart() }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(model.current == nil)
            Divider()
            Button("Next State") { model.editor?.jumpState(1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Button("Previous State") { model.editor?.jumpState(-1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var monitor: Any?
    private var appearanceObservation: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel.shared
        model.applyAppearance()

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel]) { event in
            MainActor.assumeIsolated { AppModel.shared.pointerMoved() }
            return event
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { AppModel.shared.systemDark = AppModel.readSystemDark() }
        }
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { app, _ in
            MainActor.assumeIsolated {
                let model = AppModel.shared
                guard model.appearance == .system else { return }
                let dark = app.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                if model.systemDark != dark { model.systemDark = dark }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                AppModel.shared.refreshTree()
                AppModel.shared.checkDisk()
            }
        }
        DispatchQueue.main.async { model.restoreLastFile() }
        Snapshot.runIfRequested()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach { AppModel.shared.open($0) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = AppModel.shared
        let dirty = model.dirtyDocuments
        guard !dirty.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = dirty.count == 1
            ? "Save changes to “\(dirty[0].name)”?"
            : "Save changes to \(dirty.count) flows?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: dirty.count == 1 ? "Save" : "Save All")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            model.saveAll()
            return model.dirtyDocuments.isEmpty ? .terminateNow : .terminateCancel
        case .alertThirdButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }
}
