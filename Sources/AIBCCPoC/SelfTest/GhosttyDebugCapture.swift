import Foundation
import GhosttyTerminal

/// Routes libghostty-spm's debug log to a file for self-test diagnosis.
enum GhosttyDebugCapture {
    static func enable(writingTo file: URL) {
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let path = file.path
        TerminalDebugLog.sink = { message in
            guard let handle = FileHandle(forWritingAtPath: path),
                  let data = (message + "\n").data(using: .utf8)
            else { return }
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        }
        TerminalDebugLog.enable([.lifecycle, .input, .ime, .actions])
    }
}
