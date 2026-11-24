import Foundation

/// Terminal output archive rules (v1 scrollback.rs tests) on a temp
/// directory.
@MainActor
struct ScrollbackSuite {
    func run() -> TestResult {
        let start = ContinuousClock.now
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aibcc-scrollback-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var archive = ScrollbackArchive(directory: directory)
        var failures: [String] = []
        let a = UUID().uuidString, b = UUID().uuidString, c = UUID().uuidString
        let now = Date()
        archive.save(id: a, title: "shell 1", barrackPath: "/x", text: "hello\nworld\n", now: now.addingTimeInterval(-10))
        if archive.text(of: a) != "hello\nworld\n" || archive.list().map(\.id) != [a] { failures.append("save/list") }
        archive.save(id: a, title: "shell 1", barrackPath: "/x", text: "hello\nworld\nmore\n", now: now)
        if archive.text(of: a) != "hello\nworld\nmore\n" || archive.list().count != 1 { failures.append("replace same id") }
        if archive.save(id: b, title: "t", barrackPath: nil, text: "  \n ") != nil { failures.append("empty kept") }
        if archive.save(id: "../evil", title: "t", barrackPath: nil, text: "x") != nil { failures.append("invalid id") }
        let attributes = { (path: String) in (try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? Int }
        let payload = archive.record(a).flatMap(ScrollbackArchive.payloadName).map { directory.appendingPathComponent($0).path } ?? ""
        if attributes(directory.path) != 0o700 || attributes(payload) != 0o600 {
            failures.append("permissions \(String(attributes(directory.path) ?? 0, radix: 8))")
        }
        // r5: a save interrupted after the payload (no record yet) leaves the
        // previous output committed; the stray payload is garbage.
        let stray = directory.appendingPathComponent("\(a).DEADBEEF.txt")
        try? Data("half written".utf8).write(to: stray)
        if archive.text(of: a) != "hello\nworld\nmore\n" || archive.list().count != 1 { failures.append("interrupted save visible") }
        archive.collectGarbage(now: now)
        if FileManager.default.fileExists(atPath: stray.path) || archive.text(of: a) == nil { failures.append("orphan payload gc") }
        try? Data("{}".utf8).write(to: directory.appendingPathComponent("foreign.json"))
        if archive.list().count != 1 { failures.append("foreign file listed") }
        // Tail: whole lines, character boundaries (Korean is 3 bytes each).
        let (cut, truncated) = ScrollbackArchive.tail("첫 줄 잘림\n둘째 줄\n셋째", maxBytes: 18)
        // 32 bytes, keep 18: the cut lands on the first newline → next line.
        if !truncated || cut != "둘째 줄\n셋째" { failures.append("tail \(cut.debugDescription)") }
        // 21 bytes, keep 7: the cut lands inside 마 → starts at 바.
        let (mid, _) = ScrollbackArchive.tail("가나다라마바사", maxBytes: 7)
        if mid != "바사" { failures.append("utf8 boundary \(mid.debugDescription)") }
        archive.maxBytesPerOutput = 10
        if archive.save(id: c, title: "big", barrackPath: nil, text: "0123456789\nabcdefgh\n", now: now.addingTimeInterval(1))?.truncated != true
            || archive.text(of: c) != "abcdefgh\n" { failures.append("cap \(archive.text(of: c).debugDescription)") }
        // GC: age first, then the oldest past the total cap.
        archive.maxTotalBytes = 15
        archive.save(id: b, title: "old", barrackPath: nil, text: "old\n", now: now.addingTimeInterval(-15 * 86_400))
        let removed = archive.collectGarbage(now: now)
        let left = archive.list().map(\.id)
        if removed != 2 || left != [c] { failures.append("gc removed \(removed), left \(left.count)") }
        archive.deleteAll()
        if !archive.list().isEmpty { failures.append("delete all") }
        return .make("SB-01a", "터미널 출력 보관 = v1(원자적 교체·개당 상한(줄·문자 경계)·보관 기간·총량 GC·전용 권한·id 검증)",
                     status: failures.isEmpty ? .pass : .fail, cause: .app,
                     evidence: ["failures": failures.joined(separator: " | ")], startedAt: start)
    }
}
