import Foundation

/// Checks that can wedge process-wide state (the process gate) run in a
/// child copy of the app; the parent self-test applies a watchdog, so a
/// regression is reported as a failure instead of hanging the run (r7).
enum SelfTestProbe {
    static let argumentPrefix = "--selftest-probe="
    static let activationGate = "activation-gate"

    /// Runs the requested probe and exits; returns when none was requested.
    static func runIfRequested(_ arguments: [String] = CommandLine.arguments) {
        guard let argument = arguments.first(where: { $0.hasPrefix(argumentPrefix) }) else { return }
        let name = String(argument.dropFirst(argumentPrefix.count))
        let failures: [String] = MainActor.assumeIsolated {
            switch name {
            case activationGate: ActivationSuite().endToEndFailures()
            default: ["unknown probe \(name)"]
            }
        }
        FileHandle.standardOutput.write(Data((failures.joined(separator: " | ") + "\n").utf8))
        exit(failures.isEmpty ? 0 : 1)
    }
}
