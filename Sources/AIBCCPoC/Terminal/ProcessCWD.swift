import Darwin

/// Current working directory of a live process (libproc), used to verify
/// that a pane's shell really runs in the selected barrack.
enum ProcessCWD {
    static func path(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
            raw.bindMemory(to: CChar.self).baseAddress.map { String(cString: $0) }
        }
    }

    static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }
}
