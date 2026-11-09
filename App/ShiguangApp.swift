import SwiftUI

@main
@MainActor
struct ShiguangApp: App {
    @StateObject private var store = LibraryStore()
    @AppStorage("appearance") private var appearance = AlbumAppearance.system.rawValue
    init() { ScanRuntime.shared.register() }
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(store).tint(Palette.accent).foregroundStyle(Palette.ink)
                .preferredColorScheme(AlbumAppearance(rawValue: appearance)?.colorScheme)
        }
    }
}
