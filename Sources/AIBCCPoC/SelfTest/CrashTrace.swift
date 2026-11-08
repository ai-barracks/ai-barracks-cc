import Darwin
import Foundation

/// Self-test only: a fatal signal writes the crashing thread's backtrace to
/// `crash.txt` in the run's output folder, then dies as before. The system
/// stops writing crash reports when the disk is nearly full, and a run that
/// died left no report at all (known issue #13, 2026-11-08).
enum CrashTrace {
    nonisolated(unsafe) private static var fd: Int32 = -1
    private static let signals = [SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGTRAP, SIGFPE]

    static func install(in directory: URL) {
        let path = directory.appendingPathComponent("crash.txt").path
        fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { return }
        for signal in signals {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = { number in CrashTrace.write(number) }
            action.sa_flags = SA_RESETHAND
            sigaction(signal, &action, nil)
        }
    }

    /// Only async-signal-safe calls: write, backtrace, backtrace_symbols_fd.
    private static func write(_ number: Int32) {
        var header: [UInt8] = Array("fatal signal ".utf8) + Array(String(number).utf8) + [10]
        _ = Darwin.write(fd, &header, header.count)
        var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 128)
        let count = backtrace(&frames, Int32(frames.count))
        backtrace_symbols_fd(&frames, count, fd)
        raise(number)
    }
}
