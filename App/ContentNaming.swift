import Foundation
import CoreLocation

enum VideoTitleRules {
    static func title(from transcript: String) -> String {
        let compact = transcript.replacingOccurrences(of: " ", with: "")
        let wishes = [("生日快乐", "生日祝福"), ("新婚快乐", "新婚祝福"), ("百年好合", "婚礼祝福"),
                      ("新年快乐", "新年祝福"), ("身体健康", "平安祝福"), ("毕业快乐", "毕业祝福")]
        for (phrase, theme) in wishes where compact.contains(phrase) {
            let pattern = "(?:祝|祝愿)([\\p{Han}A-Za-z·]{1,10}?)" + phrase
            if let range = compact.range(of: pattern, options: .regularExpression) {
                var name = String(compact[range])
                if name.hasPrefix("祝愿") { name.removeFirst(2) } else { name.removeFirst() }
                name = String(name.dropLast(phrase.count))
                let generic = ["你", "您", "你们", "您们", "大家", "所有人", "各位", "我们", "朋友们", "家人们", "福你", "福您"]
                if !generic.contains(name) { return "\(name) · \(theme)" }
            }
            return "\(theme) · 对象待确认"
        }
        if compact.contains("祝福") || compact.contains("祝你") || compact.contains("祝您") {
            return "祝福视频 · 对象待确认"
        }
        let first = transcript.components(separatedBy: CharacterSet(charactersIn: "。！？!?\n"))
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? "视频"
        return String(first.trimmingCharacters(in: .whitespacesAndNewlines).prefix(20))
    }
}

enum TripNaming {
    // Approximate city centres, used only for editable candidates within 30 km.
    // Unknown locations retain a date title; no reverse-geocoding request is sent.
    private static let centres: [(String, Double, Double)] = [
        ("长沙",28.228,112.939), ("北京",39.904,116.407), ("上海",31.230,121.474),
        ("广州",23.129,113.264), ("深圳",22.543,114.058), ("杭州",30.274,120.155),
        ("成都",30.572,104.067), ("重庆",29.563,106.551), ("武汉",30.593,114.305),
        ("西安",34.342,108.940), ("南京",32.060,118.797), ("苏州",31.299,120.585),
        ("厦门",24.480,118.089), ("青岛",36.067,120.383), ("昆明",25.038,102.718),
        ("三亚",18.253,109.512), ("大理",25.607,100.267), ("丽江",26.855,100.227),
        ("桂林",25.274,110.290), ("张家界",29.117,110.479), ("天津",39.084,117.201),
        ("郑州",34.747,113.625), ("合肥",31.820,117.227), ("福州",26.075,119.296),
        ("南昌",28.683,115.858), ("济南",36.651,117.120), ("哈尔滨",45.804,126.535),
        ("沈阳",41.805,123.432), ("长春",43.817,125.324), ("海口",20.044,110.199),
        ("贵阳",26.647,106.630), ("南宁",22.817,108.367), ("兰州",36.061,103.834),
        ("银川",38.487,106.231), ("西宁",36.617,101.778), ("拉萨",29.652,91.172),
        ("乌鲁木齐",43.825,87.617), ("呼和浩特",40.842,111.749), ("太原",37.870,112.549),
        ("石家庄",38.042,114.515), ("香港",22.319,114.169), ("澳门",22.198,113.544)
    ]
    static func city(latitude: Double, longitude: Double) -> String? {
        let point = CLLocation(latitude: latitude, longitude: longitude)
        let distances = centres.map { ($0.0, point.distance(from: CLLocation(latitude: $0.1, longitude: $0.2))) }
        guard let nearest = distances.min(by: { $0.1 < $1.1 }), nearest.1 <= 30_000 else { return nil }
        return nearest.0
    }
    static func name(for records: [MediaRecord]) -> String {
        guard let first = records.map(\.date).min(), let last = records.map(\.date).max() else { return "出游候选" }
        var votes: [String: Int] = [:]
        for record in records {
            if let lat = record.latitude, let lon = record.longitude, let name = city(latitude: lat, longitude: lon) {
                votes[name, default: 0] += 1
            }
        }
        let dominant = votes.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.first
        let place = dominant.flatMap { Double($0.value) / Double(records.count) >= 0.6 ? $0.key : nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        var lunar = Calendar(identifier: .chinese); lunar.timeZone = calendar.timeZone
        var day = calendar.startOfDay(for: first), holiday: String?
        for _ in 0..<11 {
            if day > last { break }
            let solar = calendar.dateComponents([.month, .day], from: day)
            let moon = lunar.dateComponents([.month, .day], from: day)
            if moon.isLeapMonth != true && moon.month == 8 && moon.day == 15 { holiday = "中秋"; break }
            if moon.isLeapMonth != true && moon.month == 1 && moon.day == 1 { holiday = "春节"; break }
            if solar.month == 10 && solar.day == 1 { holiday = "国庆"; break }
            if solar.month == 5 && solar.day == 1 { holiday = "五一"; break }
            if solar.month == 1 && solar.day == 1 { holiday = "元旦"; break }
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = calendar.timeZone; formatter.dateFormat = "M月d日"
        return [holiday ?? formatter.string(from: first), place ?? "出游候选"].joined(separator: " · ")
    }
}
