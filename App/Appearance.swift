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
        return value
    }
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
    static let canvas = adaptive(0xF5F3ED, 0x141A17)
    static let surface = adaptive(0xFFFDF8, 0x232C26)
    static let ink = adaptive(0x29372D, 0xF1F2E9)
    static let secondary = adaptive(0x667066, 0xB8C5B9)
    static let accent = adaptive(0x50664A, 0xC3D5AE)
    static let line = adaptive(0xDDDCD1, 0x465448)
}

struct PaperCard: ViewModifier {
    var radius: CGFloat = 24
    func body(content: Content) -> some View {
        content
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Palette.line.opacity(0.55), lineWidth: 0.5) }
    }
}

extension View {
    func paperCard(radius: CGFloat = 24) -> some View { modifier(PaperCard(radius: radius)) }
    func paperList() -> some View { scrollContentBackground(.hidden).background(Palette.canvas) }
}

enum AlbumTab: Int, CaseIterable {
    case library, trips, people, pending, ai
    var title: String {
        switch self {
        case .library: return "整理"
        case .trips: return "出游"
        case .people: return "人物"
        case .pending: return "待删"
        case .ai: return "AI"
        }
    }
    var icon: String {
        switch self {
        case .library: return "square.grid.2x2"
        case .trips: return "map"
        case .people: return "person.2"
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
                    Text("每批识别100张，自动跳过已完成的图片。截图优先，普通图片可在「更多」中选择。")
                    Text("切换栏目或进入后台会暂停；下次从已保存的进度继续。仅在 iCloud 的原件需先下载。")
                }
                Section("标签与人物") {
                    Text("分类可重叠，人物由你命名关联。视频暂不分析语音与内容；相似照片只是候选。")
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
