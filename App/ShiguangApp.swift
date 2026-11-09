import SwiftUI

@main
@MainActor
struct ShiguangApp: App {
    @StateObject private var store = LibraryStore()
    @AppStorage("appLanguage") private var language = AppLanguage.system.rawValue
    @AppStorage("appearance") private var appearance = AlbumAppearance.system.rawValue
    init() {
        #if DEBUG
        if DesignPreview.enabled, let code = ProcessInfo.processInfo.environment["SHIGUANG_PREVIEW_LANGUAGE"] {
            UserDefaults.standard.set(code,forKey:"appLanguage")
        }
        #endif
        ScanRuntime.shared.register(); SemanticSearchController.shared.registerBackground(); SortActivityController.shared.removeAbandoned()
    }
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(store).tint(Palette.accent).foregroundStyle(Palette.ink)
                .environment(\.locale, Locale(identifier: (AppLanguage(rawValue: language) ?? .system).code))
                .onOpenURL { url in
                    guard url.scheme == "shiguang", url.host == "scan" else { return }
                    if url.path == "/stop" { ScanRuntime.shared.pause(); SemanticSearchController.shared.pause() }
                }
                .preferredColorScheme(AlbumAppearance(rawValue: appearance)?.colorScheme)
        }
    }
}
