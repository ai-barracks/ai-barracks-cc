import Carbon
import Foundation

/// Keyboard input-source control for the self-test.
/// - Plain-key tests run on an ASCII layout so results never depend on the
///   source the user happened to leave active (Codex review r1 #6).
/// - The Korean synthetic test is scoped: afterwards the ASCII baseline is
///   restored, and at exit (normal, atexit, SIGINT/SIGTERM) the user's
///   original source is restored (Council decision 6).
@MainActor
enum InputSourceGuard {
    static let korean2Set = "com.apple.inputmethod.Korean.2SetKorean"
    static let asciiCandidates = ["com.apple.keylayout.ABC", "com.apple.keylayout.US"]

    private static var signalSources: [DispatchSourceSignal] = []

    static var currentSourceID: String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return sourceID(of: source)
    }

    /// Selects the first available ASCII layout. Returns its ID, or nil.
    @discardableResult
    static func selectASCIIBaseline() -> String? {
        asciiCandidates.first { select(id: $0) && currentSourceID == $0 }
    }

    /// Runs `body` with `id` selected, then re-selects the source that was
    /// active before. Returns nil without running `body` if `id` is missing.
    static func with<T>(_ id: String, _ body: @MainActor () async -> T) async -> T? {
        let previous = currentSourceID
        defer {
            if let previous, currentSourceID != previous { select(id: previous) }
        }
        guard select(id: id), currentSourceID == id else { return nil }
        return await body()
    }

    @discardableResult
    static func select(id: String) -> Bool {
        installRestoreHooksIfNeeded()
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource],
              let source = list.first
        else { return false }
        return TISSelectInputSource(source) == noErr
    }

    static func restore() {
        restoreOriginalInputSource()
    }

    private static func installRestoreHooksIfNeeded() {
        guard signalSources.isEmpty else { return }
        rememberOriginalInputSource()
        atexit { restoreOriginalInputSource() }
        signalSources = [SIGINT, SIGTERM].map { signalNumber in
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler {
                restoreOriginalInputSource()
                exit(128 + signalNumber)
            }
            source.resume()
            return source
        }
    }

    fileprivate static func sourceID(of source: TISInputSource) -> String? {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }
}

// Global state touched from atexit/signal paths, so it lives outside the actor.
nonisolated(unsafe) private var originalInputSource: TISInputSource?

private func rememberOriginalInputSource() {
    guard originalInputSource == nil else { return }
    originalInputSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
}

private func restoreOriginalInputSource() {
    guard let original = originalInputSource else { return }
    TISSelectInputSource(original)
}
