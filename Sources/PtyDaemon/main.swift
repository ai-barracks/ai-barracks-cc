import Darwin
import Foundation
import PtyProtocol

/// AIBCCPtyDaemon — PTY owner for the AIBCC app.
///   AIBCCPtyDaemon --socket PATH            serve (exits 0 if one already serves PATH)
///   AIBCCPtyDaemon --socket PATH --list     print sessions as JSON
///   AIBCCPtyDaemon --socket PATH --shutdown hang up every session and stop
enum DaemonCommand {
    static func run(_ arguments: [String]) -> Never {
        guard let socketIndex = arguments.firstIndex(of: "--socket"), socketIndex + 1 < arguments.count else {
            FileHandle.standardError.write(Data("usage: AIBCCPtyDaemon --socket PATH [--list|--shutdown]\n".utf8))
            exit(2)
        }
        let socketPath = arguments[socketIndex + 1]
        if arguments.contains("--list") { list(socketPath) }
        if arguments.contains("--shutdown") { shutdown(socketPath) }
        serve(socketPath)
    }

    private static func list(_ socketPath: String) -> Never {
        guard let reply = FrameRequest.send(Frame(.list), to: socketPath, expecting: .sessions) else { exit(1) }
        FileHandle.standardOutput.write(reply.payload)
        FileHandle.standardOutput.write(Data("\n".utf8))
        exit(0)
    }

    private static func shutdown(_ socketPath: String) -> Never {
        exit(FrameRequest.send(Frame(.shutdown), to: socketPath) == nil ? 1 : 0)
    }

    private static func serve(_ socketPath: String) -> Never {
        let directory = (socketPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        // Held for the daemon's lifetime: a second daemon exits quietly.
        guard UnixSocket.acquireLock(path: socketPath + ".lock") != nil else {
            DaemonLog.write("another daemon owns \(socketPath)")
            exit(0)
        }
        signal(SIGPIPE, SIG_IGN)
        guard let listener = UnixSocket.listen(path: socketPath) else {
            DaemonLog.write("cannot listen at \(socketPath): errno \(errno)")
            exit(1)
        }
        let daemon = Daemon(socketPath: socketPath)
        daemon.start(listeningFD: listener)
        dispatchMain()
    }
}

DaemonCommand.run(CommandLine.arguments)
