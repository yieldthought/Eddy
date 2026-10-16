import AppKit
import WebKit

/// Development aid: `EDDY_SNAPSHOT=<dir>` renders the window to PNGs (one per
/// theme in `EDDY_THEMES`) and quits. Optional `EDDY_FILE`, `EDDY_STATE`,
/// `EDDY_FOCUS`.
@MainActor
enum Snapshot {
    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["EDDY_SNAPSHOT"] else { return }
        let model = AppModel.shared
        let domain = Bundle.main.bundleIdentifier ?? "local.eddy.editor"
        let savedDefaults = UserDefaults.standard.persistentDomain(forName: domain)
        Task { @MainActor in
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? await Task.sleep(for: .seconds(1.5))
            let main = NSApp.windows.first { $0.isVisible && !($0 is NSPanel) }
            let wasFullScreen = main?.styleMask.contains(.fullScreen) == true
            if wasFullScreen, env["EDDY_WINDOWED"] != nil {
                main?.toggleFullScreen(nil)
                try? await Task.sleep(for: .seconds(2))
            }
            if let file = env["EDDY_FILE"] { model.open(URL(fileURLWithPath: file)) }
            if let graph = env["EDDY_GRAPH"] { model.showGraph = graph != "0" }
            if env["EDDY_SIDEBAR"] == "0" { model.columnVisibility = .detailOnly }
            if let focus = env["EDDY_FOCUS"].flatMap(FocusMode.init(rawValue:)) { model.focusMode = focus }
            try? await Task.sleep(for: .seconds(0.8))
            if let state = env["EDDY_STATE"], let url = model.current?.url { model.open(url, state: state) }
            if let text = env["EDDY_TYPE"] { model.editor?.debugType(text) }
            if let id = env["EDDY_GRAPH_CLICK"], let root = NSApp.windows.first?.contentView,
               let web = webViews(in: root).first {
                try? await Task.sleep(for: .seconds(1.5))
                _ = try? await web.evaluateJavaScript("document.getElementById('\(id)')?.dispatchEvent(new MouseEvent('click', {bubbles: true})); 1")
                try? await Task.sleep(for: .seconds(0.8))
                print("after graph click: state=\(model.caretState ?? "-") line=\(model.caretLine)")
            }
            if env["EDDY_SAVE"] != nil { model.save() }
            let themes = env["EDDY_THEMES"]?.split(separator: ",").map(String.init) ?? [model.theme.id]
            for id in themes {
                if let theme = Theme.named(id) { model.choose(theme) }
                try? await Task.sleep(for: .seconds(1.2))
                if let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && !($0 is NSPanel) }) {
                    await write(window, to: "\(dir)/\(id).png")
                    if env["EDDY_DUMP"] != nil, let root = window.contentView?.superview {
                        var lines: [String] = []
                        dump(root, depth: 0, into: &lines)
                        try? lines.joined(separator: "\n").write(toFile: "\(dir)/\(id)-views.txt", atomically: true, encoding: .utf8)
                        var windows: [String] = []
                        for w in NSApp.windows {
                            windows.append("\(type(of: w)) frame=\(w.frame) visible=\(w.isVisible) level=\(w.level.rawValue) parent=\(w.parent.map { "\(type(of: $0))" } ?? "-") toolbar=\(w.toolbar.map { "\(type(of: $0)) visible=\($0.isVisible) items=\($0.items.count)" } ?? "-") style=\(w.styleMask.rawValue) tbTransparent=\(w.titlebarAppearsTransparent) titleVis=\(w.titleVisibility.rawValue)")
                            if let frame = w.contentView?.superview, w !== window {
                                var sub: [String] = []
                                dump(frame, depth: 1, into: &sub)
                                windows += sub
                            }
                        }
                        if let host = window.standardWindowButton(.closeButton)?.window {
                            windows.append("-- close button window: \(type(of: host)) frame=\(host.frame) visible=\(host.isVisible) alpha=\(host.alphaValue) occlusionVisible=\(host.occlusionState.contains(.visible)) screen=\(host.screen?.frame ?? .zero)")
                        }
                        if let titlebar = window.standardWindowButton(.closeButton)?.superview?.superview {
                            windows.append("-- titlebar ancestry of close button:")
                            var v: NSView? = window.standardWindowButton(.closeButton)
                            while let view = v { windows.append("  \(type(of: view)) \(view.convert(view.bounds, to: nil)) hidden=\(view.isHidden) alpha=\(view.alphaValue)"); v = view.superview }
                            var sub: [String] = []
                            dump(titlebar, depth: 1, into: &sub)
                            windows += sub
                            if let layer = titlebar.layer {
                                windows.append("-- titlebar layers:")
                                var layerLines: [String] = []
                                dumpLayer(layer, root: layer, depth: 1, into: &layerLines)
                                windows += layerLines
                            }
                        }
                        try? windows.joined(separator: "\n").write(toFile: "\(dir)/\(id)-windows.txt", atomically: true, encoding: .utf8)
                        if let layer = root.layer {
                            var layerLines: [String] = []
                            dumpLayer(layer, root: layer, depth: 0, into: &layerLines)
                            try? layerLines.joined(separator: "\n").write(toFile: "\(dir)/\(id)-layers.txt", atomically: true, encoding: .utf8)
                        }
                    }
                }
            }
            if wasFullScreen, main?.styleMask.contains(.fullScreen) == false {
                main?.toggleFullScreen(nil)
                try? await Task.sleep(for: .seconds(2))
            }
            if let savedDefaults {
                UserDefaults.standard.setPersistentDomain(savedDefaults, forName: domain)
            } else {
                UserDefaults.standard.removePersistentDomain(forName: domain)
            }
            UserDefaults.standard.synchronize()
            exit(0)
        }
    }

    private static func dump(_ view: NSView, depth: Int, into lines: inout [String]) {
        guard !view.isHidden, depth < 14 else { return }
        var note = ""
        if let effect = view as? NSVisualEffectView { note += " material=\(effect.material.rawValue) blending=\(effect.blendingMode.rawValue)" }
        if let color = view.layer?.backgroundColor { note += " bg=\(color)" }
        let frame = view.convert(view.bounds, to: nil)
        lines.append(String(repeating: "  ", count: depth) + "\(type(of: view)) \(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))\(note)")
        for sub in view.subviews { dump(sub, depth: depth + 1, into: &lines) }
    }

    private static func dumpLayer(_ layer: CALayer, root: CALayer, depth: Int, into lines: inout [String]) {
        guard depth < 18 else { return }
        let frame = layer.convert(layer.bounds, to: root)
        var note = ""
        if let name = layer.name { note += " name=\(name)" }
        if let color = layer.backgroundColor { note += " bg=\(color.components?.map { String(format: "%.2f", $0) }.joined(separator: ",") ?? "")" }
        if layer.isHidden { note += " hidden" }
        if layer.opacity < 1 { note += " opacity=\(layer.opacity)" }
        if let delegate = layer.delegate { note += " delegate=\(type(of: delegate))" }
        lines.append(String(repeating: " ", count: depth) + "\(type(of: layer)) \(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))\(note)")
        for sub in layer.sublayers ?? [] { dumpLayer(sub, root: root, depth: depth + 1, into: &lines) }
    }

    private static func write(_ window: NSWindow, to path: String) async {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        // Web views render out of process; paint their own snapshots on top.
        if let web = webViews(in: view).first, let image = try? await web.takeSnapshot(configuration: nil) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(in: web.convert(web.bounds, to: view), from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
        }
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    private static func webViews(in view: NSView) -> [WKWebView] {
        if let web = view as? WKWebView { return [web] }
        return view.subviews.flatMap(webViews)
    }
}
