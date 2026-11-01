import Darwin
import Foundation

/// Minimal AF_UNIX stream socket helpers. Every fd is FD_CLOEXEC so it never
/// leaks into a spawned child.
public enum UnixSocket {
    /// Blocking connect; nil if nothing listens at `path`.
    public static func connect(path: String) -> Int32? {
        guard var address = address(for: path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        disableSigpipe(fd)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    /// Binds and listens at `path` (owner-only), replacing a stale socket
    /// file. The caller must hold the daemon lock so a live peer's socket is
    /// never unlinked.
    public static func listen(path: String, backlog: Int32 = 16) -> Int32? {
        guard var address = address(for: path) else { return nil }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(fd, backlog) == 0 else {
            close(fd)
            return nil
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        return fd
    }

    /// Accepts one pending connection (non-blocking listener).
    public static func accept(listener: Int32) -> Int32? {
        let fd = Darwin.accept(listener, nil, nil)
        guard fd >= 0 else { return nil }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        disableSigpipe(fd)
        return fd
    }

    /// Exclusive advisory lock next to the socket: exactly one daemon per
    /// socket path, even when two apps start one at the same time.
    public static func acquireLock(path: String) -> Int32? {
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    public static func setReceiveTimeout(_ fd: Int32, seconds: Double) {
        var timeout = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - floor(seconds)) * 1_000_000))
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    private static func disableSigpipe(_ fd: Int32) {
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    private static func address(for path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { return nil }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return address
    }
}
