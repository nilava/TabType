import Foundation
import TabTypeKit

/// Owns the v2 (llama.cpp) model lifecycle: the catalog, which model is selected,
/// downloads, and loading it into the shared `InferenceEngine`.
@MainActor
final class LlamaModelManager: ObservableObject {
    static let shared = LlamaModelManager()

    enum Status: Equatable {
        case noModel
        case downloading(id: String, fraction: Double)
        case loading(id: String)
        case ready(id: String)
        case failed(id: String?, message: String)
    }

    @Published private(set) var status: Status = .noModel
    @Published private(set) var catalog: TabTypeKit.ModelCatalog
    /// Bumped whenever files on disk change, so views re-check installed state.
    @Published private(set) var storageRevision = 0
    @Published var selectedID: String {
        didSet { UserDefaults.standard.set(selectedID, forKey: Self.selectedKey) }
    }
    let inference = InferenceEngine()
    let store = TabTypeKit.ModelStore()
    let ramGB = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)

    /// Template and decoder settings of the loaded model (nil until loaded).
    private(set) var template: ModelTemplate?
    private(set) var decoderOptions: DecoderOptions?
    private(set) var loadedID: String?
    private var downloadTask: Task<Void, Never>?

    private static let selectedKey = "llamaModelID"
    private static let customPrefix = "custom:"

    private init() {
        catalog = (try? TabTypeKit.ModelCatalog.bundled())
            ?? TabTypeKit.ModelCatalog(version: 0, models: [], recommendations: [])
        selectedID = UserDefaults.standard.string(forKey: Self.selectedKey) ?? ""
        if selectedID.isEmpty { selectedID = recommendedID ?? catalog.models.first?.id ?? "" }
    }

    var isLoaded: Bool { if case .ready = status { return true } else { return false } }
    var recommendedID: String? { catalog.recommendedEntry(forRAMGB: ramGB)?.id }

    /// Catalog models offered on this Mac, plus GGUFs the user dropped into the folder.
    var entries: [TabTypeKit.ModelCatalog.Entry] {
        _ = storageRevision
        return catalog.entries(forRAMGB: ramGB) + customEntries()
    }

    func entry(id: String) -> TabTypeKit.ModelCatalog.Entry? {
        entries.first { $0.id == id } ?? catalog.entry(id: id)
    }

    func isInstalled(_ id: String) -> Bool {
        _ = storageRevision
        if id.hasPrefix(Self.customPrefix) { return true }
        return entry(id: id).map(store.isInstalled) ?? false
    }

    func fit(_ entry: TabTypeKit.ModelCatalog.Entry) -> ModelFit {
        ModelFit.check(modelBytes: entry.sizeBytes,
                       physicalMemoryBytes: Int64(ProcessInfo.processInfo.physicalMemory),
                       freeDiskBytes: store.freeDiskBytes(), alreadyDownloaded: isInstalled(entry.id))
    }

    // MARK: Lifecycle

    /// Refresh the catalog and load the selected model if it's on disk.
    func start() {
        Task {
            let cache = store.directory.appendingPathComponent("catalog-cache.json")
            try? FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
            catalog = await TabTypeKit.ModelCatalog.latest(cacheURL: cache)
            storageRevision += 1
        }
        if isInstalled(selectedID) {
            load(selectedID)
        } else if case .noModel = status {
            Log.shared.info("v2 engine: selected model \(selectedID) is not downloaded yet")
        }
    }

    /// Choose a model: load it if present, otherwise download then load.
    func select(_ id: String) {
        selectedID = id
        if isInstalled(id) { load(id) } else { download(id) }
    }

    func download(_ id: String) {
        guard let entry = entry(id: id), !id.hasPrefix(Self.customPrefix) else { return }
        downloadTask?.cancel()
        status = .downloading(id: id, fraction: 0)
        downloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await TabTypeKit.ModelDownloader().download(entry, into: self.store) { [weak self] received, total in
                    Task { @MainActor [weak self] in
                        guard let self, case .downloading(id, _) = self.status else { return }
                        self.status = .downloading(id: id, fraction: Double(received) / Double(max(total, 1)))
                    }
                }
                self.storageRevision += 1
                if self.selectedID == id { self.load(id) } else { self.restoreStatus() }
            } catch is CancellationError {
                self.restoreStatus()
            } catch {
                self.status = .failed(id: id, message: "Download failed: \(error)")
                Log.shared.info("v2 engine: download of \(id) failed: \(error)")
            }
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        restoreStatus()
    }

    func delete(_ id: String) {
        guard let entry = entry(id: id), !id.hasPrefix(Self.customPrefix) else { return }
        if loadedID == id {
            Task { await inference.unload() }
            loadedID = nil
            template = nil
            decoderOptions = nil
            status = .noModel
        }
        try? store.delete(entry)
        storageRevision += 1
    }

    func load(_ id: String) {
        guard let entry = entry(id: id) else {
            status = .failed(id: id, message: "Unknown model")
            return
        }
        let path = id.hasPrefix(Self.customPrefix)
            ? store.directory.appendingPathComponent(entry.fileName).path
            : store.url(for: entry).path
        status = .loading(id: id)
        Task {
            let start = Date()
            do {
                try await inference.load(modelPath: path)
                template = entry.modelTemplate
                decoderOptions = entry.decoderOptions()
                loadedID = id
                status = .ready(id: id)
                Log.shared.info("v2 engine: loaded \(entry.name) (\(entry.template)) in \(Int(Date().timeIntervalSince(start) * 1000))ms")
                await selfTest(entry)
            } catch {
                status = .failed(id: id, message: "Couldn't load \(entry.name): \(error)")
                Log.shared.info("v2 engine: load of \(id) failed: \(error)")
            }
        }
    }

    /// Free the model before the process exits — ggml aborts if Metal resources
    /// are still alive at exit.
    func shutdown() async {
        downloadTask?.cancel()
        await inference.unload()
    }

    // MARK: Helpers

    /// One fixed completion right after loading, logged — proves the whole v2 path
    /// (template → decoder → Metal) works on this Mac before the first keystroke.
    private func selfTest(_ entry: TabTypeKit.ModelCatalog.Entry) async {
        let text = PromptAssembler(template: entry.modelTemplate)
            .assemble(PromptContext(typedText: "Thanks for the update, I'll take a look "))
        let start = Date()
        let result = try? await inference.complete(text, options: entry.decoderOptions(),
                                                    requestID: inference.beginRequest())
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        if let result {
            Log.shared.info("v2 self-test: \"…take a look \" → \"\(result.text)\" (conf \(String(format: "%.2f", result.confidence)), \(ms)ms)")
        } else {
            Log.shared.info("v2 self-test: no result (\(ms)ms)")
        }
    }

    private func restoreStatus() {
        if let loadedID { status = .ready(id: loadedID) } else { status = .noModel }
    }

    private func customEntries() -> [TabTypeKit.ModelCatalog.Entry] {
        store.customModels(excluding: catalog).map { url in
            let name = GGUFFileName(url.lastPathComponent)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            // Custom files are continued as plain text: it works on base and chat
            // models alike, and chat framing needs the file's metadata (TODO once
            // the runtime exposes it before load).
            return TabTypeKit.ModelCatalog.Entry(
                id: Self.customPrefix + url.lastPathComponent, name: name.baseName,
                summary: "Custom model" + (name.quantization.map { " · \($0)" } ?? ""),
                template: "base", url: url, fileName: url.lastPathComponent,
                sizeBytes: size, sha256: nil, license: "", licenseURL: nil, requiresTermsNotice: false,
                minimumRAMGB: 0, showThreshold: nil, extensionThreshold: nil)
        }
    }
}
