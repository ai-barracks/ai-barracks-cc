import Foundation

/// One model a CLI advertises.
struct ProviderModel: Equatable, Identifiable, Sendable {
    let model: String
    let name: String
    let efforts: [String]
    let isDefault: Bool

    var id: String { model }
}

/// The models the installed Codex CLI advertises for this account, read
/// through `codex app-server` JSON-RPC (initialize → initialized →
/// model/list). Never starts a thread or sends a model turn. Port of CC
/// v1.6.1 providers.rs with the same bounds: temp working directory,
/// provider credentials stripped from the environment, hooks/plugins/apps/
/// memories off, 64 KiB per line, 512 KiB total, 4 pages, 12 s.
enum CodexModelProbe {
    enum Failure: Error, Equatable {
        case couldNotStart, timeout, refused, invalid(String), empty

        var message: String {
            switch self {
            case .couldNotStart: "Codex app-server를 시작하지 못했습니다"
            case .timeout: "Codex가 제때 답하지 않았습니다"
            case .refused: "Codex가 모델 목록 요청을 거절했습니다 — 기본 모델이나 직접 입력을 쓰세요"
            case let .invalid(reason): "알 수 없는 응답: \(reason)"
            case .empty: "이 CLI·계정이 알리는 모델이 없습니다"
            }
        }
    }

    static let arguments = ["app-server", "--stdio", "--disable", "hooks", "--disable", "plugins", "--disable", "apps",
                            "--disable", "memories", "-c", "analytics.enabled=false"]
    static let maxLine = 64 * 1024
    static let maxTotal = 512 * 1024
    static let maxPages = 4
    static let timeout: TimeInterval = 12

    /// `command -v codex` in a login shell (a GUI app's PATH is minimal).
    static func findBinary() async -> URL? {
        let output = await ProcessOutput.run(URL(fileURLWithPath: "/bin/zsh"), ["-lc", "command -v codex"], in: NSHomeDirectory())
        let path = output.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return path.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    static func list(binary: URL, timeout: TimeInterval = timeout) async -> Result<[ProviderModel], Failure> {
        await Task.detached { run(binary: binary, timeout: timeout) }.value
    }

    /// v1 sanitized_command: no alternate billing/provider credentials or
    /// nested-session markers; custom account directories stay.
    static func sanitizedEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        let prefixes = ["ANTHROPIC_", "CLAUDE_CODE_", "OPENAI_", "CODEX_", "AWS_", "GOOGLE_"]
        let keep = ["CODEX_HOME", "CLAUDE_CONFIG_DIR"]
        return environment.filter { key, _ in
            keep.contains(key) || !(prefixes.contains { key.hasPrefix($0) } || key == "CLAUDECODE" || key == "MAP_SESSION_ID")
        }
    }

    /// One page of `model/list` (v1 parse_models).
    static func parse(_ result: [String: Any]) -> Result<[ProviderModel], Failure> {
        guard let data = result["data"] as? [[String: Any]] else { return .failure(.invalid("model/list 형식")) }
        guard data.count <= 100 else { return .failure(.invalid("페이지가 너무 큼")) }
        var models: [ProviderModel] = []
        for item in data where item["hidden"] as? Bool != true {
            guard let model = item["model"] as? String, !model.isEmpty, model.count <= ProviderProfiles.maxModelLength,
                  !model.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                return .failure(.invalid("모델 식별자"))
            }
            let allowed = ProviderProfiles.efforts(for: .codex)
            let efforts = ((item["supportedReasoningEfforts"] as? [[String: Any]]) ?? [])
                .compactMap { $0["reasoningEffort"] as? String }.filter(allowed.contains)
            let name = String(((item["displayName"] as? String) ?? model).prefix(200))
            models.append(ProviderModel(model: model, name: name, efforts: efforts, isDefault: item["isDefault"] as? Bool == true))
        }
        return .success(models)
    }

    private static func run(binary: URL, timeout: TimeInterval) -> Result<[ProviderModel], Failure> {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("aibcc-codex-\(UUID().uuidString)")
        guard (try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)) != nil else { return .failure(.couldNotStart) }
        defer { try? FileManager.default.removeItem(at: scratch) }
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = binary
        process.arguments = arguments
        process.currentDirectoryURL = scratch
        process.environment = sanitizedEnvironment()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return .failure(.couldNotStart) }
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        let session = Session(reader: LineReader(output.fileHandleForReading), writer: input.fileHandleForWriting,
                              deadline: Date().addingTimeInterval(timeout))
        return session.exchange()
    }

    /// The JSON-RPC conversation over newline-delimited JSON.
    private struct Session {
        let reader: LineReader
        let writer: FileHandle
        let deadline: Date

        func exchange() -> Result<[ProviderModel], Failure> {
            let initialize: [String: Any] = ["clientInfo": ["name": "aibcc", "version": "2"], "capabilities": ["experimentalApi": false]]
            if case let .failure(failure) = request(1, "initialize", initialize) { return .failure(failure) }
            // The notification must follow a successful initialize.
            guard send(["method": "initialized"]) else { return .failure(.couldNotStart) }
            var cursor: String?
            var all: [ProviderModel] = []
            for page in 0..<maxPages {
                let params: [String: Any] = ["limit": 50, "includeHidden": false, "cursor": cursor ?? NSNull()]
                let result: [String: Any]
                switch request(2 + page, "model/list", params) {
                case let .success(value): result = value
                case let .failure(failure): return .failure(failure)
                }
                switch parse(result) {
                case let .success(models): all += models
                case let .failure(failure): return .failure(failure)
                }
                guard let next = result["nextCursor"] as? String else { return finish(all) }
                guard next != cursor else { return .failure(.invalid("같은 페이지 커서 반복")) }
                cursor = next
            }
            return .failure(.invalid("페이지 수 초과"))
        }

        private func finish(_ models: [ProviderModel]) -> Result<[ProviderModel], Failure> {
            var seen = Set<String>()
            let unique = models.filter { seen.insert($0.model).inserted }
            return unique.isEmpty ? .failure(.empty) : .success(unique)
        }

        private func send(_ message: [String: Any]) -> Bool {
            guard let data = try? JSONSerialization.data(withJSONObject: message, options: .withoutEscapingSlashes) else { return false }
            return (try? writer.write(contentsOf: data + Data("\n".utf8))) != nil
        }

        private func request(_ id: Int, _ method: String, _ params: [String: Any]) -> Result<[String: Any], Failure> {
            guard send(["id": id, "method": method, "params": params]) else { return .failure(.couldNotStart) }
            while true {
                guard let line = reader.next(until: deadline) else { return .failure(.timeout) }
                guard let value = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
                    return .failure(.invalid("JSON 아님"))
                }
                guard value["id"] as? Int == id else { continue }
                if value["error"] != nil { return .failure(.refused) }
                guard let result = value["result"] as? [String: Any] else { return .failure(.invalid("result 없음")) }
                return .success(result)
            }
        }
    }

    /// Lines from a pipe with a deadline; closes past the byte bounds.
    private final class LineReader: @unchecked Sendable {
        private let lock = NSLock()
        private let available = DispatchSemaphore(value: 0)
        private var buffer = Data()
        private var lines: [Data] = []
        private var total = 0
        private var closed = false

        init(_ handle: FileHandle) {
            handle.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                self?.append(data)
            }
        }

        private func append(_ data: Data) {
            lock.lock()
            if data.isEmpty || closed {
                closed = true
            } else {
                total += data.count
                buffer.append(data)
                while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    lines.append(buffer[buffer.startIndex..<newline])
                    buffer = Data(buffer[(newline + 1)...])
                }
                if buffer.count > CodexModelProbe.maxLine || total > CodexModelProbe.maxTotal { closed = true }
            }
            lock.unlock()
            available.signal()
        }

        func next(until deadline: Date) -> Data? {
            while true {
                lock.lock()
                if !lines.isEmpty {
                    let line = lines.removeFirst()
                    lock.unlock()
                    return line
                }
                let done = closed
                lock.unlock()
                if done { return nil }
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0, available.wait(timeout: .now() + remaining) == .success else { return nil }
            }
        }
    }
}
