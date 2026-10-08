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
    private var configuration = LlamaRuntime.Configuration()
    private var lastUse = Date()
    private var idleCheck: Task<Void, Never>?
    private var memoryPressure: DispatchSourceMemoryPressure?

    public init() {}

    public var isReady: Bool { runtime != nil }
    public var loadedModelPath: String? { runtime?.modelPath }

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
        state = .unloaded
        idleCheck?.cancel()
    }

    // MARK: Requests

    /// Claims the newest request id, invalidating all earlier requests. Call it on
    /// every keystroke, before awaiting `complete`.
    public nonisolated func beginRequest() -> UInt64 { gate.next() }

    /// Runs the decoder for `text` unless a newer request superseded this one.
    /// Returns nil when superseded, cancelled mid-decode, or not loaded.
    public func complete(_ text: String, options: DecoderOptions, requestID: UInt64) throws -> CompletionResult? {
        guard gate.isCurrent(requestID), let runtime else { return nil }
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

    /// Prefill a stable prompt head (template + context) so the first real request
    /// only computes the typed text.
    public func warmUp(_ text: String) throws {
        guard let runtime else { return }
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
        unload()
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
        unload()
    }
}
