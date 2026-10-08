import CryptoKit
import Foundation

/// Where model files live and what's installed.
/// Default: ~/Library/Application Support/TabType/Models
public struct ModelStore: Sendable {
    public let directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TabType/Models", isDirectory: true)
    }

    public func url(for entry: ModelCatalog.Entry) -> URL {
        directory.appendingPathComponent(entry.fileName)
    }

    public func isInstalled(_ entry: ModelCatalog.Entry) -> Bool {
        guard let size = try? url(for: entry).resourceValues(forKeys: [.fileSizeKey]).fileSize else { return false }
        return Int64(size) == entry.sizeBytes
    }

    /// GGUF files in the folder that aren't catalog downloads — user-supplied
    /// models, offered as "custom" with templates inferred from their metadata.
    public func customModels(excluding catalog: ModelCatalog) -> [URL] {
        let known = Set(catalog.models.map(\.fileName))
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "gguf" && !known.contains($0.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public func freeDiskBytes() -> Int64? {
        let probe = FileManager.default.fileExists(atPath: directory.path)
            ? directory : directory.deletingLastPathComponent()
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    public func delete(_ entry: ModelCatalog.Entry) throws {
        let file = url(for: entry)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
}

public enum ModelDownloadError: Error, CustomStringConvertible, Equatable {
    case httpStatus(Int)
    case sizeMismatch(expected: Int64, actual: Int64)
    case checksumMismatch

    public var description: String {
        switch self {
        case .httpStatus(let code): return "server returned HTTP \(code)"
        case .sizeMismatch(let e, let a): return "downloaded \(a) bytes, expected \(e)"
        case .checksumMismatch: return "file checksum does not match the catalog"
        }
    }
}

/// Resumable single-file downloader. Writes to `<file>.part` with HTTP Range
/// requests, so an interrupted download continues where it stopped (also across
/// app launches), then verifies size and SHA-256 before moving the file in place.
public final class ModelDownloader: @unchecked Sendable {
    public typealias Progress = @Sendable (_ received: Int64, _ total: Int64) -> Void

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func download(_ entry: ModelCatalog.Entry, into store: ModelStore,
                         progress: Progress? = nil) async throws -> URL {
        let destination = store.url(for: entry)
        if store.isInstalled(entry) { return destination }
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        let partial = destination.appendingPathExtension("part")

        var attempt = 0
        while true {
            do {
                try await transfer(entry.url, to: partial, expected: entry.sizeBytes, progress: progress)
                break
            } catch let error as ModelDownloadError {
                throw error
            } catch {
                attempt += 1
                if Task.isCancelled || attempt >= 20 { throw error }
                // Network hiccup: back off and resume from what's on disk.
                try await Task.sleep(nanoseconds: UInt64(min(30, 1 << min(attempt, 5))) * 1_000_000_000)
            }
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? Int64) ?? 0
        guard size == entry.sizeBytes else {
            try? FileManager.default.removeItem(at: partial)
            throw ModelDownloadError.sizeMismatch(expected: entry.sizeBytes, actual: size)
        }
        if let expected = entry.sha256?.lowercased(), try Self.sha256(of: partial) != expected {
            try? FileManager.default.removeItem(at: partial)
            throw ModelDownloadError.checksumMismatch
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: partial, to: destination)
        return destination
    }

    private func transfer(_ url: URL, to partial: URL, expected: Int64, progress: Progress?) async throws {
        if !FileManager.default.fileExists(atPath: partial.path) {
            FileManager.default.createFile(atPath: partial.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }
        var offset = try handle.seekToEnd()
        guard Int64(offset) < expected else { return }

        var request = URLRequest(url: url)
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if offset > 0, status == 200 {
            // Server ignored the range: start over.
            try handle.truncate(atOffset: 0)
            offset = 0
        } else if status != 200, status != 206 {
            throw ModelDownloadError.httpStatus(status)
        }

        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        var received = Int64(offset)
        var lastReport = Date.distantPast
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 20 {
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if Date().timeIntervalSince(lastReport) > 0.25 {
                    progress?(received, expected)
                    lastReport = Date()
                }
                try Task.checkCancellation()
            }
        }
        try handle.write(contentsOf: buffer)
        received += Int64(buffer.count)
        progress?(received, expected)
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
