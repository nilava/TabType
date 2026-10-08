import Foundation

/// The suggestion engine in use. A single engine since the v2 cutover; kept as a
/// seam so `Engine` doesn't construct inference itself.
@MainActor
final class EngineRouter {
    let llama = LlamaEngine()

    var current: LlamaEngine { llama }

    func cancelInFlight() { llama.cancelInFlight() }
}
