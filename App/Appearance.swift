import SwiftUI
import UIKit

// Used only by Debug simulator launches to inspect layouts without a real library.
enum DesignPreview {
    static var enabled: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["SHIGUANG_DESIGN_PREVIEW"] == "1"
        #else
        false
        #endif
    }
    static var tab: Int {
        guard enabled, let value = Int(ProcessInfo.processInfo.environment["SHIGUANG_PREVIEW_TAB"] ?? "0"), (0...4).contains(value) else { return 0 }
        return value == 2 ? 0 : value
    }
    static var screen: String { enabled ? (ProcessInfo.processInfo.environment["SHIGUANG_PREVIEW_SCREEN"] ?? "") : "" }
}

enum Palette {
    static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 255) / 255,
                           green: CGFloat((hex >> 8) & 255) / 255,
                           blue: CGFloat(hex & 255) / 255, alpha: 1)
        })
    }
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let ink = Color(uiColor: .label)
    static let secondary = adaptive(0x59636B, 0xBAC6D0)
    static let accent = adaptive(0x286D88, 0x9ED7EB)
    static let onAccent = adaptive(0xFFFFFF, 0x122C38)
    static let destructive = adaptive(0xA8332D, 0xE59C94)
    static let line = Color(uiColor: .separator)
}

struct QuietPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 20).padding(.vertical, 13)
            .foregroundStyle(Palette.onAccent)
            .background(configuration.role == .destructive ? Palette.destructive : Palette.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(enabled ? (configuration.isPressed ? 0.78 : 1) : 0.38)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

struct PaperCard: ViewModifier {
    var radius: CGFloat = 18
    func body(content: Content) -> some View {
        content
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Palette.line.opacity(0.35), lineWidth: 0.5) }
    }
}

extension View {
    func paperCard(radius: CGFloat = 18) -> some View { modifier(PaperCard(radius: radius)) }
    func paperList() -> some View { scrollContentBackground(.hidden).background(AlbumCanvas()) }
    @ViewBuilder func albumGlassButton(prominent: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            if prominent { self.buttonStyle(.glassProminent).foregroundStyle(Palette.onAccent).buttonBorderShape(.roundedRectangle(radius: 14)) }
            else { self.buttonStyle(.glass).buttonBorderShape(.roundedRectangle(radius: 14)) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent).foregroundStyle(Palette.onAccent).buttonBorderShape(.roundedRectangle(radius: 14)) }
            else { self.buttonStyle(.bordered).buttonBorderShape(.roundedRectangle(radius: 14)) }
        }
    }
}

enum AlbumTab: Int, CaseIterable {
    case library = 0, trips = 1, pending = 3, ai = 4
    var title: String {
        switch self {
        case .library: return "整理"
        case .trips: return "出游"
        case .pending: return "待删"
        case .ai: return "AI"
        }
    }
    var icon: String {
        switch self {
        case .library: return "square.grid.2x2"
        case .trips: return "map"
        case .pending: return "trash"
        case .ai: return "sparkles"
        }
    }
}

struct GlassTabBar: View {
    @Binding var selection: Int
    var pendingCount: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 3) {
            ForEach(AlbumTab.allCases, id: \.rawValue) { tab in
                let chosen = selection == tab.rawValue
                Button {
                    guard !chosen else { return }
                    UISelectionFeedbackGenerator().selectionChanged()
                    withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.82)) {
                        selection = tab.rawValue
                    }
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 21, weight: chosen ? .semibold : .regular))
                            .scaleEffect(chosen && !reduceMotion ? 1.05 : 1)
                            .overlay(alignment: .topTrailing) {
                                if tab == .pending && pendingCount > 0 {
                                    Circle().fill(Palette.accent).frame(width: 6, height: 6).offset(x: 5, y: -2)
                                }
                            }
                        Text(tab.title).font(.system(size: 11, weight: chosen ? .semibold : .medium))
                    }
                    .foregroundStyle(chosen ? Palette.ink : Palette.secondary)
                    .frame(maxWidth: .infinity).frame(height: 54)
                    .background {
                        if chosen {
                            Capsule(style: .continuous)
                                .fill(Palette.accent.opacity(0.16))
                                .overlay { Capsule().strokeBorder(Palette.accent.opacity(0.15), lineWidth: 0.5) }
                                .matchedGeometryEffect(id: "selection", in: highlight)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title + (tab == .pending && pendingCount > 0 ? "，\(pendingCount)项待删" : ""))
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
        .padding(7)
        .background {
            if reduceTransparency { Capsule().fill(Palette.surface) }
            else { Capsule().fill(.ultraThinMaterial).overlay { Capsule().fill(Palette.surface.opacity(0.28)) } }
        }
        .overlay { Capsule().strokeBorder(Palette.line.opacity(0.75), lineWidth: 0.7) }
        .shadow(color: .black.opacity(0.10), radius: 18, x: 0, y: 6)
        .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 6)
    }
}

struct AlbumHelpView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("整理") {
                    Text("自动跳过已完成的图片。设置中可选择截图或全部图片，以及每次整理数量。")
                    Text("后台整理由系统安排，可在设置中关闭。仅在 iCloud 的原件需先下载。")
                }
                Section("分类与出游") {
                    Text("同一张照片可属于多个分类与行程。视频详情可本机转写并生成标题；相似照片只是候选。")
                }
                Section("照片与隐私") {
                    Text("上滑加入待删，原图仍在。集中删除需系统确认，iCloud 会同步删除；可在苹果照片「最近删除」中恢复。")
                    Text("本地整理不上传。DeepSeek 只接收你确认发送的内容，并按账户计费。")
                }
            }.paperList().navigationTitle("使用说明").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("完成") { dismiss() } }
        }
    }
}
