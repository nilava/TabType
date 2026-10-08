import Foundation

/// One piece of real or realistic writing the cases are cut from. Stored as JSONL
/// (one object per line) under `eval/corpus/`.
public struct CorpusEntry: Codable, Sendable, Equatable {
    /// Writing situation: "chat", "email", "doc", "note", "code-comment"…
    public var category: String
    /// The app the text was written in, as a hint for prompting ("Slack", "Mail"…).
    public var app: String?
    /// What was on screen around the field (e.g. the conversation so far, newest
    /// last, or an email being replied to). May be empty.
    public var context: String
    /// The author's own text — the thing suggestions are scored against.
    public var text: String

    public init(category: String, app: String? = nil, context: String = "", text: String) {
        self.category = category
        self.app = app
        self.context = context
        self.text = text
    }
}

/// Where the caret sits when the suggestion is requested.
public enum SplitKind: String, Codable, Sendable, CaseIterable {
    /// Right after a space: the next word is predicted from scratch.
    case boundary
    /// Inside a word: the rest of the current word must be completed.
    case midword
}

/// A single evaluation case: the field holds `prefix` with the caret at its end, and
/// the author actually went on to type `truth`.
public struct EvalCase: Codable, Sendable, Equatable {
    public var id: String
    public var category: String
    public var app: String?
    public var kind: SplitKind
    public var context: String
    public var prefix: String
    public var truth: String

    public init(id: String, category: String, app: String?, kind: SplitKind,
                context: String, prefix: String, truth: String) {
        self.id = id
        self.category = category
        self.app = app
        self.kind = kind
        self.context = context
        self.prefix = prefix
        self.truth = truth
    }
}

/// The outcome of running one case through a backend.
public struct CaseResult: Codable, Sendable, Equatable {
    public var id: String
    public var category: String
    public var kind: SplitKind
    public var suggestion: String
    public var truth: String
    public var score: CaseScore
    public var latencyMs: Double

    public init(id: String, category: String, kind: SplitKind, suggestion: String,
                truth: String, score: CaseScore, latencyMs: Double) {
        self.id = id
        self.category = category
        self.kind = kind
        self.suggestion = suggestion
        self.truth = truth
        self.score = score
        self.latencyMs = latencyMs
    }
}

/// A full run: which backend/model produced it, the per-case results, and the
/// aggregate summary. Written as pretty JSON under `eval/results/`.
public struct EvalRun: Codable, Sendable {
    public var backend: String
    public var model: String
    public var date: Date
    public var summary: EvalSummary
    public var results: [CaseResult]

    public init(backend: String, model: String, date: Date = Date(),
                summary: EvalSummary, results: [CaseResult]) {
        self.backend = backend
        self.model = model
        self.date = date
        self.summary = summary
        self.results = results
    }
}

public enum JSONL {
    public static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> [T] {
        let text = try String(contentsOf: url, encoding: .utf8)
        let decoder = JSONDecoder()
        return try text.split(separator: "\n", omittingEmptySubsequences: true)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { try decoder.decode(T.self, from: Data($0.utf8)) }
    }

    public static func write<T: Encodable>(_ items: [T], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let lines = try items.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
