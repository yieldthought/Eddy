import AppKit
import Observation

struct ValidationIssue: Identifiable, Hashable {
    enum Severity { case error, warning }
    let id = UUID()
    var severity: Severity
    var message: String
    /// Zero-based line, when the message names one.
    var line: Int?
    var state: String?
}

enum ValidationState: Equatable {
    case unknown
    case running
    case valid
    case issues([ValidationIssue])
    case unavailable(String)

    var errorCount: Int {
        if case .issues(let list) = self { return list.filter { $0.severity == .error }.count }
        return 0
    }

    var issues: [ValidationIssue] {
        if case .issues(let list) = self { return list }
        return []
    }
}

/// Tracks character edits so restyling can always cover the edited text,
/// even when a line's content ends up identical to what it was.
private final class EditTracker: NSObject, NSTextStorageDelegate {
    var pending: NSRange?

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        pending = pending.map { NSUnionRange($0, editedRange) } ?? editedRange
    }
}

@MainActor
@Observable
final class FlowDocument: Identifiable {
    nonisolated let url: URL
    nonisolated var id: URL { url }

    var isDirty = false
    var states: [FlowStateInfo] = []
    var flowName: String?
    var validation: ValidationState = .unknown
    var changedOnDisk = false

    @ObservationIgnored let storage: NSTextStorage
    @ObservationIgnored let undoManager = UndoManager()
    @ObservationIgnored private(set) var analysis = FlowAnalysis.empty
    @ObservationIgnored private var styledGeneration = -1
    @ObservationIgnored private let tracker = EditTracker()
    @ObservationIgnored private var savedText: String
    @ObservationIgnored private var diskDate: Date?
    @ObservationIgnored var selection = NSRange(location: 0, length: 0)
    @ObservationIgnored var scrollY: CGFloat = 0
    @ObservationIgnored var pendingWork: Task<Void, Never>?

    var name: String { url.lastPathComponent }
    var displayName: String {
        url.pathExtension == "flow" ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
    }

    init(url: URL) throws {
        self.url = url
        let text = try String(contentsOf: url, encoding: .utf8)
        savedText = text
        storage = NSTextStorage(string: text)
        diskDate = Self.modificationDate(url)
        storage.delegate = tracker
        analysis = FlowAnalyzer.analyze(storage.string as NSString)
        states = analysis.states
        flowName = analysis.flowName
    }

    static func modificationDate(_ url: URL) -> Date? {
        let path = url.resolvingSymlinksInPath().path
        return (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    var text: String { storage.string }

    // MARK: Styling

    func restyle(_ styles: Styles) {
        let fresh = FlowAnalyzer.analyze(storage.string as NSString)
        let old = analysis.lines
        let new = fresh.lines
        var lo = 0
        var hi = new.count
        if styledGeneration == styles.generation {
            var oldHi = old.count
            while lo < hi, lo < oldHi, new[lo].signature == old[lo].signature { lo += 1 }
            while hi > lo, oldHi > lo, new[hi - 1].signature == old[oldHi - 1].signature {
                hi -= 1
                oldHi -= 1
            }
            if let edit = tracker.pending {
                lo = min(lo, fresh.lineIndex(at: edit.location))
                hi = max(hi, min(new.count, fresh.lineIndex(at: NSMaxRange(edit)) + 1))
            }
        }
        tracker.pending = nil
        analysis = fresh
        styledGeneration = styles.generation
        if lo < hi {
            storage.beginEditing()
            styles.apply(fresh, lines: lo..<hi, to: storage)
            storage.endEditing()
            tracker.pending = nil
        }
        if states != fresh.states { states = fresh.states }
        if flowName != fresh.flowName { flowName = fresh.flowName }
    }

    func invalidateStyle() { styledGeneration = -1 }

    // MARK: Disk

    func refreshDirty() {
        let dirty = storage.string != savedText
        if dirty != isDirty { isDirty = dirty }
    }

    func save() throws {
        let target = url.resolvingSymlinksInPath()
        let fm = FileManager.default
        let permissions = (try? fm.attributesOfItem(atPath: target.path))?[.posixPermissions]
        let text = storage.string
        try text.write(to: target, atomically: true, encoding: .utf8)
        if let permissions {
            try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path)
        }
        savedText = text
        diskDate = Self.modificationDate(url)
        isDirty = false
        changedOnDisk = false
    }

    /// True when the file on disk is newer than what we last read or wrote.
    var isStaleOnDisk: Bool {
        guard let current = Self.modificationDate(url) else { return false }
        guard let diskDate else { return true }
        return current > diskDate
    }

    /// Replaces the buffer with the file on disk. Returns false if unreadable.
    @discardableResult
    func reload(styles: Styles) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        diskDate = Self.modificationDate(url)
        changedOnDisk = false
        if text != storage.string {
            storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text)
            undoManager.removeAllActions()
            invalidateStyle()
            restyle(styles)
        }
        savedText = text
        isDirty = false
        return true
    }
}
