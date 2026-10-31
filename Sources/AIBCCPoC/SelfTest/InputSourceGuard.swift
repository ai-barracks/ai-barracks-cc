import Carbon
import Foundation

/// Selects a keyboard input source for the synthetic IME test and always
/// restores the user's original source — on normal exit, on SIGINT/SIGTERM,
/// and via atexit (Council decision 6).
@MainActor
enum InputSourceGuard {
    static let korean2Set = "com.apple.inputmethod.Korean.2SetKorean"

    private static var signalSources: [DispatchSourceSignal] = []

    static var currentSourceID: String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return sourceID(of: source)
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
