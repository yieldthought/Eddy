import AppKit
import SwiftUI
import WebKit

/// Live flow graph beside the editor. Rebuilt from the in-memory buffer
/// whenever the states or transitions change; pan and zoom survive updates.
struct GraphView: NSViewRepresentable {
    let document: FlowDocument
    let states: [FlowStateInfo]
    let theme: Theme
    let current: String?
    let focus: Bool
    let labels: GraphLabels
    let model: AppModel

    func makeCoordinator() -> GraphCoordinator { GraphCoordinator(model: model) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(WeakMessageHandler(context.coordinator), name: "eddy")
        let webView = GraphWebView(frame: .zero, configuration: configuration)
        webView.onResize = { [weak coordinator = context.coordinator] width in coordinator?.paneResized(width) }
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        webView.allowsMagnification = true
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        webView.loadHTMLString(GraphCoordinator.shell, baseURL: nil)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(document: document, states: states, theme: theme, current: current, focus: focus, labels: labels)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: GraphCoordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "eddy")
    }
}

final class GraphWebView: WKWebView {
    var onResize: ((CGFloat) -> Void)?

    override func setFrameSize(_ newSize: NSSize) {
        let changed = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        if changed { onResize?(newSize.width) }
    }
}

private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

@MainActor
final class GraphCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let model: AppModel
    weak var webView: WKWebView?
    private var ready = false
    private var queued: [(String, [String: Any])] = []
    private var renderedKey: Int?
    private var renderTask: Task<Void, Never>?
    private var highlightKey: String?
    private var themeID: String?
    private var document: FlowDocument?
    private var names: [String] = []
    private var states: [FlowStateInfo] = []
    private var theme: Theme?
    private var labels: GraphLabels = .automatic
    /// Pane width when automatic labels were last decided, and the decision.
    private var labelDecision: (width: CGFloat, labels: Bool)?
    private var resizeTask: Task<Void, Never>?

    init(model: AppModel) {
        self.model = model
    }

    func update(document: FlowDocument, states: [FlowStateInfo], theme: Theme, current: String?, focus: Bool, labels: GraphLabels) {
        let switched = document !== self.document
        self.document = document
        self.states = states
        self.theme = theme
        names = states.map(\.name)
        if labels != self.labels {
            self.labels = labels
            renderedKey = nil
        }

        if theme.id != themeID {
            themeID = theme.id
            call("setTheme(vars)", ["vars": [
                "muted": theme.muted.hex,
                "error": theme.error.hex,
                "text": theme.text.hex,
            ]])
        }

        var hasher = Hasher()
        hasher.combine(states)
        hasher.combine(theme.id)
        hasher.combine(labels)
        let key = hasher.finalize()
        if key != renderedKey {
            renderedKey = key
            render(states: states, theme: theme, immediately: switched)
        }

        let index = current.flatMap { name in states.firstIndex { $0.name == name } }
        let highlight = "\(index.map { "s\($0)" } ?? "")|\(focus)"
        if highlight != highlightKey {
            highlightKey = highlight
            call("highlight(id, focus)", ["id": index.map { "s\($0)" } ?? "", "focus": focus])
        }
    }

    private func render(states: [FlowStateInfo], theme: Theme, immediately: Bool) {
        renderTask?.cancel()
        guard !states.isEmpty else {
            call("message(text)", ["text": "No states yet."])
            return
        }
        guard let dot = model.dotBinary else {
            call("message(text)", ["text": "Install Graphviz to see the graph:\nbrew install graphviz"])
            return
        }
        let mode = labels
        let paneWidth = (webView?.bounds.width ?? 440) - 44
        renderTask = Task { @MainActor [weak self] in
            if !immediately { try? await Task.sleep(for: .milliseconds(140)) }
            guard !Task.isCancelled else { return }
            var result = await FlowGraph.svg(FlowGraph.dot(for: states, theme: theme, labels: mode != .never), dot: dot)
            // Automatic: drop condition labels when they'd shrink the graph past legibility.
            if mode == .automatic, case .success(let svg) = result, let width = FlowGraph.width(of: svg) {
                let fits = width * 0.72 <= paneWidth
                self?.labelDecision = (paneWidth, fits)
                if !fits {
                    result = await FlowGraph.svg(FlowGraph.dot(for: states, theme: theme, labels: false), dot: dot)
                }
            }
            guard !Task.isCancelled, let self else { return }
            switch result {
            case .success(let svg):
                self.call("update(svg, fresh)", ["svg": svg, "fresh": immediately])
            case .failure(let error):
                self.call("message(text)", ["text": error.localizedDescription])
            }
        }
    }

    func paneResized(_ width: CGFloat) {
        guard labels == .automatic, let theme, !states.isEmpty else { return }
        resizeTask?.cancel()
        resizeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            if let decision = self.labelDecision, abs(decision.width - (width - 44)) < 40 { return }
            self.render(states: self.states, theme: theme, immediately: true)
        }
    }

    private func call(_ script: String, _ arguments: [String: Any]) {
        guard ready, let webView else {
            queued.append((script, arguments))
            return
        }
        webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) { _ in }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true
        let pending = queued
        queued = []
        pending.forEach { call($0.0, $0.1) }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let id = body["id"] as? String,
              let document, let kind = id.first, let number = Int(id.dropFirst()) else {
            if let body = message.body as? [String: Any], body["id"] as? String == "start",
               let start = document?.states.first(where: \.isStart), let url = document?.url {
                model.open(url, state: start.name)
            }
            return
        }
        switch kind {
        case "s" where number < names.count:
            model.open(document.url, state: names[number])
        case "t", "g":
            model.editor?.jump(toLine: number)
        default:
            break
        }
    }

    static let shell = """
    <!doctype html>
    <html>
    <head>
    <meta charset="utf-8">
    <style>
      :root { --muted: #888; --error: #e66; --text: #ddd; --glow: transparent; }
      html, body { margin: 0; background: transparent; }
      body { font: 12px -apple-system, sans-serif; color: var(--muted); -webkit-user-select: none; cursor: default; }
      #wrap { padding: 30px 22px 72px; }
      #graph svg { display: block; margin: 0 auto; width: 100%; height: auto; overflow: visible; }
      #graph.fresh svg { animation: appear .35s ease-out; }
      @keyframes appear { from { opacity: 0; transform: translateY(4px); } to { opacity: 1; transform: none; } }
      g.node, g.edge { cursor: pointer; transition: opacity .3s ease; }
      g.node > path, g.node > polygon, g.node a > path, g.node a > polygon { transition: stroke-width .2s ease, filter .3s ease; }
      g.edge:hover text, g.node:hover text { text-decoration: underline; text-decoration-color: color-mix(in srgb, currentColor 40%, transparent); }
      g.node.current path, g.node.current polygon { stroke-width: 2.8px; filter: drop-shadow(0 0 7px var(--glow)); }
      g.edge.near path { stroke-width: 1.8px; }
      body.focus g.node:not(.near), body.focus g.edge:not(.near) { opacity: .26; }
      #message { display: none; white-space: pre-line; text-align: center; padding: 80px 24px; line-height: 1.6; }
      body.message #message { display: block; }
      body.message #graph { display: none; }
    </style>
    </head>
    <body>
    <div id="wrap"><div id="graph"></div><div id="message"></div></div>
    <script>
      let currentId = '', focusMode = false;
      function setTheme(vars) {
        for (const [k, v] of Object.entries(vars)) document.documentElement.style.setProperty('--' + k, v);
      }
      function message(text) {
        document.getElementById('message').textContent = text;
        document.body.classList.add('message');
      }
      function update(svg, fresh) {
        document.body.classList.remove('message');
        const graph = document.getElementById('graph');
        graph.classList.toggle('fresh', fresh);
        graph.innerHTML = svg;
        const el = graph.querySelector('svg');
        if (el) {
          const width = parseFloat(el.getAttribute('width')) * 4 / 3;
          el.removeAttribute('width');
          el.removeAttribute('height');
          if (width) {
            el.style.maxWidth = Math.round(width) + 'px';
            el.style.minWidth = Math.round(width * 0.6) + 'px';
          }
          // Graphviz titles hold "from->to"; keep the ends, drop the tooltips.
          el.querySelectorAll('g.edge').forEach(edge => {
            const title = edge.querySelector(':scope > title');
            if (title) edge.dataset.ends = title.textContent.replace('__start', 'start').replace('->', '>');
          });
          el.querySelectorAll('title').forEach(t => t.remove());
        }
        graph.querySelectorAll('g.node, g.edge').forEach(g => {
          g.addEventListener('click', event => {
            event.preventDefault();
            window.webkit.messageHandlers.eddy.postMessage({ id: g.id });
          });
        });
        highlight(currentId, focusMode, false);
      }
      function highlight(id, focus, scroll = true) {
        currentId = id; focusMode = focus;
        document.querySelectorAll('.current, .near').forEach(e => e.classList.remove('current', 'near'));
        const node = id ? document.getElementById(id) : null;
        document.body.classList.toggle('focus', !!(focus && node));
        if (!node) return;
        node.classList.add('current', 'near');
        const stroke = node.querySelector('path, polygon');
        if (stroke) document.documentElement.style.setProperty('--glow', stroke.getAttribute('stroke'));
        const name = node.id;
        document.querySelectorAll('g.edge').forEach(edge => {
          const [from, to] = (edge.dataset.ends || '').split('>');
          if (from === name || to === name) {
            edge.classList.add('near');
            [from, to].forEach(n => document.getElementById(n)?.classList.add('near'));
          }
        });
        if (scroll) {
          const r = node.getBoundingClientRect();
          if (r.top < 40 || r.bottom > window.innerHeight - 60 || r.left < 0 || r.right > window.innerWidth) node.scrollIntoView({ block: 'center', inline: 'center', behavior: 'smooth' });
        }
      }
    </script>
    </body>
    </html>
    """
}
