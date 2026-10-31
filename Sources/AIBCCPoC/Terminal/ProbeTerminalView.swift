import AppKit
import GhosttyTerminal

/// One input-method callback observed on a terminal view.
struct InputCallRecord: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case keyDown, interpretBegin, interpretEnd, insertText, setMarkedText, unmarkText, doCommand
    }

    let kind: Kind
    let text: String?
    let keyCode: UInt16?
    let selectedLocation: Int?
    let selectedLength: Int?
    /// insertText is dropped by the wrapper when `NSApp.currentEvent` is nil,
    /// so the probe records it (Codex review r1 #currentEvent).
    let hadCurrentEvent: Bool
    let uptime: TimeInterval
}

/// What the input method does inside one `interpretKeyEvents` call.
/// Scripts replace the real IMK so the callback contract can be replayed
/// deterministically (acceptance layer `imeCallbackContract`).
enum ScriptedIMECall: Sendable, Equatable {
    case setMarkedText(String)
    case insertText(String)
    case unmarkText
}

/// `AppTerminalView` that records every input-method callback and can replay
/// scripted IMK behaviour. Recording a physical-keyboard session yields a
/// fixture; replaying it re-runs exactly the calls IMK made, without IMK.
final class ProbeTerminalView: AppTerminalView {
    /// Bounded so long sessions do not slow the main actor (and skew latency).
    static let callLogLimit = 5000

    private(set) var callLog: [InputCallRecord] = []
    private var replayQueue: [[ScriptedIMECall]] = []

    var pendingReplayCount: Int { replayQueue.count }

    func enqueueReplay(_ calls: [ScriptedIMECall]) {
        replayQueue = replayQueue + [calls]
    }

    func clearCallLog() {
        callLog = []
    }

    func clearReplayQueue() {
        replayQueue = []
    }

    override func keyDown(with event: NSEvent) {
        record(.keyDown, text: event.characters, keyCode: event.keyCode)
        super.keyDown(with: event)
    }

    override func interpretKeyEvents(_ eventArray: [NSEvent]) {
        record(.interpretBegin)
        if let script = replayQueue.first {
            replayQueue = Array(replayQueue.dropFirst())
            script.forEach(apply)
        } else {
            super.interpretKeyEvents(eventArray)
        }
        record(.interpretEnd)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        record(.insertText, text: Self.plainText(string))
        super.insertText(string, replacementRange: replacementRange)
    }

    override func setMarkedText(
        _ string: Any,
        selectedRange: NSRange,
        replacementRange: NSRange
    ) {
        record(.setMarkedText, text: Self.plainText(string), selected: selectedRange)
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    override func unmarkText() {
        record(.unmarkText)
        super.unmarkText()
    }

    override func doCommand(by selector: Selector) {
        record(.doCommand, text: NSStringFromSelector(selector))
        super.doCommand(by: selector)
    }

    private func apply(_ call: ScriptedIMECall) {
        let notFound = NSRange(location: NSNotFound, length: 0)
        switch call {
        case let .setMarkedText(text):
            let caret = NSRange(location: (text as NSString).length, length: 0)
            setMarkedText(text, selectedRange: caret, replacementRange: notFound)
        case let .insertText(text):
            insertText(text, replacementRange: notFound)
        case .unmarkText:
            unmarkText()
        }
    }

    private func record(
        _ kind: InputCallRecord.Kind,
        text: String? = nil,
        keyCode: UInt16? = nil,
        selected: NSRange? = nil
    ) {
        let entry = InputCallRecord(
            kind: kind,
            text: text,
            keyCode: keyCode,
            selectedLocation: selected?.location,
            selectedLength: selected?.length,
            hadCurrentEvent: NSApp.currentEvent != nil,
            uptime: ProcessInfo.processInfo.systemUptime
        )
        if callLog.count >= Self.callLogLimit {
            callLog.removeFirst(callLog.count - Self.callLogLimit + 1)
        }
        callLog.append(entry)
    }

    private static func plainText(_ value: Any) -> String? {
        if let attributed = value as? NSAttributedString { return attributed.string }
        return value as? String
    }
}
