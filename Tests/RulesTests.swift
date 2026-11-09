import XCTest
@testable import Shiguang

final class RulesTests: XCTestCase {
    private func media(_ id: String, _ seconds: TimeInterval = 0,
                       lat: Double? = nil, lon: Double? = nil) -> MediaRecord {
        MediaRecord(id: id, date: Date(timeIntervalSince1970: 1_700_000_000 + seconds),
            latitude: lat, longitude: lon, isVideo: false, isScreenshot: false, duration: 0)
    }

    func testScreenshotCanBeChatAndPaymentAndPortrait() {
        let result = CategoryRules.classify(text: "微信支付 支付成功 发送", screenshot: true,
            faces: 1, labels: [], isVideo: false).0
        XCTAssertTrue(result.isSuperset(of: [.screenshot, .payment, .chat, .portrait]))
        XCTAssertFalse(result.contains(.other))
    }
    func testUnknownStaysReviewable() {
        let result = CategoryRules.classify(text: "", screenshot: true, faces: 0, labels: [], isVideo: false).0
        XCTAssertEqual(result, [.screenshot, .other])
    }
    func testCallDoesNotBecomeVideoAsset() {
        let result = CategoryRules.classify(text: "视频通话 切换摄像头", screenshot: true, faces: 2, labels: [], isVideo: false).0
        XCTAssertTrue(result.contains(.videoCall))
        XCTAssertFalse(result.contains(.video))
    }
    func testManualCorrectionsOverrideAutomaticTagsAndRoundTrip() throws {
        var record = media("a")
        record.tags = [.portrait, .meme]
        record.removedTags = [.meme]
        record.addedTags = [.ticket]
        let decoded = try JSONDecoder().decode(MediaRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(decoded.effectiveTags, [.portrait, .ticket])
    }
    func testStagingUndoAndDeleteDoNotLeaveDanglingReferences() throws {
        var state = LibraryState()
        state.records = ["a": media("a"), "b": media("b")]
        state.trips = [Trip(name: "长沙", members: ["a", "b"])]
        state.stage("a")
        state.stage("a")
        state.stage("missing")
        XCTAssertEqual(state.pending, ["a"])
        let restored = try JSONDecoder().decode(LibraryState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored.pending, ["a"])
        state.undo()
        XCTAssertTrue(state.pending.isEmpty)
        state.stage("a")
        state.forget(["a"])
        XCTAssertEqual(state.trips[0].members, ["b"])
        XCTAssertNil(state.lastStaged)
        XCTAssertNil(state.records["a"])
    }
    func testTripsSeparateDistantLocationsAndMissingLocation() {
        let records = [media("a", 0, lat: 28.2, lon: 112.9),
            media("b", 100, lat: 28.2, lon: 112.9), media("c", 200, lat: 28.2, lon: 112.9),
            media("d", 300, lat: 39.9, lon: 116.4), media("no-location", 400)]
        let trips = TripBuilder.candidates(records)
        XCTAssertEqual(trips.count, 1)
        XCTAssertEqual(trips[0].members, ["a", "b", "c"])
    }
    func testSimilarityFindsDifferentDateCandidatesWithoutDeleting() {
        var a = media("a")
        var b = media("b", 86400 * 100)
        var c = media("c")
        a.hash = 0xA55AA55AA55AA55A
        b.hash = a.hash! ^ 3
        c.hash = ~a.hash!
        XCTAssertEqual(Similarity.pairs([a, b, c]), [["a", "b"]])
    }

    func testAIRequestUsesOfficialHostAndExplicitImageParts() throws {
        let request = try DeepSeekClient.makeRequest(key: "dummy-test-key", model: "deepseek-flash",
            system: "JSON only", text: "分类这张图片", jpeg: Data([1, 2, 3]))
        XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer dummy-test-key")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content[1]["type"] as? String, "image_url")
        let textOnly = try DeepSeekClient.makeRequest(key: "dummy", model: "deepseek-flash", system: "JSON", text: "test")
        XCTAssertFalse(String(data: try XCTUnwrap(textOnly.httpBody), encoding: .utf8)!.contains("image_url"))
    }
    func testAIRejectsTruncatedAndEmptyOutput() throws {
        let truncated = Data(#"{"choices":[{"finish_reason":"length","message":{"content":"{}"}}]}"#.utf8)
        let blank = Data(#"{"choices":[{"finish_reason":"stop","message":{"content":"   "}}]}"#.utf8)
        XCTAssertThrowsError(try DeepSeekClient.decode(truncated, as: AIPlan.self))
        XCTAssertThrowsError(try DeepSeekClient.decode(blank, as: AIPlan.self))
        let invalid = AISuggestion(tags: ["直接删除"], summary: "x", explanation: "x")
        XCTAssertThrowsError(try invalid.validated())
    }
    func testAIValidResponseDecodesBeforeApproval() throws {
        let suggestion = AISuggestion(tags: ["支付记录"], summary: "付款记录", explanation: "支付成功文字")
        let content = String(data: try JSONEncoder().encode(suggestion), encoding: .utf8)!
        let data = try JSONSerialization.data(withJSONObject: ["choices": [
            ["finish_reason": "stop", "message": ["content": content]]]])
        let decoded = try DeepSeekClient.decode(data, as: AISuggestion.self).validated()
        XCTAssertEqual(decoded.tags, ["支付记录"])
        XCTAssertThrowsError(try DeepSeekClient.makeRequest(key: "dummy", model: "", system: "JSON", text: "test"))
        XCTAssertThrowsError(try DeepSeekClient.makeRequest(key: "dummy", model: "deepseek-flash", system: "JSON", text: "test", jpeg: Data(repeating: 0, count: 2_000_001)))
    }
    func testUnsupportedAIPlanCannotMatchAnything() {
        var record = media("a")
        record.tags = [.portrait]
        let plan = AIPlan(tags: ["人像"], text: "", person: "", trip: "", albumName: "测试",
            explanation: "", unsupported: ["排除条件"])
        XCTAssertFalse(plan.matches(record, people: [], trips: []))
        let empty = AIPlan(tags: [], text: "", person: "", trip: "", albumName: "测试", explanation: "", unsupported: [])
        XCTAssertFalse(empty.matches(record, people: [], trips: []))
    }
    func testAIPlanIntersectsTagsPersonAndTripLocally() {
        var record = media("a")
        record.tags = [.portrait]
        let person = NamedPerson(name: "桐桐")
        record.people = [person.id]
        let trip = Trip(name: "中秋 · 长沙", members: ["a"])
        let plan = AIPlan(tags: ["人像"], text: "", person: "桐桐", trip: "长沙", albumName: "长沙桐桐", explanation: "", unsupported: [])
        XCTAssertTrue(plan.matches(record, people: [person], trips: [trip]))
        XCTAssertFalse(plan.matches(record, people: [], trips: [trip]))
    }
    func testCustomTagsNormalizeAndSurviveStorage() throws {
        XCTAssertEqual(TagNames.normalized([" #夜景 ", "夜景", "Cat", "cat", "", "＃聚餐"]), ["夜景", "Cat", "聚餐"])
        var record = media("a")
        record.keywords = ["夜景", "聚餐"]
        let decoded = try JSONDecoder().decode(MediaRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(decoded.customTags, ["夜景", "聚餐"])
        XCTAssertEqual(media("unclassified").effectiveTags, [.other])
        let plan = AIPlan(tags: [], text: "", person: "", trip: "", albumName: "夜景", explanation: "", unsupported: [], keywords: ["夜景"])
        XCTAssertTrue(plan.matches(decoded, people: [], trips: []))
        XCTAssertFalse(plan.matches(media("b"), people: [], trips: []))
    }
}
