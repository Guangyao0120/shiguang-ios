import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, chinese = "zh-Hans", english = "en", japanese = "ja", korean = "ko", spanish = "es", russian = "ru"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return L.t("跟随系统")
        case .chinese: return "简体中文"
        case .english: return "English"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        case .spanish: return "Español"
        case .russian: return "Русский"
        }
    }
    var code: String {
        if self != .system { return rawValue }
        return Bundle.preferredLocalizations(from: ["zh-Hans", "en", "ja", "ko", "es", "ru"], forPreferences: Locale.preferredLanguages).first ?? "en"
    }
}
enum L {
    static var language: AppLanguage { AppLanguage(rawValue: UserDefaults.standard.string(forKey: "appLanguage") ?? "system") ?? .system }
    static var locale: Locale { Locale(identifier: language.code) }
    static func t(_ key: String) -> String {
        guard let path = Bundle.main.path(forResource: language.code, ofType: "lproj"), let bundle = Bundle(path: path) else { return key }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }
    static func f(_ key: String, _ arguments: CVarArg...) -> String { String(format: t(key), locale: locale, arguments: arguments) }
    static func status(_ value: String) -> String {
        if value.hasPrefix("已搜索 "), let regex = try? NSRegularExpression(pattern:"[0-9]+") {
            let numbers = regex.matches(in:value,range:NSRange(value.startIndex...,in:value)).compactMap { match -> Int? in
                guard let range = Range(match.range,in:value) else { return nil }; return Int(value[range])
            }
            if numbers.count == 2 { return f("已搜索 %d/%d 张，按画面相关度排列。",numbers[0],numbers[1]) }
        }
        let parts = value.components(separatedBy: " · ")
        return parts.map { t($0) }.joined(separator: " · ")
    }
}

extension PhotoTag { var title: String { L.t(rawValue) } }
