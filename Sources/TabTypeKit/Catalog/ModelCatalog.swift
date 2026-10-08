import Foundation

/// The list of models TabType can download, which one to recommend for a Mac, and
/// each model's tuned decoding settings. Shipped inside the app and refreshable
/// from the repo (`catalog/models.json`).
public struct ModelCatalog: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        /// One-line description for the picker.
        public var summary: String
        /// Template name (`ModelTemplate.named`).
        public var template: String
        public var url: URL
        public var fileName: String
        public var sizeBytes: Int64
        public var sha256: String?
        public var license: String
        public var licenseURL: URL?
        /// Show a terms notice and require acknowledgement before downloading.
        public var requiresTermsNotice: Bool
        /// Smallest RAM (GB) this model is offered for.
        public var minimumRAMGB: Int
        /// Tuned on the eval set; nil means decoder defaults.
        public var showThreshold: Double?
        public var extensionThreshold: Double?

        public var modelTemplate: ModelTemplate { ModelTemplate.named(template) ?? .base }

        public func decoderOptions() -> DecoderOptions {
            var options = DecoderOptions()
            if let showThreshold { options.showThreshold = showThreshold }
            if let extensionThreshold { options.extensionThreshold = extensionThreshold }
            return options
        }
    }

    /// Recommended model id for Macs with at least `minimumRAMGB`.
    public struct Recommendation: Codable, Sendable, Equatable {
        public var minimumRAMGB: Int
        public var modelID: String
    }

    public var version: Int
    public var models: [Entry]
    /// Highest matching tier wins.
    public var recommendations: [Recommendation]

    public func entry(id: String) -> Entry? { models.first { $0.id == id } }

    public func recommendedEntry(forRAMGB ram: Int) -> Entry? {
        recommendations
            .filter { $0.minimumRAMGB <= ram }
            .max { $0.minimumRAMGB < $1.minimumRAMGB }
            .flatMap { entry(id: $0.modelID) }
    }

    public func entries(forRAMGB ram: Int) -> [Entry] {
        models.filter { $0.minimumRAMGB <= ram }
    }

    public static func decode(_ data: Data) throws -> ModelCatalog {
        try JSONDecoder().decode(ModelCatalog.self, from: data)
    }

    /// Where the newest catalog is published: this repo's `main` branch, so new
    /// models and retuned thresholds reach users without an app release.
    public static let remoteURL = URL(string:
        "https://raw.githubusercontent.com/nilava/TabType/main/Sources/TabTypeKit/Catalog/models.json")!

    /// The freshest usable catalog: remote (cached to `cacheURL` on success), else the
    /// last cached copy, else the bundled one. A remote catalog older than the
    /// bundled one, or one that fails to decode, is ignored.
    public static func latest(remote: URL = remoteURL, cacheURL: URL?,
                              session: URLSession = .shared) async -> ModelCatalog {
        let bundled = (try? bundled()) ?? ModelCatalog(version: 0, models: [], recommendations: [])
        var request = URLRequest(url: remote, timeoutInterval: 10)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let (data, response) = try? await session.data(for: request),
           (response as? HTTPURLResponse)?.statusCode == 200,
           let fetched = try? decode(data), fetched.version >= bundled.version, !fetched.models.isEmpty {
            if let cacheURL { try? data.write(to: cacheURL, options: .atomic) }
            return fetched
        }
        if let cacheURL, let data = try? Data(contentsOf: cacheURL), let cached = try? decode(data),
           cached.version >= bundled.version, !cached.models.isEmpty {
            return cached
        }
        return bundled
    }

    /// The catalog shipped with this build.
    public static func bundled() throws -> ModelCatalog {
        guard let url = Bundle.module.url(forResource: "models", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try decode(Data(contentsOf: url))
    }
}

// MARK: - Model files

/// Name and quantization parsed from a GGUF file name, e.g.
/// "Qwen3-4B-Base.i1-Q4_K_M.gguf" → ("Qwen3-4B-Base", "Q4_K_M", imatrix: true).
public struct GGUFFileName: Equatable, Sendable {
    public var baseName: String
    public var quantization: String?
    public var isImatrix: Bool

    public init(_ fileName: String) {
        var stem = fileName.hasSuffix(".gguf") ? String(fileName.dropLast(5)) : fileName
        let pattern = #"[.-](i1-|UD-)?((?:IQ|Q)\d[\w]*|F16|f16|BF16|bf16|F32|f32)$"#
        guard let range = stem.range(of: pattern, options: .regularExpression) else {
            baseName = stem
            quantization = nil
            isImatrix = false
            return
        }
        let suffix = String(stem[range].dropFirst())   // drop the separator
        stem.removeSubrange(range)
        isImatrix = suffix.hasPrefix("i1-")
        quantization = suffix.replacingOccurrences(of: "i1-", with: "").replacingOccurrences(of: "UD-", with: "")
        // "Name.i1" style: strip a trailing imatrix marker left on the name.
        if stem.hasSuffix(".i1") {
            stem.removeLast(3)
        }
        baseName = stem
    }
}

/// Whether a model is a sensible choice for this Mac.
public enum ModelFit: Equatable, Sendable {
    case good
    /// Usable, but takes a large share of memory.
    case heavyMemory(percentOfRAM: Int)
    /// Would likely cause swapping or fail to load.
    case tooLarge(percentOfRAM: Int)
    case insufficientDisk(neededBytes: Int64, freeBytes: Int64)

    public static func check(modelBytes: Int64, physicalMemoryBytes: Int64, freeDiskBytes: Int64?,
                             alreadyDownloaded: Bool) -> ModelFit {
        if !alreadyDownloaded, let free = freeDiskBytes, free < modelBytes + 1_000_000_000 {
            return .insufficientDisk(neededBytes: modelBytes + 1_000_000_000, freeBytes: free)
        }
        // Weights plus KV cache and runtime buffers ≈ 1.3× the file.
        let share = Int(Double(modelBytes) * 1.3 / Double(max(physicalMemoryBytes, 1)) * 100)
        if share >= 60 { return .tooLarge(percentOfRAM: share) }
        if share >= 35 { return .heavyMemory(percentOfRAM: share) }
        return .good
    }
}

/// Detects when the catalog starts recommending a different model for this Mac than
/// the one recommended when the user last chose, so the app can offer the switch
/// once.
public struct RecommendationTracker: Sendable {
    public static func pendingUpdate(catalog: ModelCatalog, ramGB: Int, selectedModelID: String?,
                                     lastSeenRecommendationID: String?, dismissedRecommendationID: String?)
        -> ModelCatalog.Entry? {
        guard let recommended = catalog.recommendedEntry(forRAMGB: ramGB),
              recommended.id != selectedModelID,
              recommended.id != dismissedRecommendationID,
              let lastSeen = lastSeenRecommendationID, lastSeen != recommended.id,
              // Only nudge people who were following the previous recommendation.
              selectedModelID == lastSeen else { return nil }
        return recommended
    }
}
