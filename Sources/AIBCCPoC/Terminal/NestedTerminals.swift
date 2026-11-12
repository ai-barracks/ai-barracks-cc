import Darwin
import Foundation

/// Terminals a program opened inside a pane's own. `aib start codex` and
/// `aib start gemini` run the agent under macOS `script` (to keep its raw
/// output), and `script` opens a second PTY at the size it starts with and
/// never passes a later size change on: the agent stayed as wide as the
/// slot it was started in (2026-11-13 report on beta.7, and the 2026-11-09
/// "agent stayed narrow in a widened window"). The pane's size is given to
/// those inner terminals too; setting it signals their foreground program
/// (SIGWINCH) as any resize does.
enum NestedTerminals {
    struct Size: Equatable, Sendable {
        let columns: UInt16
        let rows: UInt16
        let widthPixels: UInt16
        let heightPixels: UInt16
    }

    /// TIOCSWINSZ is a function-like macro that Swift does not import.
    private static let setWindowSize: UInt = 0x8008_7467
    private static let noDevice = UInt32.max

    /// Device paths of the terminals that descendants of `root` run on,
    /// other than `root`'s own.
    static func devices(under root: pid_t) -> [String] {
        guard root > 0, let own = info(of: root) else { return [] }
        let processes = allProcesses()
        let children = Dictionary(grouping: processes, by: \.parent)
        var found: Set<UInt32> = []
        var pending = [root]
        var seen: Set<pid_t> = [root]
        while let pid = pending.popLast() {
            for child in children[pid] ?? [] where seen.insert(child.pid).inserted {
                if child.terminal != noDevice, child.terminal != own.terminal { found.insert(child.terminal) }
                pending.append(child.pid)
            }
        }
        return found.compactMap(path).sorted()
    }

    /// Gives `size` to every inner terminal under `root`. Returns the
    /// devices it was set on.
    @discardableResult
    static func resize(under root: pid_t, to size: Size) -> [String] {
        devices(under: root).filter { device in
            // Never the controlling terminal of this process, never blocking.
            let descriptor = open(device, O_RDWR | O_NOCTTY | O_NONBLOCK)
            guard descriptor >= 0 else { return false }
            defer { close(descriptor) }
            var window = winsize(ws_row: size.rows, ws_col: size.columns,
                                 ws_xpixel: size.widthPixels, ws_ypixel: size.heightPixels)
            return ioctl(descriptor, setWindowSize, &window) == 0
        }
    }

    private struct Entry {
        let pid: pid_t
        let parent: pid_t
        let terminal: UInt32
    }

    private static func info(of pid: pid_t) -> Entry? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Entry(pid: pid, parent: pid_t(info.pbi_ppid), terminal: info.e_tdev)
    }

    private static func allProcesses() -> [Entry] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        guard capacity > 64 else { return [] }
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        return pids.prefix(max(0, count)).compactMap { $0 > 0 ? info(of: $0) : nil }
    }

    /// "/dev/ttys003" for a pseudo-terminal device number; nil for anything
    /// else.
    private static func path(_ device: UInt32) -> String? {
        guard let name = devname(dev_t(bitPattern: device), S_IFCHR).map({ String(cString: $0) }),
              name.hasPrefix("ttys") else { return nil }
        return "/dev/" + name
    }
}
