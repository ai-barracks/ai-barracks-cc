import Foundation

/// US-01a: agents and aib run with the PATH the user's terminal has
/// (2026-11-25: the app's `zsh -lc` skipped ~/.zshrc, so a new Mac's app
/// could not find claude in ~/.local/bin, and this Mac's app ran Homebrew's
/// stale Claude 2.1.118 instead of the terminal's 2.1.331). Fixture shells
/// (ZDOTDIR) stand in for the user's dotfiles.
enum UserShellTests {
    static func run() async -> TestResult {
        let start = ContinuousClock.now
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aibcc-us-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var failures = parsing()
        failures += await dotfiles(directory)
        failures += activation(directory)
        return .make("US-01a", "에이전트·aib는 사용자 터미널과 같은 PATH로 실행(.zshrc 반영, 프로필이 PATH를 바꿔도 유지, 멈추는 rc는 시간 제한)",
                     status: failures.isEmpty ? .pass : .fail, cause: .app,
                     evidence: ["failures": failures.joined(separator: " | ")], startedAt: start)
    }

    private static func parsing() -> [String] {
        var failures: [String] = []
        let noisy = "Last login: today\nwelcome\n__AIB_PATH_BEGIN__\n/u/.local/bin:/usr/bin\n__AIB_PATH_END__\nbye\n"
        if UserShell.parse(noisy) != "/u/.local/bin:/usr/bin" { failures.append("PATH not read between markers") }
        if UserShell.parse("no markers\n") != nil || UserShell.parse("__AIB_PATH_BEGIN__\n__AIB_PATH_END__\n") != nil {
            failures.append("a PATH read from nothing")
        }
        if UserShell.prefix(for: nil) != "" || UserShell.prefix(for: "") != "" { failures.append("unknown PATH changed the command") }
        if UserShell.prefix(for: "/a b/bin:/x'y") != "export PATH='/a b/bin:/x'\\''y'; " { failures.append("PATH not quoted") }
        return failures
    }

    /// The profile and rc as Terminal runs them; the prefix survives a
    /// profile that puts Homebrew first.
    private static func dotfiles(_ directory: URL) async -> [String] {
        var failures: [String] = []
        let home = directory.appendingPathComponent("zdot")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try? Data("export PATH=\"/aibcc-profile/bin:$PATH\"\n".utf8).write(to: home.appendingPathComponent(".zprofile"))
        try? Data("echo rc says hello\nexport PATH=\"/aibcc-rc/bin:$PATH\"\n".utf8).write(to: home.appendingPathComponent(".zshrc"))
        let env = ["ZDOTDIR": home.path]
        let read = await UserShell.read(shell: "/bin/zsh", environment: env, timeout: 10)
        if read?.hasPrefix("/aibcc-rc/bin:/aibcc-profile/bin:") != true { failures.append("terminal PATH: \(read ?? "nil")") }
        let login = await ProcessOutput.runWithStatus(URL(fileURLWithPath: "/bin/zsh"), ["-lc", "printenv PATH"], in: NSHomeDirectory(), environment: env).output
        if login.contains("/aibcc-rc/bin") { failures.append("fixture: zsh -lc read .zshrc (the bug would not show)") }
        let fixed = await ProcessOutput.runWithStatus(URL(fileURLWithPath: "/bin/zsh"), ["-lc", UserShell.prefix(for: "/aibcc-rc/bin:/usr/bin:/bin") + "printenv PATH"],
                                                     in: NSHomeDirectory(), environment: env).output
        if fixed.trimmingCharacters(in: .whitespacesAndNewlines) != "/aibcc-rc/bin:/usr/bin:/bin" { failures.append("prefix lost after the profile: \(fixed)") }
        try? Data("sleep 30\n".utf8).write(to: home.appendingPathComponent(".zshrc"))
        let clock = ContinuousClock.now
        let hung = await UserShell.read(shell: "/bin/zsh", environment: env, timeout: 2)
        if hung != nil || ContinuousClock.now - clock > .seconds(8) { failures.append("a waiting rc held the read") }
        return failures
    }

    /// Scheduled activation runs the terminal's claude, not Homebrew's first.
    private static func activation(_ directory: URL) -> [String] {
        let user = directory.appendingPathComponent("user-bin"), other = directory.appendingPathComponent("other-bin")
        for folder in [user, other] {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("aibcc-us-fake")
            FileManager.default.createFile(atPath: file.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        }
        let found = ActivationRunner.findBinary("aibcc-us-fake", userPath: user.path, path: other.path)
        let fallback = ActivationRunner.findBinary("aibcc-us-fake", userPath: nil, path: other.path)
        return found?.deletingLastPathComponent().lastPathComponent == "user-bin" && fallback != nil ? [] : ["activation: \(found?.path ?? "nil")"]
    }
}
