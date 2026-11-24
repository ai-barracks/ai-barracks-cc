import Foundation

/// A release version: "2.1.0", "v2.0.0-beta.10". A pre-release sorts below
/// its release; numeric parts compare as numbers (2.10 > 2.9).
struct ReleaseVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    let core: [Int]
    let prerelease: [String]

    init?(_ text: String) {
        let trimmed = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let parts = trimmed.split(separator: "-", maxSplits: 1).map(String.init)
        let numbers = parts.first?.split(separator: ".").map { Int($0) } ?? []
        guard numbers.count == 3, numbers.allSatisfy({ $0 != nil }) else { return nil }
        core = numbers.compactMap { $0 }
        prerelease = parts.count > 1 ? parts[1].split(separator: ".").map(String.init) : []
    }

    var description: String { core.map(String.init).joined(separator: ".") + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: ".")) }

    static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        if lhs.core != rhs.core { return lhs.core.lexicographicallyPrecedes(rhs.core) }
        if lhs.prerelease.isEmpty || rhs.prerelease.isEmpty { return !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty }
        for (a, b) in zip(lhs.prerelease, rhs.prerelease) where a != b {
            if let x = Int(a), let y = Int(b) { return x < y }
            return a < b
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

/// The newest published release and the two files an update needs.
struct ReleaseInfo: Equatable, Sendable {
    let version: ReleaseVersion
    let page: URL
    let archive: URL
    let checksums: URL
    let notes: String

    var archiveName: String { UpdateFeed.archiveName(version) }
}

/// GitHub's "latest release" (pre-releases excluded by GitHub). Asset names
/// are the ones `docs/RELEASE.md` publishes.
enum UpdateFeed {
    static let latest = URL(string: "https://api.github.com/repos/ai-barracks/ai-barracks-cc/releases/latest")
    /// Tests point the app at a local feed.
    static let feedOverrideKey = "AIBCC_UPDATE_FEED"

    static var url: URL? {
        ProcessInfo.processInfo.environment[feedOverrideKey].flatMap(URL.init(string:)) ?? latest
    }

    static func archiveName(_ version: ReleaseVersion) -> String { "AI-Barracks-CommandCenter-\(version).app.tar.gz" }
    static func checksumsName(_ version: ReleaseVersion) -> String { "SHA256SUMS-\(version).txt" }

    static func parse(_ data: Data) -> ReleaseInfo? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String, let version = ReleaseVersion(tag),
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)),
              let assets = json["assets"] as? [[String: Any]]
        else { return nil }
        let urls = Dictionary(assets.compactMap { asset -> (String, URL)? in
            guard let name = asset["name"] as? String,
                  let url = (asset["browser_download_url"] as? String).flatMap(URL.init(string:)) else { return nil }
            return (name, url)
        }) { first, _ in first }
        guard let archive = urls[archiveName(version)], let checksums = urls[checksumsName(version)] else { return nil }
        return ReleaseInfo(version: version, page: page, archive: archive, checksums: checksums,
                           notes: json["body"] as? String ?? "")
    }

    /// The SHA-256 a SHA256SUMS file gives for `name` ("<hex>  <name>").
    static func expectedHash(in sums: String, for name: String) -> String? {
        sums.split(separator: "\n").lazy.compactMap { line -> String? in
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count == 2, fields[1].trimmingCharacters(in: .whitespaces) == name,
                  fields[0].count == 64 else { return nil }
            return fields[0].lowercased()
        }.first
    }

    static func fetch(from url: URL, userAgent: String) async throws -> ReleaseInfo {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError.feed("HTTP \(http.statusCode)")
        }
        guard let release = parse(data) else { throw UpdateError.feed("릴리스 정보를 읽지 못했습니다") }
        return release
    }
}

enum UpdateError: Error, Equatable {
    case feed(String), download(String), hashMismatch, archive(String), wrongBundle(String)
    case notWritable(String), swap(String)

    var message: String {
        switch self {
        case let .feed(why): "최신 버전을 확인하지 못했습니다 (\(why))"
        case let .download(why): "내려받지 못했습니다 (\(why))"
        case .hashMismatch: "내려받은 파일이 SHA256SUMS와 다릅니다. 설치하지 않았습니다."
        case let .archive(why): "압축을 풀지 못했습니다 (\(why))"
        case let .wrongBundle(why): "받은 앱이 이 앱이 아닙니다 (\(why))"
        case let .notWritable(path): "\(path)에 쓸 수 없어 교체하지 못했습니다. 릴리스 페이지에서 직접 받으세요."
        case let .swap(why): "앱을 바꾸지 못했습니다 — 원래 앱은 그대로입니다 (\(why))"
        }
    }
}
