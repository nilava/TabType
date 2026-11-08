import Foundation

public enum PersonalizationScope: String, Codable, CaseIterable, Sendable {
    case currentApp, allApps
}

/// Reuses existing app provenance; never infers a contact or website identity.
/// Unknown apps have no current-app hint, rather than falling back to all writing.
public struct ScopedSuffixIndex: Sendable {
    public struct Document: Sendable {
        public var bundleId: String
        public var text: String
        public init(bundleId: String, text: String) { self.bundleId = bundleId; self.text = text }
    }

    private let shared: SuffixIndex
    private let apps: [String: SuffixIndex]
    public var isEmpty: Bool { shared.isEmpty }
    public var byteCount: Int { shared.byteCount + apps.values.reduce(0) { $0 + $1.byteCount } }

    public init(documents: [Document]) {
        shared = SuffixIndex(documents: documents.map(\.text))
        apps = Dictionary(grouping: documents, by: \.bundleId).mapValues { SuffixIndex(documents: $0.map(\.text)) }
    }

    public func continuation(after typed: String, bundleId: String, scope: PersonalizationScope) -> RetrievalHint? {
        switch scope {
        case .currentApp: return apps[bundleId]?.continuation(after: typed)
        case .allApps: return shared.continuation(after: typed)
        }
    }
}
