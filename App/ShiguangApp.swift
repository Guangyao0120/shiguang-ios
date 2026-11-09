import SwiftUI

@main
@MainActor
struct ShiguangApp: App {
    @StateObject private var store = LibraryStore()
    @AppStorage("appLanguage") private var language = AppLanguage.system.rawValue
    @AppStorage("appearance") private var appearance = AlbumAppearance.system.rawValue
    init() { ScanRuntime.shared.register(); SortActivityController.shared.removeAbandoned() }
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(store).tint(Palette.accent).foregroundStyle(Palette.ink)
                .environment(\.locale, Locale(identifier: (AppLanguage(rawValue: language) ?? .system).code))
                .onOpenURL { url in
                    guard url.scheme == "shiguang", url.host == "scan" else { return }
                    if url.path == "/stop" { ScanRuntime.shared.pause() }
                }
                .preferredColorScheme(AlbumAppearance(rawValue: appearance)?.colorScheme)
        }
    }
}
