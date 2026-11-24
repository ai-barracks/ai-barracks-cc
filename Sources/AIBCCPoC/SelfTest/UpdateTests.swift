import Foundation

/// 앱 안 업데이트 (2026-11-24, user: DMG + xattr each release is a chore).
/// The rules, then installs against a local release (file:// feed, ad-hoc
/// signed stand-in apps in a scratch folder) — never GitHub, never the
/// installed app. `updatelive` (opt-in) runs the real feed into scratch.
@MainActor
enum UpdateTests {
    static let appName = "AI Barracks CommandCenter 2.app"

    /// UP-01a: version order, feed and SHA256SUMS parsing, which builds
    /// check at all, translocated or read-only targets refused.
    static func rules() -> TestResult {
        let start = ContinuousClock.now
        var failures: [String] = []
        let ordered = ["2.0.0-beta.2", "2.0.0-beta.10", "2.0.0", "v2.0.1", "2.1.0", "2.9.0", "2.10.0", "3.0.0"]
        let versions = ordered.compactMap(ReleaseVersion.init)
        if versions.count != ordered.count || versions != versions.sorted() || Set(versions).count != versions.count {
            failures.append("order \(versions)")
        }
        if ReleaseVersion("2.1") != nil || ReleaseVersion("dev") != nil || ReleaseVersion("v2.1.0") != ReleaseVersion("2.1.0") {
            failures.append("parse")
        }
        let feed = Self.feedJSON(version: "2.2.0", base: "https://example.invalid/d")
        let release = UpdateFeed.parse(feed)
        if release?.version != ReleaseVersion("2.2.0") || release?.archive.lastPathComponent != "AI-Barracks-CommandCenter-2.2.0.app.tar.gz"
            || release?.checksums.lastPathComponent != "SHA256SUMS-2.2.0.txt" {
            failures.append("feed \(String(describing: release))")
        }
        if UpdateFeed.parse(Self.feedJSON(version: "2.2.0", base: "x", assets: false)) != nil { failures.append("feed without assets") }
        let hash = String(repeating: "ab", count: 32)
        let sums = "\(String(repeating: "cd", count: 32))  AI-Barracks-CommandCenter-2.2.0.dmg\n\(hash)  AI-Barracks-CommandCenter-2.2.0.app.tar.gz\n"
        if UpdateFeed.expectedHash(in: sums, for: "AI-Barracks-CommandCenter-2.2.0.app.tar.gz") != hash
            || UpdateFeed.expectedHash(in: sums, for: "other.tar.gz") != nil {
            failures.append("sums")
        }
        let id = AppUpdater.bundleID
        let builds: [([String: Any], ReleaseVersion?)] = [
            (["CFBundleIdentifier": id, "AIBVersionLabel": "2.1.0"], ReleaseVersion("2.1.0")),
            (["CFBundleIdentifier": id, "AIBVersionLabel": "dev", "CFBundleShortVersionString": "2.1.0"], nil),
            (["CFBundleIdentifier": "com.aibarracks.commandcenter.swiftpoc", "AIBVersionLabel": "2.1.0"], nil),
        ]
        for (info, expected) in builds where AppUpdater(info: info).current != expected { failures.append("current \(info)") }
        let translocated = URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/\(appName)")
        if (try? UpdateInstaller.checkWritable(translocated)) != nil { failures.append("translocated accepted") }
        if (try? UpdateInstaller.checkWritable(URL(fileURLWithPath: "/System/Applications/Calculator.app"))) != nil {
            failures.append("read-only folder accepted")
        }
        return check("UP-01a", failures, start, "업데이트 규칙: 버전 순서(베타<정식, 2.10>2.9), 릴리스·SHA256SUMS 읽기, 개발 빌드·다른 번들은 확인 안 함, 번역 경로·쓰기 불가 위치 거부")
    }

    /// UP-01b: a local release is offered over an older app and not over
    /// the same one; a bad checksum or a different app leaves the
    /// installed app as it was; a good one replaces it, keeps the old one
    /// as the backup, and leaves no quarantine flag.
    static func installs() async -> TestResult {
        let start = ContinuousClock.now
        var failures: [String] = []
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aibcc-up-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = root.appendingPathComponent("Applications/\(appName)")
        guard makeApp(at: installed, id: AppUpdater.bundleID, version: "2.1.0"),
              let good = makeRelease(in: root.appendingPathComponent("good"), id: AppUpdater.bundleID, version: "9.9.9"),
              let otherApp = makeRelease(in: root.appendingPathComponent("other"), id: "com.example.other", version: "9.9.9"),
              let badSums = makeRelease(in: root.appendingPathComponent("badsums"), id: AppUpdater.bundleID, version: "9.9.9", corruptSums: true)
        else { return check("UP-01b", ["setup"], start, "업데이트 설치") }
        let older = AppUpdater(info: ["CFBundleIdentifier": AppUpdater.bundleID, "AIBVersionLabel": "2.1.0"])
        await older.check(userInitiated: false, feed: good)
        guard let release = older.available else { return check("UP-01b", ["not offered: \(older.state)"], start, "업데이트 설치") }
        let same = AppUpdater(info: ["CFBundleIdentifier": AppUpdater.bundleID, "AIBVersionLabel": "9.9.9"])
        await same.check(userInitiated: false, feed: good)
        if same.state != .upToDate { failures.append("same version offered: \(same.state)") }
        for (name, feed) in [("bad checksum", badSums), ("other app", otherApp)] {
            let updater = AppUpdater(info: ["CFBundleIdentifier": AppUpdater.bundleID, "AIBVersionLabel": "2.1.0"])
            await updater.check(userInitiated: false, feed: feed)
            guard let offered = updater.available else { failures.append("\(name) not offered"); continue }
            let ok = await updater.install(offered, target: installed, relaunch: false)
            if ok || updater.installError == nil || version(of: installed) != "2.1.0" { failures.append("\(name): ok=\(ok) now \(version(of: installed) ?? "gone")") }
        }
        let ok = await older.install(release, target: installed, relaunch: false)
        let backup = AppConstants.Update.directory.appendingPathComponent("previous/\(appName)")
        if !ok || version(of: installed) != "9.9.9" { failures.append("install: ok=\(ok) \(older.installError ?? "") now \(version(of: installed) ?? "gone")") }
        if version(of: backup) != "2.1.0" { failures.append("backup \(version(of: backup) ?? "none")") }
        if UpdateInstaller.run("/usr/bin/xattr", ["-p", "com.apple.quarantine", installed.path]) == 0 { failures.append("quarantined") }
        try? FileManager.default.removeItem(at: backup)
        return check("UP-01b", failures, start, "업데이트 설치(로컬 릴리스): 낮은 버전에만 제안, 체크섬 불일치·다른 앱은 설치 안 하고 원래 앱 유지, 정상이면 교체·이전 앱 백업·격리 속성 없음")
    }

    /// UP-01c (`--selftest-only=updatelive`, network): GitHub's latest is
    /// offered to a pretend older app and installs into scratch.
    static func live() async -> TestResult {
        let start = ContinuousClock.now
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aibcc-uplive-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = root.appendingPathComponent(appName)
        guard makeApp(at: installed, id: AppUpdater.bundleID, version: "2.0.0") else { return check("UP-01c", ["setup"], start, "GitHub") }
        let updater = AppUpdater(info: ["CFBundleIdentifier": AppUpdater.bundleID, "AIBVersionLabel": "2.0.0"])
        await updater.check(userInitiated: false, feed: UpdateFeed.latest)
        guard let release = updater.available else { return check("UP-01c", ["state \(updater.state)"], start, "GitHub") }
        let ok = await updater.install(release, target: installed, relaunch: false)
        try? FileManager.default.removeItem(at: AppConstants.Update.directory.appendingPathComponent("previous/\(appName)"))
        let now = version(of: installed)
        let failures = ok && now == release.version.description ? [] : ["ok=\(ok) \(updater.installError ?? "") now \(now ?? "gone")"]
        return check("UP-01c", failures, start, "GitHub 최신 릴리스 v\(release.version)를 내려받아 검증·설치(임시 폴더)")
    }

    // MARK: - Stand-ins

    static func version(of app: URL) -> String? {
        (NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any])?["AIBVersionLabel"] as? String
    }

    /// A signed app bundle whose executable is a copy of /usr/bin/true.
    static func makeApp(at app: URL, id: String, version: String) -> Bool {
        let contents = app.appendingPathComponent("Contents")
        let info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleShortVersionString": version, "AIBVersionLabel": version,
                                   "CFBundleExecutable": "standin", "CFBundlePackageType": "APPL", "CFBundleName": "standin"]
        do {
            try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
            try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: contents.appendingPathComponent("MacOS/standin").path)
            guard (info as NSDictionary).write(to: contents.appendingPathComponent("Info.plist"), atomically: true) else { return false }
        } catch { return false }
        return UpdateInstaller.run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", app.path]) == 0
    }

    /// A release folder (archive, SHA256SUMS, feed.json); returns the feed.
    static func makeRelease(in folder: URL, id: String, version: String, corruptSums: Bool = false) -> URL? {
        guard let parsed = ReleaseVersion(version), makeApp(at: folder.appendingPathComponent("stage/\(appName)"), id: id, version: version)
        else { return nil }
        let archive = folder.appendingPathComponent(UpdateFeed.archiveName(parsed))
        let options = BoundedProcess.Options(timeout: 60, outputLimit: 4096, mergeStderr: true, tag: "update")
        let tar = BoundedProcess.run(URL(fileURLWithPath: "/usr/bin/tar"), ["-czf", archive.path, "-C", folder.appendingPathComponent("stage").path, appName],
                                     cwd: folder, environment: ["PATH": "/usr/bin:/bin", "COPYFILE_DISABLE": "1"], options: options)
        guard case let .success(output) = tar, output.status == 0, let data = try? Data(contentsOf: archive) else { return nil }
        let hash = corruptSums ? String(repeating: "0", count: 64) : UpdateInstaller.sha256(data)
        let sums = "\(hash)  \(archive.lastPathComponent)\n"
        let feed = folder.appendingPathComponent("feed.json")
        do {
            try sums.write(to: folder.appendingPathComponent(UpdateFeed.checksumsName(parsed)), atomically: true, encoding: .utf8)
            try feedJSON(version: version, base: folder.absoluteString.hasSuffix("/") ? String(folder.absoluteString.dropLast()) : folder.absoluteString).write(to: feed)
        } catch { return nil }
        return feed
    }

    static func feedJSON(version: String, base: String, assets: Bool = true) -> Data {
        let names = ["AI-Barracks-CommandCenter-\(version).dmg", "AI-Barracks-CommandCenter-\(version).app.tar.gz", "SHA256SUMS-\(version).txt"]
        let list: [[String: Any]] = assets ? names.map { ["name": $0, "browser_download_url": "\(base)/\($0)"] } : []
        let body: [String: Any] = ["tag_name": "v\(version)", "html_url": "\(base)/release", "body": "notes", "assets": list]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    private static func check(_ id: String, _ failures: [String], _ start: ContinuousClock.Instant, _ title: String) -> TestResult {
        .make(id, title, status: failures.isEmpty ? .pass : .fail, cause: .app,
              evidence: ["failures": failures.joined(separator: " | ")], startedAt: start)
    }
}
