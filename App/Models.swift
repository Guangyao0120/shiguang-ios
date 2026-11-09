import Foundation
import CoreLocation

enum PhotoTag: String, Codable, CaseIterable, Identifiable {
    case portrait = "人像", scenery = "风景", screenshot = "截图"
    case chat = "聊天记录", videoCall = "视频通话", shopping = "商品购物"
    case receipt = "收据", invoice = "发票", payment = "支付记录"
    case ticket = "票券", meme = "表情与梗图", video = "视频", other = "待确认"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .portrait: return "person.crop.rectangle"
        case .scenery: return "mountain.2"
        case .screenshot: return "viewfinder"
        case .chat: return "bubble.left.and.bubble.right"
        case .videoCall: return "video"
        case .shopping: return "bag"
        case .receipt: return "receipt"
        case .invoice: return "doc.text"
        case .payment: return "creditcard"
        case .ticket: return "ticket"
        case .meme: return "face.smiling"
        case .video: return "play.rectangle"
        case .other: return "questionmark.folder"
        }
    }
}

struct MediaRecord: Codable, Identifiable {
    var id: String
    var date: Date
    var modified: Date?
    var latitude: Double?
    var longitude: Double?
    var isVideo: Bool
    var isScreenshot: Bool
    var duration: Double
    var tags: Set<PhotoTag> = []
    var addedTags: Set<PhotoTag> = []
    var removedTags: Set<PhotoTag> = []
    var text = ""
    var reasons: [String] = []
    var hash: UInt64?
    var people: Set<UUID> = []
    var analyzed = false
    var unavailable = false
    var aiSummary: String?
    var keywords: [String]?
    var voiceTranscript: String?
    var videoTitle: String?
    var effectiveTags: Set<PhotoTag> {
        let result = tags.union(addedTags).subtracting(removedTags)
        return result.isEmpty ? [.other] : result
    }
    var customTags: [String] { TagNames.normalized(keywords ?? []) }
}

enum TagNames {
    static func normalized(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.compactMap { raw in
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "#＃"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.count <= 24, !value.contains(where: \.isNewline),
                  seen.insert(value.lowercased()).inserted else { return nil }
            return value
        }.prefix(40).map { $0 }
    }
}

struct NamedPerson: Codable, Identifiable {
    var id = UUID()
    var name: String
}

struct Trip: Codable, Identifiable {
    var id = UUID()
    var name: String
    var members: Set<String>
    var manual = false
}

struct LibraryState: Codable {
    var similarPairs: [[String]]?
    var customTagNames: [String]?
    var records: [String: MediaRecord] = [:]
    var people: [NamedPerson] = []
    var trips: [Trip] = []
    var pending: Set<String> = []
    var lastStaged: String?

    mutating func stage(_ id: String) {
        guard records[id] != nil, !pending.contains(id) else { return }
        pending.insert(id)
        lastStaged = id
    }
    mutating func undo() {
        if let id = lastStaged { pending.remove(id) }
        lastStaged = nil
    }
    mutating func forget(_ ids: Set<String>) {
        for id in ids { records.removeValue(forKey: id) }
        pending.subtract(ids)
        if let lastStaged, ids.contains(lastStaged) { self.lastStaged = nil }
        for index in trips.indices { trips[index].members.subtract(ids) }
        trips.removeAll { $0.members.isEmpty }
        similarPairs?.removeAll { !$0.allSatisfy { !ids.contains($0) } }
    }
}

enum CategoryRules {
    static func classify(text: String, screenshot: Bool, faces: Int,
                         labels: [String], isVideo: Bool) -> (Set<PhotoTag>, [String]) {
        let t = text.lowercased().replacingOccurrences(of: " ", with: "")
        var tags: Set<PhotoTag> = []
        var reasons: [String] = []
        func match(_ terms: [String]) -> Bool { terms.contains { t.contains($0) } }
        func add(_ tag: PhotoTag, _ reason: String) { tags.insert(tag); reasons.append(reason) }
        if screenshot { add(.screenshot, "系统截图标记") }
        if isVideo { add(.video, "系统视频类型；文字识别只覆盖封面") }
        if faces > 0 { add(.portrait, "检测到人脸，尚未识别人物身份") }
        if match(["增值税", "发票号码", "发票代码", "电子发票", "invoice"]) {
            add(.invoice, "识别到发票文字")
        }
        if match(["收据", "收款收据", "小票", "receipt", "合计金额", "找零"]) {
            add(.receipt, "识别到收据或结算文字")
        }
        if match(["支付成功", "付款成功", "转账成功", "交易单号", "收款成功", "微信支付", "支付宝转账"]) {
            add(.payment, "识别到付款或转账文字")
        }
        if match(["加入购物车", "立即购买", "商品详情", "领券", "已售", "加入购物袋", "buy now", "addtocart"]) {
            add(.shopping, "识别到购物界面文字")
        }
        if match(["检票", "座位号", "影厅", "取票码", "登机牌", "车次", "电子客票", "入场券", "boardingpass"]) {
            add(.ticket, "识别到票券文字")
        }
        if screenshot && match(["按住说话", "发送", "撤回了一条消息", "聊天记录", "对方正在输入", "send", "微信号"]) {
            add(.chat, "截图中有聊天界面线索")
        }
        if screenshot && match(["视频通话", "切换摄像头", "翻转摄像头", "扬声器", "麦克风已关闭", "facetime", "结束通话"]) {
            add(.videoCall, "截图中有通话控制文字；建议复核")
        }
        let visual = labels.joined(separator: " ").lowercased()
        if ["landscape", "mountain", "beach", "forest", "sunset", "scenery"].contains(where: visual.contains) {
            add(.scenery, "本地图像分类命中风景线索")
        }
        if ["meme", "cartoon", "comic", "illustration"].contains(where: visual.contains)
            || match(["表情包", "笑死", "哈哈哈哈", "打工人", "我太难了"]) {
            add(.meme, "插画或梗文字线索，可能包含普通插画")
        }
        if tags.subtracting([.screenshot, .video]).isEmpty { tags.insert(.other) }
        return (tags, reasons)
    }
}

enum TripBuilder {
    // Conservative candidates, not an assertion that every cluster is a vacation.
    static func candidates(_ records: [MediaRecord]) -> [Trip] {
        let located = records.filter { $0.latitude != nil && $0.longitude != nil && !$0.isScreenshot }
            .sorted { $0.date < $1.date }
        var groups: [[MediaRecord]] = []
        for record in located {
            if let last = groups.last?.last,
               record.date.timeIntervalSince(last.date) <= 36 * 3600,
               record.date.timeIntervalSince(groups.last!.first!.date) <= 10 * 86400 {
                let a = CLLocation(latitude: last.latitude!, longitude: last.longitude!)
                let b = CLLocation(latitude: record.latitude!, longitude: record.longitude!)
                if a.distance(from: b) < 150_000 {
                    groups[groups.count - 1].append(record)
                    continue
                }
            }
            groups.append([record])
        }
        return groups.filter { $0.count >= 3 }.map { group in
            Trip(name: TripNaming.name(for: group),
                 members: Set(group.map(\.id)))
        }
    }
}

enum Similarity {
    static func distance(_ lhs: UInt64, _ rhs: UInt64) -> Int { (lhs ^ rhs).nonzeroBitCount }
    static func pairs(_ records: [MediaRecord], comparisonLimit: Int = 200_000) -> [[String]] {
        let images = Array(records.filter { !$0.isVideo && $0.hash != nil }.sorted { $0.id < $1.id }.prefix(3000))
        var result: [[String]] = []
        var comparisons = 0
        // A hash split into 8 bytes: <= 6 bit differences guarantees a matching byte.
        var buckets: [String: [Int]] = [:]
        for i in images.indices {
            if Task.isCancelled { return result }
            let hash = images[i].hash!
            var candidates: Set<Int> = []
            for byte in 0..<8 {
                let key = "\(byte):\((hash >> (byte * 8)) & 255)"
                candidates.formUnion(buckets[key] ?? [])
                buckets[key, default: []].append(i)
            }
            for j in candidates.sorted() {
                if Task.isCancelled || comparisons >= comparisonLimit { return result }
                comparisons += 1
                guard distance(hash, images[j].hash!) <= 6 else { continue }
                result.append([images[j].id, images[i].id])
                // Bound the review result, never auto-delete.
                if result.count >= 500 { return result }
            }
        }
        return result
    }
}
