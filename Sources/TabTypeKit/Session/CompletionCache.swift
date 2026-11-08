import Foundation

/// Bounded recent completions, keyed by every decoder option and the exact prompt.
/// Callers must still authorize the current field and clear on privacy revocation.
public struct CompletionCache: Sendable {
    public struct Key: Hashable, Sendable {
        public let modelID: String
        public let options: DecoderOptions
        public let prompt: String
        public init(modelID: String, options: DecoderOptions, prompt: String) {
            self.modelID = modelID; self.options = options; self.prompt = prompt
        }
    }

    private struct Entry: Sendable { var result: CompletionResult; var at: TimeInterval }
    private var entries: [Key: Entry] = [:]
    private var order: [Key] = []
    private let capacity: Int
    private let lifetime: TimeInterval

    public init(capacity: Int = 200, lifetime: TimeInterval = 30) {
        self.capacity = max(0, capacity); self.lifetime = max(0, lifetime)
    }

    public mutating func result(for key: Key, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> CompletionResult? {
        guard let entry = entries[key] else { return nil }
        let age = now - entry.at
        guard age >= 0, age < lifetime else {
            entries.removeValue(forKey: key)
            order.removeAll { $0 == key }
            return nil
        }
        return entry.result
    }

    public mutating func insert(_ result: CompletionResult, for key: Key,
                                now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard capacity > 0 else { return }
        if entries[key] == nil { order.append(key) }
        entries[key] = Entry(result: result, at: now)
        while order.count > capacity { entries.removeValue(forKey: order.removeFirst()) }
    }

    public mutating func removeAll() { entries.removeAll(); order.removeAll() }
}
