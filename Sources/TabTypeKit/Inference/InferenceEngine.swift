import Foundation

/// Monotonic request counter readable from any thread. Starting a request makes
/// every older request stale; the decoder polls `isCurrent` between steps, so a
/// superseded generation stops within one decode step (no zombie generations).
public final class GenerationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var current: UInt64 = 0

    public init() {}

    public func next() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        current &+= 1
        return current
    }

    public func isCurrent(_ id: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return id == current
    }
}

/// Owns the loaded model for the app. All llama.cpp work runs on one dedicated
/// serial queue (the actor's executor) so blocking decode calls never occupy the
/// shared concurrency pool.
public actor InferenceEngine {
    public enum State: Equatable, Sendable {
        case unloaded
        case ready(modelPath: String)
        case failed(modelPath: String, message: String)
    }

    public private(set) var state: State = .unloaded
    /// Unload after this long without a request (frees several GB of unified memory).
    public var idleUnloadDelay: TimeInterval = 15 * 60

    private let queue = DispatchSerialQueue(label: "app.tabtype.inference", qos: .userInitiated)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let gate = GenerationGate()
    private var runtime: LlamaRuntime?
    /// The model to bring back after an idle or memory-pressure unload; nil after
    /// an explicit `unload()` (model deleted, app quitting).
    private var parkedModelPath: String?
    private var configuration = LlamaRuntime.Configuration()
    private var lastUse = Date()
    private var idleCheck: Task<Void, Never>?
    private var memoryPressure: DispatchSourceMemoryPressure?

    public init() {}

    /// A model is loaded, or parked and reloaded on the next request.
    public var isReady: Bool { runtime != nil || parkedModelPath != nil }
    public var loadedModelPath: String? { runtime?.modelPath ?? parkedModelPath }

    // MARK: Lifecycle

    public func load(modelPath: String, configuration: LlamaRuntime.Configuration = .init()) throws {
        if runtime?.modelPath == modelPath { return }
        runtime = nil   // free the old model before mapping the new one
        self.configuration = configuration
        do {
            runtime = try LlamaRuntime(modelPath: modelPath, configuration: configuration)
            state = .ready(modelPath: modelPath)
            lastUse = Date()
            installMemoryPressureHandler()
            scheduleIdleCheck()
        } catch {
            state = .failed(modelPath: modelPath, message: "\(error)")
            throw error
        }
    }

    public func unload() {
        _ = gate.next()   // anything still queued is stale
        runtime = nil
        parkedModelPath = nil
        state = .unloaded
        idleCheck?.cancel()
    }

    /// Free the model but remember it: the next request loads it again.
    func park() {
        guard let path = runtime?.modelPath else { return }
        _ = gate.next()
        runtime = nil
        parkedModelPath = path
        idleCheck?.cancel()
        // `state` stays `.ready`: to callers the model is available.
    }

    /// The runtime, reloading a parked model (idle / memory pressure) on demand.
    private func activeRuntime() -> LlamaRuntime? {
        if let runtime { return runtime }
        guard let path = parkedModelPath else { return nil }
        do {
            runtime = try LlamaRuntime(modelPath: path, configuration: configuration)
            parkedModelPath = nil
            lastUse = Date()
            scheduleIdleCheck()
            return runtime
        } catch {
            state = .failed(modelPath: path, message: "\(error)")
            parkedModelPath = nil
            return nil
        }
    }

    /// Apply (or clear, with nil) a LoRA adapter on the loaded model.
    public func setAdapter(path: String?, scale: Float = 1) throws {
        _ = gate.next()
        try runtime?.setAdapter(path: path, scale: scale)
    }

    // MARK: Requests

    /// Claims the newest request id, invalidating all earlier requests. Call it on
    /// every keystroke, before awaiting `complete`.
    public nonisolated func beginRequest() -> UInt64 { gate.next() }

    /// Runs the decoder for `text` unless a newer request superseded this one.
    /// Returns nil when superseded, cancelled mid-decode, or not loaded.
    public func complete(_ text: String, options: DecoderOptions, requestID: UInt64) throws -> CompletionResult? {
        guard gate.isCurrent(requestID), let runtime = activeRuntime() else { return nil }
        lastUse = Date()
        let gate = self.gate
        do {
            return try CompletionDecoder.complete(text, model: runtime, options: options) {
                !gate.isCurrent(requestID)
            }
        } catch is CancellationError {
            return nil
        }
    }

    /// Replacements for a selected word (synonym picker), ranked by fit on both sides.
    public func replacements(before: String, selected: String, after: String, count: Int,
                             requestID: UInt64) throws -> [WordScore] {
        guard gate.isCurrent(requestID), let runtime = activeRuntime() else { return [] }
        lastUse = Date()
        let gate = self.gate
        do {
            return try CompletionDecoder.replacements(before: before, selected: selected, after: after,
                                                      model: runtime, count: count) { !gate.isCurrent(requestID) }
        } catch is CancellationError {
            return []
        }
    }

    /// Prefill a stable prompt head (template + context) so the first real request
    /// only computes the typed text.
    public func warmUp(_ text: String) throws {
        guard let runtime = activeRuntime() else { return }
        let tokens = runtime.tokenize(HealSplit.split(text).prompt, addSpecial: true)
        guard !tokens.isEmpty else { return }
        _ = try runtime.evaluatePrompt(tokens)
    }

    // MARK: Memory

    private func scheduleIdleCheck() {
        idleCheck?.cancel()
        idleCheck = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                await self?.unloadIfIdle()
            }
        }
    }

    private func unloadIfIdle() {
        guard runtime != nil, Date().timeIntervalSince(lastUse) >= idleUnloadDelay else { return }
        park()
    }

    private func installMemoryPressureHandler() {
        guard memoryPressure == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.handleMemoryPressure() }
        }
        source.resume()
        memoryPressure = source
    }

    /// Under pressure the model is the biggest allocation we own: drop it unless a
    /// request just ran (it reloads on demand).
    private func handleMemoryPressure() {
        guard Date().timeIntervalSince(lastUse) > 30 else { return }
        park()
    }
}
