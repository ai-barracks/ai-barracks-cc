import Darwin
import Foundation

/// Codex's own transcript, `$CODEX_HOME/sessions/YYYY/MM/DD/rollout-*.jsonl`,
/// which the running `codex` keeps open from its first turn. Without aib's
/// Codex hooks it is the only record of a turn ending (2026-11-25: a Codex
/// wrap-up finished and its terminal stayed — the app had nothing to wait
/// for). Measured on Codex 0.160 and 0.167: a turn is `event_msg
/// task_started {turn_id}`, `turn_context {turn_id, cwd}`, the user message
/// (`response_item` role user; older Codex also `event_msg user_message`),
/// then `event_msg task_complete {turn_id, last_agent_message, error?}` or
/// `event_msg turn_aborted`.
enum CodexTranscript {
    enum Turn: Equatable, Sendable {
        /// The request is not in the transcript (yet).
        case notYet
        case running
        /// Ended with an answer, at the line's time.
        case finished(at: Date)
        /// Ended in an error, or the user stopped it.
        case failed
    }

    /// A user message a little before the request's own clock still counts.
    private static let slack: TimeInterval = 2

    /// The turn that carries `request`, sent at or after `since`. `cwd`: in
    /// a transcript no process of the terminal holds, only a turn run in
    /// this folder is this terminal's (another Codex may wrap up too).
    static func turn(of request: String, since: Date, lines: [Substring], cwd: String? = nil) -> Turn {
        var open: (id: String, cwd: String?)?
        var target: (id: String, cwd: String?)?
        var awaitingStart = false
        let here = { (folder: String?) in cwd == nil || folder == nil || samePath(folder, cwd) }
        for line in lines where mayMatter(line, request) {
            guard let entry = Entry(line) else { continue }
            switch entry.kind {
            case let .started(id):
                open = (id, nil)
                if awaitingStart { target = (id, nil); awaitingStart = false }
            case let .context(id, folder):
                if open != nil, id == nil || id == open?.id { open?.cwd = folder }
                if target != nil, id == nil || id == target?.id { target?.cwd = folder }
            case let .ended(id, answered):
                if id == open?.id { open = nil }
                guard let mine = target, id == mine.id else { continue }
                if !here(mine.cwd) || mine.cwd == nil && cwd != nil { target = nil; continue }
                return answered ? .finished(at: entry.time ?? since) : .failed
            case let .user(text):
                guard target == nil, !awaitingStart, text.contains(request),
                      (entry.time ?? .distantPast) >= since.addingTimeInterval(-slack) else { continue }
                if let open { target = open } else { awaitingStart = true }
            }
        }
        guard let target else { return awaitingStart ? .running : .notYet }
        return here(target.cwd) ? .running : .notYet
    }

    /// Codex is mid-reply: the last turn event is a start. `truncated`: the
    /// lines are a tail; none in it means a turn too long to see the start of.
    static func isMidTurn(lines: [Substring], truncated: Bool) -> Bool {
        for line in lines.reversed() where mayMatter(line, nil) {
            switch Entry(line)?.kind {
            case .started: return true
            case .ended: return false
            case .user, .context, nil: continue
            }
        }
        return truncated
    }

    // MARK: - Files

    /// Transcripts held open under `root` (the pane's process): exactly this
    /// terminal's Codex, whatever its CODEX_HOME or executable name.
    static func openTranscripts(under root: pid_t?) -> [URL] {
        guard let root, root > 0 else { return [] }
        let paths = ProcessTree.descendants(of: root)
            .flatMap(ProcessTree.openFiles)
            .filter(isTranscript)
            .map { canonical(URL(fileURLWithPath: $0)) }
        return Array(Set(paths)).sorted().map { URL(fileURLWithPath: $0) }
    }

    /// One spelling per file (/var and /private/var are one folder): the
    /// key offsets and ownership are compared by.
    static func canonical(_ file: URL) -> String {
        file.resolvingSymlinksInPath().path
    }

    static func isTranscript(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return path.contains("/sessions/") && name.hasPrefix("rollout-") && name.hasSuffix(".jsonl")
    }

    /// Codex's home as the app's environment has it.
    static var home: URL {
        ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    /// Transcripts written within `window` before `now`, any process: for a
    /// Codex whose file no process of the terminal holds (a background
    /// server writes it). Files are filed by the day the session started.
    static func recentTranscripts(in home: URL = home, now: Date = Date(),
                                  window: TimeInterval = AppConstants.WrapUp.recentTranscriptWindow) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let walk = FileManager.default.enumerator(at: home.appendingPathComponent("sessions"), includingPropertiesForKeys: keys)
        else { return [] }
        return walk.compactMap { $0 as? URL }.filter { file in
            guard isTranscript(file.path), let values = try? file.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true, let modified = values.contentModificationDate else { return false }
            return now.timeIntervalSince(modified) <= window
        }.map { URL(fileURLWithPath: canonical($0)) }
    }

    /// Transcripts started on `date`'s day or today: new ones since the request.
    static func transcripts(startedAround date: Date, in home: URL = home, now: Date = Date()) -> [URL] {
        let days = Set([date, now].map { Calendar.current.dateComponents([.year, .month, .day], from: $0) })
        return days.flatMap { day -> [URL] in
            guard let year = day.year, let month = day.month, let dayOfMonth = day.day else { return [] }
            let folder = home.appendingPathComponent(String(format: "sessions/%04d/%02d/%02d", year, month, dayOfMonth))
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            return names.map { folder.appendingPathComponent($0) }.filter { isTranscript($0.path) }
                .map { URL(fileURLWithPath: canonical($0)) }
        }
    }

    /// Each file's size now: the wrap-up reads only what comes after.
    static func sizes(_ files: [URL]) -> [String: UInt64] {
        Dictionary(files.map { (canonical($0), size(of: $0)) }) { first, _ in first }
    }

    static func isMidTurn(at file: URL) -> Bool {
        let size = size(of: file)
        let tailBytes = AppConstants.WrapUp.transcriptTailBytes
        let start = size > tailBytes ? size - tailBytes : 0
        let tail = lines(of: file, from: start)
        return isMidTurn(lines: start > 0 ? Array(tail.dropFirst()) : tail, truncated: start > 0)
    }

    /// The request's turn: first in the terminal's own transcripts, then in
    /// `others` (only a turn in `cwd`). Each file is read from its offset at
    /// the request (a file new since then, from its start).
    static func turn(of request: String, since: Date, owned: [URL], others: [URL],
                     offsets: [String: UInt64], cwd: String?) -> Turn {
        let read = { (file: URL, folder: String?) in
            turn(of: request, since: since, lines: lines(of: file, from: offsets[canonical(file)] ?? 0), cwd: folder)
        }
        if let mine = decisive(owned.map { read($0, nil) }) { return mine }
        // Without the terminal's folder no other transcript can be told apart.
        guard let cwd else { return .notYet }
        return decisive(others.map { read($0, cwd) }) ?? .notYet
    }

    /// The most telling of several transcripts' answers: an ended turn,
    /// then a running one.
    private static func decisive(_ turns: [Turn]) -> Turn? {
        turns.first { if case .finished = $0 { return true } else { return false } }
            ?? turns.first { $0 == .failed } ?? turns.first { $0 == .running }
    }

    static func lines(of file: URL, from offset: UInt64) -> [Substring] {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.readToEnd() else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n")
    }

    static func samePath(_ one: String?, _ other: String?) -> Bool {
        guard let one, let other else { return false }
        let resolve = { (path: String) in URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path }
        return resolve(one) == resolve(other)
    }

    private static func size(of file: URL) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// Skips the JSON parse for lines that cannot be a turn event or the request.
    private static func mayMatter(_ line: Substring, _ request: String?) -> Bool {
        line.contains("\"task_started\"") || line.contains("\"task_complete\"") || line.contains("\"turn_aborted\"")
            || line.contains("\"turn_context\"") || request.map { line.contains($0) } ?? false
    }

    private struct Entry {
        enum Kind {
            case started(String)
            case context(turnID: String?, cwd: String?)
            case ended(String, answered: Bool)
            case user(String)
        }

        let kind: Kind
        let time: Date?

        private static let timeStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

        init?(_ line: Substring) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let payload = object["payload"] as? [String: Any], let type = object["type"] as? String
            else { return nil }
            guard let kind = Self.kind(type: type, payload: payload) else { return nil }
            self.kind = kind
            time = (object["timestamp"] as? String).flatMap { try? Self.timeStyle.parse($0) }
        }

        private static func kind(type: String, payload: [String: Any]) -> Kind? {
            let event = payload["type"] as? String
            switch (type, event) {
            case ("event_msg", "task_started"):
                return (payload["turn_id"] as? String).map(Kind.started)
            case ("turn_context", _):
                return .context(turnID: payload["turn_id"] as? String, cwd: payload["cwd"] as? String)
            case ("event_msg", "task_complete"):
                guard let id = payload["turn_id"] as? String else { return nil }
                let answer = payload["last_agent_message"] as? String ?? ""
                let failed = payload["error"].map { !($0 is NSNull) } ?? false
                return .ended(id, answered: !failed && !answer.isEmpty)
            case ("event_msg", "turn_aborted"):
                return (payload["turn_id"] as? String).map { .ended($0, answered: false) }
            case ("event_msg", "user_message"):
                return (payload["message"] as? String).map(Kind.user)
            case ("response_item", "message") where payload["role"] as? String == "user":
                let parts = payload["content"] as? [[String: Any]] ?? []
                return .user(parts.compactMap { $0["text"] as? String }.joined(separator: "\n"))
            default:
                return nil
            }
        }
    }
}

extension ProcessTree {
    static func children(of pid: pid_t) -> [pid_t] {
        var buffer = [pid_t](repeating: 0, count: 256)
        let count = proc_listchildpids(pid, &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
        return count > 0 ? Array(buffer.prefix(Int(count))) : []
    }

    /// Every process under `root`, breadth first (bounded).
    static func descendants(of root: pid_t, limit: Int = 512) -> [pid_t] {
        var found: [pid_t] = []
        var frontier = [root]
        while !frontier.isEmpty, found.count < limit {
            let next = frontier.flatMap(children(of:))
            found += next
            frontier = next
        }
        return found
    }

    /// Paths of the regular files `pid` has open (same user; others read empty).
    static func openFiles(of pid: pid_t) -> [String] {
        let stride = MemoryLayout<proc_fdinfo>.stride
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + 16)
        let used = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        guard used > 0 else { return [] }
        return fds.prefix(Int(used) / stride).compactMap { fd in
            guard fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) else { return nil }
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { return nil }
            let path = withUnsafeBytes(of: info.pvip.vip_path) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            return path.isEmpty ? nil : path
        }
    }
}
