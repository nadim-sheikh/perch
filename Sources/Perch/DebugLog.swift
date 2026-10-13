import Foundation

/// Tiny append-only debug log at ~/Perch/debug.log (for diagnosing shortcuts).
enum DebugLog {
    private static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Perch/debug.log")
    static func write(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let data = Data("\(stamp) \(line)\n".utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url)
        }
    }
}
