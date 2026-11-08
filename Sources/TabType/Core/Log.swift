import Foundation

/// Lightweight file logger for diagnosing behavior in specific apps without a
/// debugger. Writes to ~/Library/Logs/TabType/tabtype.log. Verbose entries are
/// gated by `verbose` so normal runs stay quiet. The file is capped: past
/// `maxBytes` its newest `keptBytes` move to tabtype.1.log and it starts over,
/// so the log (which holds typed text when verbose) never piles up.
final class Log: @unchecked Sendable {
    static let shared = Log()

    var verbose = false

    private let url: URL
    private let previousURL: URL
    private let directory: URL
    private let queue = DispatchQueue(label: "app.tabtype.log")
    private let formatter: DateFormatter
    private var writesSinceCheck = 0

    static let maxBytes: UInt64 = 5 * 1024 * 1024
    static let keptBytes = 1024 * 1024

    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/TabType", isDirectory: true)
        directory = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("tabtype.log")
        previousURL = dir.appendingPathComponent("tabtype.1.log")
        formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        queue.async { [self] in rotateIfNeeded() }
    }

    static var fileURL: URL { shared.url }

    /// Always-logged line (lifecycle, errors).
    func info(_ message: @autoclosure () -> String) { write(message()) }

    /// Only logged when verbose logging is enabled.
    func debug(_ message: @autoclosure () -> String) {
        guard verbose else { return }
        write(message())
    }

    /// Include captures created by older versions; new versions never save them.
    func clear() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [directory] in
                do {
                    try Self.clearFiles(in: directory)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    static func clearFiles(in directory: URL) throws {
        for name in ["tabtype.log", "tabtype.1.log", "fit"] {
            do { try FileManager.default.removeItem(at: directory.appendingPathComponent(name)) }
            catch let error as CocoaError where error.code == .fileNoSuchFile { continue }
        }
    }

    private func write(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        queue.async { [self] in
            writesSinceCheck += 1
            if writesSinceCheck >= 500 { writesSinceCheck = 0; rotateIfNeeded() }
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(data)
            } else {
                try? data.write(to: url)
            }
        }
    }

    /// On the log queue.
    private func rotateIfNeeded() {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? UInt64,
              size > Self.maxBytes,
              let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: size - UInt64(Self.keptBytes))
        var tail = handle.readDataToEndOfFile()
        // Start at a whole line.
        if let newline = tail.firstIndex(of: 0x0A) { tail = tail.suffix(from: tail.index(after: newline)) }
        try? tail.write(to: previousURL, options: .atomic)
        try? Data().write(to: url, options: .atomic)
    }
}
