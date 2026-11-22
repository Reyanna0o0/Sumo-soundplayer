import Foundation

/// 调试日志：写到 Documents/debug.log，方便在没有控制台的环境里排查。
enum DebugLog {
    static func write(_ message: String) {
        #if DEBUG
        let line = "[\(Date().formatted(date: .omitted, time: .standard))] \(message)\n"
        guard let docs = try? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return }
        let url = docs.appendingPathComponent("debug.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
        #endif
    }

    static func reset() {
        #if DEBUG
        guard let docs = try? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return }
        try? FileManager.default.removeItem(at: docs.appendingPathComponent("debug.log"))
        #endif
    }
}
