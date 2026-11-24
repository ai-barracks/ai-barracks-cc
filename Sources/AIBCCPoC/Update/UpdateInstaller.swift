import CryptoKit
import Foundation

/// Puts a published release in place of the installed app. Nothing changes
/// until every check passed: the archive matches the release's SHA256SUMS,
/// it holds exactly one app with this bundle id and the release's version,
/// and that app's signature verifies. The old app is moved aside (one
/// backup kept) and moved back if the new one cannot be put in place.
enum UpdateInstaller {
    struct Plan: Sendable {
        let release: ReleaseInfo
        /// The installed app to replace (Bundle.main.bundleURL in the app).
        let target: URL
        let bundleID: String
        /// Scratch space; the previous app goes to `backup`.
        let work: URL
        let backup: URL
    }

    static func install(_ plan: Plan) async throws {
        try checkWritable(plan.target)
        let archive = try await download(plan.release.archive)
        let sums = String(decoding: try await download(plan.release.checksums), as: UTF8.self)
        guard let expected = UpdateFeed.expectedHash(in: sums, for: plan.release.archiveName),
              sha256(archive) == expected else { throw UpdateError.hashMismatch }
        let app = try unpack(archive, into: plan.work)
        try validate(app, bundleID: plan.bundleID, version: plan.release.version)
        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        try swap(plan.target, with: app, backup: plan.backup)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A path macOS runs from a read-only copy (App Translocation), or a
    /// folder this user cannot write, cannot take the new app.
    static func checkWritable(_ target: URL) throws {
        let folder = target.deletingLastPathComponent().path
        guard !target.path.contains("/AppTranslocation/"), FileManager.default.isWritableFile(atPath: folder),
              FileManager.default.isWritableFile(atPath: target.path)
        else { throw UpdateError.notWritable(folder) }
    }

    private static func download(_ url: URL) async throws -> Data {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw UpdateError.download("HTTP \(http.statusCode)")
            }
            return data
        } catch let error as UpdateError {
            throw error
        } catch {
            throw UpdateError.download(error.localizedDescription)
        }
    }

    private static func unpack(_ archive: Data, into work: URL) throws -> URL {
        let files = FileManager.default
        try? files.removeItem(at: work)
        let folder = work.appendingPathComponent("unpacked")
        do {
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            try archive.write(to: work.appendingPathComponent("release.tar.gz"))
        } catch { throw UpdateError.archive(error.localizedDescription) }
        let status = run("/usr/bin/tar", ["-xzf", work.appendingPathComponent("release.tar.gz").path, "-C", folder.path])
        let apps = ((try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "app" && !$0.lastPathComponent.hasPrefix("._") }  // AppleDouble from a tar made without COPYFILE_DISABLE
        guard status == 0, apps.count == 1, let app = apps.first else {
            throw UpdateError.archive(status == 0 ? "앱 \(apps.count)개" : "tar \(status)")
        }
        return app
    }

    static func validate(_ app: URL, bundleID: String, version: ReleaseVersion) throws {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any] else {
            throw UpdateError.wrongBundle("Info.plist 없음")
        }
        let id = info["CFBundleIdentifier"] as? String ?? "?"
        guard id == bundleID else { throw UpdateError.wrongBundle(id) }
        let label = (info["AIBVersionLabel"] as? String) ?? (info["CFBundleShortVersionString"] as? String) ?? "?"
        guard ReleaseVersion(label) == version else { throw UpdateError.wrongBundle("버전 \(label)") }
        guard run("/usr/bin/codesign", ["--verify", "--deep", app.path]) == 0 else {
            throw UpdateError.wrongBundle("서명 확인 실패")
        }
    }

    private static func swap(_ target: URL, with app: URL, backup: URL) throws {
        let files = FileManager.default
        do {
            try files.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
            if files.fileExists(atPath: backup.path) { try files.removeItem(at: backup) }
            try files.moveItem(at: target, to: backup)
        } catch { throw UpdateError.swap(error.localizedDescription) }
        do {
            try files.moveItem(at: app, to: target)
        } catch {
            try? files.moveItem(at: backup, to: target)
            throw UpdateError.swap(error.localizedDescription)
        }
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let options = BoundedProcess.Options(timeout: 120, outputLimit: 64 * 1024, mergeStderr: true, tag: "update")
        let result = BoundedProcess.run(URL(fileURLWithPath: tool), arguments, cwd: FileManager.default.temporaryDirectory,
                                        environment: ["PATH": "/usr/bin:/bin"], options: options)
        if case let .success(output) = result { return output.status }
        return -1
    }
}
