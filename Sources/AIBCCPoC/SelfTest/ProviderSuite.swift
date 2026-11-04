import Foundation

/// Provider / Model profiles (v1 providers.rs + build_profile_command
/// tests): validation, `aib start` arguments, and the Codex model/list
/// probe against fake CLIs (never the real one, never a model turn).
@MainActor
struct ProviderSuite {
    func run() async -> [TestResult] {
        [profiles(), await probe()]
    }

    private func check(_ id: String, _ title: String, _ failures: [String], _ start: ContinuousClock.Instant) -> TestResult {
        .make(id, title, status: failures.isEmpty ? .pass : .fail, cause: .app,
              evidence: ["failures": failures.joined(separator: " | ")], startedAt: start)
    }

    private func profiles() -> TestResult {
        let start = ContinuousClock.now
        var failures: [String] = []
        let defaults = UserDefaults(suiteName: "aibcc-provider-\(UUID().uuidString)")!
        if !ProviderProfiles.save(ProviderProfile(model: " opus ", effort: "max"), for: .claude, defaults: defaults) { failures.append("save") }
        if ProviderProfiles.save(ProviderProfile(model: "x", effort: "xhigh"), for: .claude, defaults: defaults) { failures.append("claude xhigh accepted") }
        if ProviderProfiles.save(ProviderProfile(model: "bad\nmodel"), for: .codex, defaults: defaults) { failures.append("control char accepted") }
        if ProviderProfiles.save(ProviderProfile(model: String(repeating: "m", count: 201)), for: .codex, defaults: defaults) { failures.append("long accepted") }
        if ProviderProfiles.save(ProviderProfile(model: "g"), for: .gemini, defaults: defaults) { failures.append("gemini profile accepted") }
        let saved = (try? JSONDecoder().decode(ProviderProfile.self, from: defaults.data(forKey: ProviderProfiles.key(.claude)) ?? Data()))
        if saved != ProviderProfile(model: "opus", effort: "max") { failures.append("trimmed \(String(describing: saved))") }
        if ProviderProfiles.arguments(ProviderProfile(model: "gpt-5.5", effort: "high"), for: .codex) != ["--model", "gpt-5.5", "--effort", "high"]
            || !ProviderProfiles.arguments(ProviderProfile(), for: .codex).isEmpty
            || !ProviderProfiles.arguments(ProviderProfile(effort: "max"), for: .codex).isEmpty { failures.append("arguments") }
        let command = AgentLauncher.command(for: .claude, skipPermissions: true, profile: ProviderProfile(model: "it's", effort: "high")) ?? ""
        let expected = "/bin/zsh -lc " + AgentLauncher.shellQuote("aib start claude --skip-permissions '--model' 'it'\\''s' '--effort' 'high'; exec /bin/zsh -l")
        if command != expected { failures.append("command \(command)") }
        if AgentLauncher.command(for: .gemini, skipPermissions: false) != "/bin/zsh -lc 'aib start gemini; exec /bin/zsh -l'" { failures.append("no profile") }
        let page: [String: Any] = ["data": [["model": "future", "displayName": "Future", "isDefault": true,
                                             "supportedReasoningEfforts": [["reasoningEffort": "high"], ["reasoningEffort": "unknown"]]],
                                            ["model": "hidden", "hidden": true]]]
        if (try? CodexModelProbe.parse(page).get()) != [ProviderModel(model: "future", name: "Future", efforts: ["high"], isDefault: true)] {
            failures.append("parse")
        }
        if case .success = CodexModelProbe.parse(["data": [["model": "\n"]]]) { failures.append("control model id") }
        if case .success = CodexModelProbe.parse(["nope": 1]) { failures.append("schema") }
        let env = CodexModelProbe.sanitizedEnvironment(["PATH": "/bin", "OPENAI_API_KEY": "k", "ANTHROPIC_API_KEY": "k", "CODEX_HOME": "/h",
                                                         "CODEX_X": "x", "CLAUDECODE": "1", "MAP_SESSION_ID": "s", "AWS_PROFILE": "p"])
        if env != ["PATH": "/bin", "CODEX_HOME": "/h"] { failures.append("env \(env.keys.sorted())") }
        return check("PR-01a", "모델 프로필 = v1(검증·trim·aib start --model/--effort·따옴표) · model/list 해석·자격 증명 환경 제거", failures, start)
    }

    private func probe() async -> TestResult {
        let start = ContinuousClock.now
        var failures: [String] = []
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aibcc-fake-codex-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fake = { (name: String, body: String) -> URL in
            let url = directory.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: Data(("#!/bin/sh\n" + body).utf8), attributes: [.posixPermissions: 0o700])
            return url
        }
        // Every request is recorded (r5: an extra request after the last page
        // went unnoticed); a worker is left running (r5: it survived).
        let requests = directory.appendingPathComponent("requests")
        let worker = directory.appendingPathComponent("worker")
        let good = fake("codex", """
        case "$PWD" in *aibcc-codex-*) ;; *) exit 8 ;; esac
        sleep 300 & echo $! > '\(worker.path)'
        exec 3>> '\(requests.path)'
        record() { echo "$1" | sed -n 's/.*"method":"\\([^"]*\\)".*/\\1/p' >&3; }
        read init; record "$init"; echo "$init" | grep -q '"method":"initialize"' || exit 1
        echo '{"id":1,"result":{}}'
        read initialized; record "$initialized"; echo "$initialized" | grep -q '"method":"initialized"' || exit 2
        read models; record "$models"; echo "$models" | grep -q '"method":"model/list"' || exit 3
        echo '{"method":"note","params":{}}'
        echo '{"id":2,"result":{"data":[{"model":"future","displayName":"Future","isDefault":true,"supportedReasoningEfforts":[{"reasoningEffort":"high"}]},{"model":"hidden","hidden":true}],"nextCursor":"next"}}'
        read models; record "$models"; echo "$models" | grep -q '"cursor":"next"' || exit 4
        echo '{"id":3,"result":{"data":[{"model":"other"},{"model":"future"}],"nextCursor":null}}'
        while read anything; do record "$anything"; done
        """)
        let listed = await CodexModelProbe.list(binary: good, timeout: 5)
        if (try? listed.get())?.map(\.model) != ["future", "other"] { failures.append("handshake/pagination \(listed)") }
        usleep(200_000)
        let sent = ((try? String(contentsOf: requests, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        if sent != ["initialize", "initialized", "model/list", "model/list"] { failures.append("requests \(sent)") }
        let workerPID = Int32(((try? String(contentsOf: worker, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        if workerPID <= 0 || kill(workerPID, 0) == 0 { failures.append("worker survived") }
        let huge = String(repeating: "x", count: 70 * 1024)
        let oversized = await CodexModelProbe.list(binary: fake("huge", "read init\necho '{\"id\":1,\"result\":{\"pad\":\"\(huge)\"}}'\nsleep 30\n"), timeout: 5)
        if case .failure(.invalid) = oversized {} else { failures.append("oversized line \(oversized)") }
        let refused = await CodexModelProbe.list(binary: fake("refuse", "read init\necho '{\"id\":1,\"error\":{\"code\":-1}}'\nsleep 30\n"), timeout: 5)
        if refused != .failure(.refused) { failures.append("refused \(refused)") }
        let began = ContinuousClock.now
        let silent = await CodexModelProbe.list(binary: fake("silent", "read init\nsleep 30\n"), timeout: 1)
        if silent != .failure(.timeout) || ContinuousClock.now - began > .seconds(4) { failures.append("timeout \(silent)") }
        let empty = await CodexModelProbe.list(binary: fake("empty", """
        read a; echo '{"id":1,"result":{}}'; read b; read c
        echo '{"id":2,"result":{"data":[{"model":"h","hidden":true}],"nextCursor":null}}'
        sleep 30
        """), timeout: 5)
        if empty != .failure(.empty) { failures.append("empty \(empty)") }
        return check("PR-01b", "Codex model/list 탐침 = v1(initialize→initialized→model/list 페이지, 다른 요청 없음, 임시 cwd, 거절·시간 초과·빈 목록)",
                     failures, start)
    }
}
