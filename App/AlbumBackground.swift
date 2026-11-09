import SwiftUI
import UIKit

enum AlbumBackground: String, CaseIterable, Identifiable {
    case system, white, black, sage, cream, rose, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "跟随外观"
        case .white: return "纯白"
        case .black: return "纯黑"
        case .sage: return "浅绿"
        case .cream: return "米色"
        case .rose: return "浅粉"
        case .custom: return "自定义"
        }
    }
    func hex(dark: Bool, custom: String) -> UInt32 {
        switch self {
        case .system: return dark ? 0x101214 : 0xF7F8FA
        case .white: return 0xFFFFFF
        case .black: return 0x000000
        case .sage: return dark ? 0x111B16 : 0xEDF3EE
        case .cream: return dark ? 0x1C1914 : 0xF5F1E8
        case .rose: return dark ? 0x20171B : 0xF8EEF1
        case .custom: return Self.parse(custom) ?? 0xEDF3EE
        }
    }
    static func parse(_ string: String) -> UInt32? {
        let value = string.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        guard value.count == 6, value.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) }) else { return nil }
        return UInt32(value, radix: 16)
    }
    static func isDark(_ hex: UInt32) -> Bool {
        func linear(_ value: UInt32) -> Double {
            let c = Double(value) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear((hex >> 16) & 255) + 0.7152 * linear((hex >> 8) & 255) + 0.0722 * linear(hex & 255)
        return luminance < 0.179
    }
    func scheme(appearance: AlbumAppearance, custom: String) -> ColorScheme? {
        switch self {
        case .white: return .light
        case .black: return .dark
        case .custom: return Self.isDark(hex(dark: false, custom: custom)) ? .dark : .light
        default: return appearance.colorScheme
        }
    }
    static func color(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }
}

struct AlbumCanvas: View {
    @AppStorage("albumBackground") private var background = AlbumBackground.system.rawValue
    @AppStorage("albumBackgroundHex") private var hex = "EDF3EE"
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        AlbumBackground.color((AlbumBackground(rawValue: background) ?? .system).hex(dark: scheme == .dark, custom: hex)).ignoresSafeArea()
    }
}

struct BackgroundSettingsView: View {
    @AppStorage("albumBackground") private var background = AlbumBackground.system.rawValue
    @AppStorage("albumBackgroundHex") private var hex = "EDF3EE"
    @State private var draft = ""
    private var customColor: Binding<Color> {
        Binding(get: { AlbumBackground.color(AlbumBackground.parse(hex) ?? 0xEDF3EE) }, set: { value in
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            guard UIColor(value).getRed(&r, green: &g, blue: &b, alpha: &a) else { return }
            hex = String(format: "%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
            draft = hex; background = AlbumBackground.custom.rawValue
        })
    }
    var body: some View {
        List {
            Section("背景颜色") {
                ForEach(AlbumBackground.allCases.filter { $0 != .custom }) { item in
                    Button { background = item.rawValue } label: {
                        HStack(spacing: 14) {
                            RoundedRectangle(cornerRadius: 8).fill(AlbumBackground.color(item.hex(dark: false, custom: hex)))
                                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.secondary.opacity(0.3), lineWidth: 0.5) }.frame(width: 32, height: 32)
                            Text(L.t(item.title)).foregroundStyle(Palette.ink)
                            Spacer()
                            if background == item.rawValue { Image(systemName: "checkmark").fontWeight(.semibold) }
                        }.frame(minHeight: 44)
                    }.accessibilityIdentifier("background." + item.rawValue)
                    .accessibilityAddTraits(background == item.rawValue ? .isSelected : [])
                }
            }
            Section {
                ColorPicker("自定义颜色", selection: customColor, supportsOpacity: false)
                HStack {
                    Text("HEX").foregroundStyle(Palette.secondary)
                    TextField("RRGGBB", text: $draft).textInputAutocapitalization(.characters).autocorrectionDisabled()
                        .accessibilityIdentifier("background.hex")
                    Button("应用") {
                        guard let value = AlbumBackground.parse(draft) else { return }
                        hex = String(format: "%06X", value); background = AlbumBackground.custom.rawValue
                    }.disabled(AlbumBackground.parse(draft) == nil).accessibilityIdentifier("background.apply")
                }
            } header: { Text("自定义") } footer: { Text("纯白、纯黑与自定义背景会自动调整文字明暗；其他背景跟随显示模式。") }
        }.paperList().navigationTitle("背景颜色").navigationBarTitleDisplayMode(.inline)
            .task { draft = hex }
    }
}
