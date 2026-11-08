import Darwin
import Foundation
import MachO

/// Self-test only: a fatal signal writes the crashing thread's raw return
/// addresses to `crash.txt` in the run's output folder, then dies as
/// before. The system stops writing crash reports when the disk is nearly
/// full, and a run that died left nothing (known issue #13, 2026-11-08).
///
/// The handler only writes preallocated bytes (no Swift strings or arrays,
/// no backtrace_symbols_fd, which calls dladdr and snprintf — Codex P11/P03
/// review); names come afterwards from the header line:
/// `atos -o <image> -l <load> <addresses…>`. It runs on its own stack so a
/// stack overflow still gets there.
enum CrashTrace {
    private static let capacity = 128
    private static let digits = 32
    private static let stackSize = 64 * 1024
    private static let signals = [SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGTRAP, SIGFPE]
    nonisolated(unsafe) private static var fd: Int32 = -1
    nonisolated(unsafe) private static var exitInstead = false
    nonisolated(unsafe) private static let frames = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: capacity)
    nonisolated(unsafe) private static let text = UnsafeMutablePointer<UInt8>.allocate(capacity: digits)

    /// `exitInsteadOfRaise`: end with 128+signal instead of dying by it, so
    /// the CT-01a probe leaves no system crash report.
    static func install(in directory: URL, exitInsteadOfRaise: Bool = false) {
        fd = open(directory.appendingPathComponent("crash.txt").path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { return }
        exitInstead = exitInsteadOfRaise
        // Initialised here, so no lazy initialisation runs in the handler.
        frames.initialize(repeating: nil, count: capacity)
        text.initialize(repeating: 0, count: digits)
        let load = UInt(bitPattern: _dyld_get_image_header(0))
        let header = "image \(Bundle.main.executablePath ?? "?") load 0x\(String(load, radix: 16))\n"
        _ = header.withCString { Darwin.write(fd, $0, strlen($0)) }
        var stack = stack_t(ss_sp: UnsafeMutableRawPointer.allocate(byteCount: stackSize, alignment: 16),
                            ss_size: stackSize, ss_flags: 0)
        sigaltstack(&stack, nil)
        for signal in signals {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = { number in CrashTrace.handle(number) }
            action.sa_flags = SA_RESETHAND | SA_ONSTACK
            sigaction(signal, &action, nil)
        }
    }

    private static func handle(_ number: Int32) {
        put("fatal signal ")
        putNumber(UInt(number), radix: 10)
        put("\n")
        let count = Int(backtrace(frames, Int32(capacity)))
        for index in 0 ..< count {
            put("0x")
            putNumber(UInt(bitPattern: frames[index]), radix: 16)
            put("\n")
        }
        if exitInstead { _exit(128 + number) }
        raise(number)
    }

    private static func put(_ literal: StaticString) {
        _ = Darwin.write(fd, literal.utf8Start, literal.utf8CodeUnitCount)
    }

    private static func putNumber(_ value: UInt, radix: UInt) {
        var length = 0
        var rest = value
        repeat {
            length += 1
            rest /= radix
        } while rest != 0 && length < digits
        rest = value
        for index in stride(from: length - 1, through: 0, by: -1) {
            let digit = UInt8(rest % radix)
            text[index] = digit < 10 ? 48 + digit : 87 + digit
            rest /= radix
        }
        _ = Darwin.write(fd, text, length)
    }
}

/// CT-01a: in a probe child, a real invalid write reaches the handler,
/// which records the signal and the return addresses and ends the child.
enum CrashTraceProbe {
    static let directoryEnv = "AIBCC_CRASH_TRACE_DIR"

    static func crash() -> Never {
        let directory = ProcessInfo.processInfo.environment[directoryEnv].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        CrashTrace.install(in: directory, exitInsteadOfRaise: true)
        let invalid = UnsafeMutablePointer<Int>(bitPattern: 0x10)
        invalid?.pointee = 1
        exit(3)
    }

    @MainActor
    static func run() -> TestResult {
        let start = ContinuousClock.now
        var failures: [String] = []
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aibcc-crashtrace-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var status: Int32 = -1
        if let app = Bundle.main.executableURL {
            let options = BoundedProcess.Options(timeout: AppConstants.SelfTest.probeTimeout, outputLimit: 64 * 1024, tag: "probe")
            let environment = ProcessInfo.processInfo.environment.merging([directoryEnv: directory.path]) { $1 }
            switch BoundedProcess.run(app, [SelfTestProbe.argumentPrefix + SelfTestProbe.crashTrace], cwd: directory,
                                      environment: environment, options: options, cancelled: { false }) {
            case let .success(output): status = output.status
            case let .failure(failure): failures.append("probe \(failure)")
            }
        }
        let trace = (try? String(contentsOf: directory.appendingPathComponent("crash.txt"), encoding: .utf8)) ?? ""
        let lines = trace.split(separator: "\n")
        let signal = status - 128
        if signal != SIGSEGV && signal != SIGBUS { failures.append("status \(status)") }
        if !trace.contains("fatal signal \(signal)") { failures.append("no signal line") }
        if !(lines.first?.hasPrefix("image ") ?? false) || !trace.contains(" load 0x") { failures.append("no image line") }
        if lines.filter({ $0.hasPrefix("0x") }).count < 3 { failures.append("addresses \(lines.count)") }
        return .make("CT-01a", "치명 신호(실제 잘못된 쓰기) → crash.txt에 신호·이미지·주소(미리 할당한 버퍼만), 자식은 그 신호로 종료",
                     status: failures.isEmpty ? .pass : .fail, cause: .app,
                     evidence: ["failures": failures.joined(separator: " | "), "status": "\(status)", "lines": "\(lines.count)"],
                     startedAt: start)
    }
}
