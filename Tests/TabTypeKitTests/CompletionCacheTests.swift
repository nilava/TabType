import XCTest
@testable import TabTypeKit

final class CompletionCacheTests: XCTestCase {
    private let result = CompletionResult(text: "hello", confidence: 0.8, words: [], alternatives: [],
        predictedTrailingSpace: false, promptTokens: 1, generatedTokens: 1)

    private func key(_ prompt: String = "draft", _ options: DecoderOptions = DecoderOptions()) -> CompletionCache.Key {
        .init(modelID: "model", options: options, prompt: prompt)
    }

    func testChangedPhraseLengthAndPersonalizationCannotReuseAnOldResult() {
        var cache = CompletionCache()
        cache.insert(result, for: key(), now: 10)
        XCTAssertEqual(cache.result(for: key(), now: 11), result)
        var options = DecoderOptions()
        options.extensionThreshold = PredictionStyle.careful.extensionThreshold
        XCTAssertNil(cache.result(for: key("draft", options), now: 11))
        options = DecoderOptions()
        options.hintBonus = 10
        XCTAssertNil(cache.result(for: key("draft", options), now: 11))
        XCTAssertNil(cache.result(for: key("other draft"), now: 11))
    }

    func testExpiryCapacityAndPrivacyClear() {
        var cache = CompletionCache(capacity: 2, lifetime: 30)
        cache.insert(result, for: key("one"), now: 10)
        cache.insert(result, for: key("two"), now: 11)
        cache.insert(result, for: key("three"), now: 12)
        XCTAssertNil(cache.result(for: key("one"), now: 13))
        XCTAssertEqual(cache.result(for: key("two"), now: 40), result)
        XCTAssertNil(cache.result(for: key("two"), now: 41))
        cache.removeAll()
        XCTAssertNil(cache.result(for: key("three"), now: 14))
        cache.insert(result, for: key(), now: 10)
        XCTAssertNil(cache.result(for: key(), now: 9))
    }
}
