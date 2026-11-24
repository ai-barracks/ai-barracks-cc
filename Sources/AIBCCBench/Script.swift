import AppKit
import Foundation

/// A bench scenario: steps run in order against other apps' windows.
struct Script: Decodable {
    struct Step: Decodable {
        let op: String
        var bundle: String?
        var text: String?
        var key: String?
        var ms: Int?
        var x: Double?
        var y: Double?
        var w: Double?
        var h: Double?
        var rx: Double?
        var ry: Double?
        var path: String?
        var contains: String?
        var label: String?
        var count: Int?
        var intervalMs: Int?
        var goFile: String?
    }

    let captureDir: String
    let steps: [Step]
}

struct StepRecord: Encodable {
    let op: String
    let ok: Bool
    let detail: String
    let wall: Double
}

struct Sample: Encodable {
    let byte: UInt8
    let wall: Double
}

struct RunResult: Encodable {
    var ok = true
    var log: [StepRecord] = []
    var sent: [Sample] = []
}

/// Runs the steps; a failed step is recorded and the run continues so the
/// log shows how far a scenario got.
@MainActor
final class ScriptRunner {
    private let script: Script
    private(set) var result = RunResult()
    private var pids: [String: pid_t] = [:]

    init(script: Script) {
        self.script = script
    }

    func run() async {
        for step in script.steps {
            let (ok, detail) = await perform(step)
            result.ok = result.ok && ok
            result.log.append(StepRecord(op: step.op + (step.label.map { ":" + $0 } ?? ""), ok: ok,
                                         detail: detail, wall: Date().timeIntervalSince1970))
        }
    }

    private func perform(_ step: Script.Step) async -> (Bool, String) {
        switch step.op {
        case "launch": return await launch(step.bundle ?? "")
        case "front": return front(step.bundle ?? "")
        case "frame": return frame(step)
        case "click": return click(step)
        case "type": return await type(step.text ?? "", interval: step.intervalMs ?? 12)
        case "key":
            guard let stroke = Keyboard.named[step.key ?? ""] else { return (false, "unknown key") }
            Keyboard.press(stroke)
            return (true, step.key ?? "")
        case "wait":
            try? await Task.sleep(for: .milliseconds(step.ms ?? 0))
            return (true, "\(step.ms ?? 0)ms")
        case "waitFile": return await waitFile(step.path ?? "", contains: step.contains, timeout: step.ms ?? 10_000)
        case "capture": return await capture(step)
        case "burst": return await burst(step)
        default: return (false, "unknown op")
        }
    }

    private func launch(_ bundle: String) async -> (Bool, String) {
        guard let app = await Targets.launch(bundle) else { return (false, "cannot launch \(bundle)") }
        pids[bundle] = app.processIdentifier
        let pid = app.processIdentifier
        for attempt in 0..<100 where Targets.mainWindow(pid) == nil {
            // A running app without windows (Terminal, iTerm) gets a new one.
            if attempt == 30 {
                Targets.bringToFront(pid)
                try? await Task.sleep(for: .milliseconds(300))
                if let stroke = Keyboard.named["cmd-n"] { Keyboard.press(stroke) }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return (Targets.mainWindow(pid) != nil, "pid \(pid)")
    }

    private func pid(_ bundle: String?) -> pid_t? {
        guard let bundle else { return nil }
        return pids[bundle] ?? Targets.running(bundle)?.processIdentifier
    }

    private func front(_ bundle: String) -> (Bool, String) {
        guard let pid = pid(bundle) else { return (false, "not running") }
        Targets.bringToFront(pid)
        return (true, "pid \(pid)")
    }

    private func frame(_ step: Script.Step) -> (Bool, String) {
        guard let pid = pid(step.bundle), let window = Targets.mainWindow(pid) else { return (false, "no window") }
        let target = CGRect(x: step.x ?? 0, y: step.y ?? 0, width: step.w ?? 800, height: step.h ?? 600)
        Targets.setFrame(window, target)
        let actual = Targets.frame(of: window) ?? .zero
        return (true, "requested \(target) actual \(actual)")
    }

    private func click(_ step: Script.Step) -> (Bool, String) {
        guard let pid = pid(step.bundle), let window = Targets.mainWindow(pid),
              let rect = Targets.frame(of: window) else { return (false, "no window") }
        let point = CGPoint(x: rect.minX + rect.width * (step.rx ?? 0.5), y: rect.minY + rect.height * (step.ry ?? 0.5))
        Keyboard.click(at: point)
        return (true, "\(point)")
    }

    private func type(_ text: String, interval: Int) async -> (Bool, String) {
        for character in text {
            guard let stroke = Keyboard.stroke(for: character) else { return (false, "no key for \(character)") }
            Keyboard.press(stroke)
            try? await Task.sleep(for: .milliseconds(interval))
        }
        return (true, "\(text.count) chars")
    }

    private func waitFile(_ path: String, contains: String?, timeout: Int) async -> (Bool, String) {
        let deadline = Date().addingTimeInterval(Double(timeout) / 1000)
        while Date() < deadline {
            // Captures are binary: without `contains` only existence counts.
            if let contains {
                if let text = try? String(contentsOfFile: path, encoding: .utf8), text.contains(contains) {
                    return (true, path)
                }
            } else if FileManager.default.fileExists(atPath: path) {
                return (true, path)
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return (false, "timeout \(path)")
    }

    /// Asks scripts/capture-watcher.sh (which holds screen-capture
    /// permission) for a window capture and waits for the file.
    private func capture(_ step: Script.Step) async -> (Bool, String) {
        let label = step.label ?? "capture"
        guard let pid = pid(step.bundle), let window = Targets.mainWindow(pid), let rect = Targets.frame(of: window),
              let number = Targets.windowNumber(pid: pid, frame: rect) else { return (false, "no window") }
        let directory = URL(fileURLWithPath: script.captureDir, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let image = directory.appendingPathComponent("capture-\(label).png")
        let request = directory.appendingPathComponent("capture-request-\(label).json")
        let body = "{\"window\": \(number), \"output\": \"\(image.path)\"}\n"
        try? body.write(to: request, atomically: true, encoding: .utf8)
        let (ok, _) = await waitFile(image.path, contains: nil, timeout: 6000)
        return (ok, "\(label) window \(number) frame \(rect)")
    }

    /// Starts the fixture's flood (GO file), waits until it really runs, then
    /// types a…z at a fixed interval and records each send time.
    private func burst(_ step: Script.Step) async -> (Bool, String) {
        guard let go = step.goFile, let log = step.path else { return (false, "missing goFile/path") }
        FileManager.default.createFile(atPath: go, contents: nil)
        let (started, _) = await waitFile(log, contains: "\"flood_start\"", timeout: 10_000)
        guard started else { return (false, "flood did not start") }
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        for index in 0..<(step.count ?? 80) {
            let letter = letters[index % letters.count]
            guard let stroke = Keyboard.stroke(for: letter), let ascii = letter.asciiValue else { continue }
            result.sent.append(Sample(byte: ascii, wall: Date().timeIntervalSince1970))
            Keyboard.press(stroke)
            try? await Task.sleep(for: .milliseconds(step.intervalMs ?? 6))
        }
        return (true, "\(result.sent.count) keys")
    }
}
