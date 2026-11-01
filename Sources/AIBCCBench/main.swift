import ApplicationServices
import Foundation

/// AIBCC-Bench: drives other apps (PoC, aibcc v1.6.1, Terminal, iTerm) with
/// real input events for the v1.6.1 latency baseline (ST-02) and the Claude
/// Code TUI resize comparison (RS-06). Launch it with `open` so it is its
/// own Accessibility client:
///   open -W AIBCC-Bench.app --args --check [--prompt] --out FILE
///   open -W AIBCC-Bench.app --args --script FILE.json --out RESULT.json
func argument(_ name: String) -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func write(_ data: Data, to path: String?) {
    guard let path else { return }
    try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
}

if CommandLine.arguments.contains("--check") {
    let prompt = CommandLine.arguments.contains("--prompt")
    // The documented value of kAXTrustedCheckOptionPrompt (a C global that
    // Swift 6 rejects as shared mutable state).
    let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
    let trusted = AXIsProcessTrustedWithOptions(options)
    write(Data("trusted=\(trusted)\n".utf8), to: argument("--out"))
    exit(trusted ? 0 : 1)
}

guard let scriptPath = argument("--script"),
      let data = FileManager.default.contents(atPath: scriptPath),
      let script = try? JSONDecoder().decode(Script.self, from: data)
else {
    FileHandle.standardError.write(Data("usage: --check [--prompt] --out FILE | --script FILE --out FILE\n".utf8))
    exit(2)
}
guard AXIsProcessTrusted() else {
    write(Data("{\"ok\": false, \"error\": \"not trusted for Accessibility\"}\n".utf8), to: argument("--out"))
    exit(3)
}
let runner = await MainActor.run { ScriptRunner(script: script) }
await runner.run()
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let result = await MainActor.run { runner.result }
write((try? encoder.encode(result)) ?? Data(), to: argument("--out"))
exit(result.ok ? 0 : 1)
