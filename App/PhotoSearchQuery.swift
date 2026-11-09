import Foundation
import NaturalLanguage

enum PhotoSearchQuery {
    static func normalized(_ text: String) -> String {
        let simplified = text.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? text
        return simplified.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static let aliases: [String: String] = [
        "人": "a photo of people", "人物": "a photo of a person", "人像": "a portrait photo of a person",
        "法官": "a photo of a judge in a courtroom", "法棍": "a photo of a baguette or sliced French bread",
        "面包": "a photo of bread", "美食": "a photo of food and dishes", "食物": "a photo of food and dishes",
        "酒店自助早餐": "a photo of a hotel breakfast buffet", "早餐": "a photo of breakfast",
        "猫": "a photo of a cat", "狗": "a photo of a dog", "宠物": "a photo of a pet",
        "花": "a photo of flowers", "海": "a photo of the sea", "海边": "a photo of a beach",
        "城市": "a photo of a city", "风景": "a photo of a landscape", "自然风光": "a photo of nature",
        "城市风光": "a photo of a city skyline", "截图": "a screenshot", "票据": "a photo of a receipt or ticket",
        "商品": "a photo of a product", "聊天记录": "a screenshot of a chat conversation"
    ]
    static func english(_ text: String) -> String? {
        let query = normalized(text)
        if let alias = aliases[query] { return alias }
        return query.unicodeScalars.allSatisfy({ $0.value < 128 }) ? query : nil
    }
    static func sourceLanguage(_ text: String) -> String {
        let chars = text.unicodeScalars
        if chars.contains(where: { (0x3040...0x30FF).contains($0.value) }) { return "ja" }
        if chars.contains(where: { (0xAC00...0xD7AF).contains($0.value) || (0x1100...0x11FF).contains($0.value) }) { return "ko" }
        if chars.contains(where: { (0x3400...0x9FFF).contains($0.value) }) { return "zh-Hans" }
        return NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue ?? "en"
    }
    static func category(_ text: String) -> PhotoTag? {
        switch normalized(text) {
        case "人", "人物", "人像", "person", "people", "portrait": return .portrait
        case "美食", "食物", "food": return .food
        case "截图", "screenshot": return .screenshot
        case "票据", "收据", "发票", "支付记录", "票券", "receipt", "invoice", "ticket": return .documents
        case "城市", "城市风光", "city": return .cityScenery
        case "自然风光", "nature": return .naturalScenery
        case "视频", "video": return .video
        default: return nil
        }
    }
    static func metadata(query: String, records: [MediaRecord], content: [String: String]) -> [SemanticHit] {
        let query = normalized(query)
        guard !query.isEmpty else { return [] }
        let tag = category(query)
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let variants = words.map { [$0, $0.applyingTransform(StringTransform("Simplified-Traditional"), reverse: false) ?? $0] }
        return records.compactMap { record in
            if let tag, record.effectiveTags.contains(tag) { return SemanticHit(id: record.id, score: 1) }
            let haystack = content[record.id] ?? ""
            return variants.allSatisfy { alternatives in alternatives.contains { haystack.contains($0) } } ? SemanticHit(id: record.id, score: 1) : nil
        }
    }
    static func merged(metadata: [SemanticHit], visual: [SemanticHit]) -> [SemanticHit] {
        var seen: Set<String> = []
        return (metadata + visual).filter { seen.insert($0.id).inserted }
    }
}
